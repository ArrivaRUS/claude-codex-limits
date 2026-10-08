"""Pure manual quota refresh contract (Python 3.7+, no application imports/I/O).

One RefreshState per provider, owned exclusively by the GUI thread. Workers return
their immutable ticket and result; they never mutate this state or the shared cache.
PollState remains responsible for Auto progression, not manual admission.
"""
import copy
import math
import re
from collections import namedtuple
from datetime import timezone
from email.utils import parsedate_to_datetime


MANUAL_GUARD = 30
Ticket = namedtuple("Ticket", "serial generation")
Admission = namedtuple("Admission", "kind ticket until", defaults=(None, None))
HTTPFailure = namedtuple("HTTPFailure", "status retry_at authentication_required")


def finite(value):
    try:
        return (isinstance(value, (int, float)) and not isinstance(value, bool)
                and math.isfinite(value))
    except OverflowError:
        return False


def _deadline(value):
    return value if finite(value) and value >= 0 else None


class RefreshState:
    def __init__(self, last_attempt=0, server_until=None):
        self.enabled = True
        self.generation = 0
        self.serial = 0
        self.flight = None
        self.local_until = 0       # wall projection for presentation, never the guard clock
        self._restored_attempt = _deadline(last_attempt) or 0
        self._local_monotonic_until = None
        self.server_until = _deadline(server_until)

    def set_enabled(self, value):
        value = bool(value)
        if value != self.enabled:
            self.enabled = value
            self.generation += 1
        # An old worker keeps its reservation even across disable/re-enable.

    def update_clock(self, now, monotonic_now):
        """Project the monotonic guard onto wall time; bootstrap saved wall time once.

        A process restart has no reusable monotonic epoch. Restore only the remaining
        guard, bounded to 30s even if the saved wall timestamp is now in the future.
        Server deadlines are deliberately never rebased or shortened here.
        """
        if not finite(now) or not finite(monotonic_now):
            raise ValueError("quota refresh requires finite wall and monotonic clocks")
        if self._local_monotonic_until is None:
            remaining = (min(MANUAL_GUARD, max(0, self._restored_attempt + MANUAL_GUARD - now))
                         if self._restored_attempt else 0)
            self._local_monotonic_until = monotonic_now + remaining
        remaining = max(0, self._local_monotonic_until - monotonic_now)
        self.local_until = now + remaining if remaining else 0

    def next_attempt(self, scheduled_at, *, now, monotonic_now):
        """A real server deadline supersedes local Auto backoff, as on macOS."""
        self.update_clock(now, monotonic_now)
        return max(self.local_until, self.server_until if self.server_until is not None else scheduled_at)

    def admit(self, intent, now, scheduled_at=0, *, monotonic_now):
        if intent not in ("manual", "scheduled"):
            raise ValueError("unknown quota refresh intent")
        if not finite(scheduled_at):
            raise ValueError("quota refresh requires finite clocks")
        self.update_clock(now, monotonic_now)
        if not self.enabled:
            return Admission("disabled")
        if self.flight is not None:
            return Admission("in_flight")
        if self.server_until is not None and now < self.server_until:
            return Admission("server_wait", until=self.server_until)
        if monotonic_now < self._local_monotonic_until:
            return Admission("local_wait", until=self.local_until)
        if intent == "scheduled" and now < self.next_attempt(scheduled_at, now=now, monotonic_now=monotonic_now):
            return Admission("not_due")
        self.serial += 1
        self.flight = Ticket(self.serial, self.generation)
        self._local_monotonic_until = monotonic_now + MANUAL_GUARD
        self.local_until = now + MANUAL_GUARD
        return Admission("start", self.flight)

    def complete(self, ticket, retry_at=None):
        """Retire only this flight; return whether its result may be applied.

        A disabled/obsolete selection still contributes a real server restriction.
        Duplicate completions cannot release a newer flight or clear its deadline.
        """
        if ticket is None or self.flight != ticket:
            return False
        self.flight = None
        deadline = _deadline(retry_at)
        if not self.enabled or ticket.generation != self.generation:
            if deadline is not None:
                self.server_until = max(self.server_until or 0, deadline)
            return False
        self.server_until = deadline
        return True


def retry_after(raw, now):
    """HTTP delta-seconds or HTTP-date -> epoch deadline; unknown stays None.

    No invented default or upper cap. Obsolete HTTP-date forms remain supported.
    """
    if not finite(now) or not isinstance(raw, str):
        return None
    raw = raw.strip()
    if not raw:
        return None
    if all("0" <= char <= "9" for char in raw):
        try:
            seconds = float(raw)
            deadline = now + seconds
            return deadline if finite(deadline) else None
        except (OverflowError, ValueError):
            return None
    # The mail date parser also accepts incomplete dates/unknown timezone names.
    # Admit only the three HTTP-date wire forms, never guess a missing timezone.
    day = r"(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)"
    month = r"(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)"
    clock = r"[0-9]{2}:[0-9]{2}:[0-9]{2}"
    forms = (day + r", [0-9]{2} " + month + r" [0-9]{4} " + clock + r" GMT",
             r"(?:Monday|Tuesday|Wednesday|Thursday|Friday|Saturday|Sunday), [0-9]{2}-"
             + month + r"-[0-9]{2} " + clock + r" GMT",
             day + " " + month + r" (?: [0-9]|[0-9]{2}) " + clock + r" [0-9]{4}")
    if not any(re.fullmatch(form, raw) for form in forms):
        return None
    try:
        date = parsedate_to_datetime(raw)
        if date.tzinfo is None:
            date = date.replace(tzinfo=timezone.utc)
        deadline = date.timestamp()
        return max(now, deadline) if finite(deadline) else None
    except (TypeError, ValueError, OverflowError, IndexError, OSError):
        return None


def http_failure(status, headers, now, token_endpoint=False, oauth_error=None):
    raw = next((value for key, value in (headers or {}).items()
                if isinstance(key, str) and key.lower() == "retry-after"), None)
    return HTTPFailure(status, retry_after(raw, now),
                       status == 401 or (token_endpoint and oauth_error == "invalid_grant"))


def has_readings(data):
    return (any(finite(getattr(data, key, None)) for key in ("session", "weekly", "reset_credits"))
            or (data.scoped is not None and finite(data.scoped.percent)))


def fallback(result, previous):
    """Snapshot + original as_of from previous; attempt metadata from result.

    Neither argument is mutated. Never resurrect old auth/retry/error state.
    """
    if result.api_fresh:
        return result
    merged = copy.copy(result)
    for key in ("session", "weekly", "session_reset", "weekly_reset", "scoped",
                "plan", "reset_credits", "as_of", "stale"):
        setattr(merged, key, getattr(previous, key))
    merged.from_cache = True
    merged.api_fresh = False
    return merged


def select_snapshot(result, previous):
    """Prefer readings, then known observation time; never synthesize a timestamp."""
    if result.api_fresh or not has_readings(previous):
        return result
    if (not has_readings(result)
            or (_deadline(previous.as_of) is not None
                and (_deadline(result.as_of) is None or previous.as_of > result.as_of))):
        return fallback(result, previous)
    return result
