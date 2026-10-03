"""Adaptive API polling. Pure state transitions; clocks are injected for offline tests.

Each product has its own schedule. Local token events can wake it without calling an API.
Errors back off too, and local activity cannot override that backoff. Persist last attempts
so opening the panel, toggling Auto or restarting cannot bypass the 15-minute floor.
"""
import math

STEPS = (900, 1800, 3600, 14400)
MINIMUM = STEPS[0]
DEFAULT = 1800


def number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


class PollState:
    def __init__(self, saved=None):
        saved = saved if isinstance(saved, dict) else {}
        self.interval = saved.get("interval") if saved.get("interval") in STEPS else DEFAULT
        self.last_attempt = saved.get("last_attempt", 0)
        self.observed_at = saved.get("observed_at", 0)
        for key in ("last_attempt", "observed_at"):
            if not number(getattr(self, key)) or getattr(self, key) < 0:
                setattr(self, key, 0)
        self.readings = saved.get("readings", {})
        if not isinstance(self.readings, dict):
            self.readings = {}
        self.failed = bool(saved.get("failed", False))

    def saved(self):
        return dict(interval=self.interval, last_attempt=self.last_attempt, observed_at=self.observed_at,
                    readings=self.readings, failed=self.failed)

    def due(self, now, manual=False):
        # A wall-clock correction must not postpone polling indefinitely.
        if self.last_attempt > now:
            self.last_attempt = now
        elapsed = now - self.last_attempt
        return not self.last_attempt or elapsed >= (MINIMUM if manual and not self.failed else self.interval)

    def begin(self, now):
        self.last_attempt = now

    def observe(self, data, now):
        fresh = (data.api_fresh and data.present and data.error is None and data.auth == "ok" and not data.from_cache
                 and not data.stale and number(data.as_of) and data.as_of >= self.last_attempt - 60)
        current = {}
        for name, value, reset in (("session", data.session, data.session_reset),
                                   ("weekly", data.weekly, data.weekly_reset)):
            if number(value):
                current[name] = [value, reset]
        if data.scoped and number(data.scoped.percent):
            current["model:" + data.scoped.name] = [data.scoped.percent, data.scoped.reset]
        self.last_attempt = max(self.last_attempt, now)
        if not fresh or not current:
            self.failed = True
            self.interval = STEPS[min(STEPS.index(self.interval) + 1, len(STEPS) - 1)]
            return
        self.failed = False
        elapsed = now - self.observed_at
        comparable, active = False, False
        if self.observed_at and elapsed > 0:
            for name, pair in current.items():
                old = self.readings.get(name)
                if not isinstance(old, (list, tuple)) or len(old) != 2 or not number(old[0]) or old[1] != pair[1]:
                    continue                         # a reset/model change isn't consumption
                comparable = True
                if (pair[0] - old[0]) * MINIMUM >= elapsed:
                    active = True                    # ≥1 percentage point per 15 minutes
        if active:
            self.interval = MINIMUM
        elif comparable:
            self.interval = STEPS[min(STEPS.index(self.interval) + 1, len(STEPS) - 1)]
        self.readings, self.observed_at = current, now

    def local_activity(self, timestamps, now):
        if self.failed:
            return False
        recent = {t for t in timestamps if number(t) and now - MINIMUM <= t <= now}
        if len(recent) >= 3 and max(recent) > self.last_attempt and self.interval != MINIMUM:
            self.interval = MINIMUM
            return True
        return False
