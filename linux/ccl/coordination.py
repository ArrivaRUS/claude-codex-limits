"""Pure B2 coordination for records already selected for the local account label.

The caller checks its own PollState.due first and persists Decision's tie_wait and
remote_retry. Remote observations never update PollState or the local Retry-After.
There are no clocks, I/O or process-local caches here.
"""

import math
from collections import namedtuple

from .polling import STEPS, normalize_interval


Decision = namedtuple("Decision", "action reason tie_wait remote_retry events")
SKEW = 60
ATTEMPT_WINDOW = 900 + SKEW
LIVE_WINDOW = 1800
RETRY_CAP = 86400


def _number(value):
    """Finite epoch number, or absent; JSON booleans and numeric strings are not times."""
    if type(value) not in (int, float):
        return None
    try:
        return value if math.isfinite(value) else None
    except OverflowError:
        return None


def _pair(value):
    if (isinstance(value, (tuple, list)) and len(value) == 2
            and isinstance(value[0], str) and value[0] and _number(value[1]) is not None):
        return value[0], value[1]
    return None


def _records(now, remote, my_id):
    """Reject stale/inconsistent records as a whole; malformed individual times are absent."""
    if not isinstance(remote, (list, tuple)):
        return []
    records = []
    for record in remote:
        if not isinstance(record, dict):
            continue
        machine_id = record.get("machineId")
        if not isinstance(machine_id, str) or not machine_id or machine_id == my_id:
            continue
        seen = _number(record.get("lastSeenAt"))
        if seen is None or seen < now - LIVE_WINDOW:
            continue
        as_of = _number(record.get("asOf"))
        attempt = _number(record.get("attemptAt"))
        next_at = _number(record.get("nextAt"))
        interval = _number(record.get("interval"))
        interval = interval if interval in STEPS else STEPS[-1]
        if ((as_of is not None and as_of > now + SKEW)
                or (attempt is not None and attempt > now + SKEW)
                or (as_of is not None and attempt is not None and as_of > attempt + SKEW)
                or (next_at is not None and next_at > now + interval + SKEW)):
            continue
        records.append({"machineId": machine_id, "status": record.get("status"),
                        "lastSeenAt": seen, "asOf": as_of, "attemptAt": attempt,
                        "nextAt": next_at, "retryUntil": _number(record.get("retryUntil"))})
    return records


def _remote_retry(now, saved, records, last_attempt):
    """Bound a chain of foreign waits until a local attempt consumes its deadline.

    Setting until to firstSeenAt + 24 h marks a consumed cap without adding fields.
    It is retained even when the source disappears: a heartbeat, changed deadline,
    or restart must not arm another 24 h wait in the same chain. A local attempt
    at or after the cap clears this marker. An effective deadline expired more
    than 900 seconds ago also ends the chain, including a consumed cap marker.
    Missing or malformed last_attempt cannot prove that a local attempt occurred.
    """
    retry = None
    if isinstance(saved, dict):
        until, first = _number(saved.get("until")), _number(saved.get("firstSeenAt"))
        if until is not None and first is not None and first <= now:
            retry = {"until": until, "firstSeenAt": first}
    if retry is not None:
        cap = retry["firstSeenAt"] + RETRY_CAP
        if now - min(retry["until"], cap) > 900:
            retry = None
    if retry is not None:
        cap = retry["firstSeenAt"] + RETRY_CAP
        if retry["until"] >= cap:
            if retry["until"] == cap and last_attempt is not None and last_attempt >= cap:
                retry = None
            else:
                if now >= cap and retry["until"] > cap:
                    retry["until"] = cap
                    return retry, ("remote_retry_capped",)
                return retry, ()
        elif now < retry["until"]:
            return retry, ()

    deadlines = [r["retryUntil"] for r in records
                 if r["retryUntil"] is not None and r["retryUntil"] > now]
    if deadlines:
        first = now
        if retry is not None and (last_attempt is None or last_attempt < retry["until"]):
            first = retry["firstSeenAt"]
        retry = {"until": max(deadlines), "firstSeenAt": first}
        if now >= first + RETRY_CAP:
            retry["until"] = first + RETRY_CAP
            return retry, ("remote_retry_capped",)
    return retry, ()


def decide(now, mine, remote, my_id, tie_wait=None):
    """Return retry_after > remote_attempt > fresh_remote > tie_break > poll.

    Manual requests apply only the first two rules. Every return carries the
    next persisted state; poll clears tie_wait but preserves a consumed retry cap.
    """
    now = _number(now)
    # The caller supplies a finite clock. A malformed clock is handled without I/O.
    if now is None:
        now = 0
    mine = mine if isinstance(mine, dict) else {}
    interval = normalize_interval(mine.get("interval"))
    records = _records(now, remote, my_id)
    last_attempt = _number(mine.get("last_attempt"))
    retry, events = _remote_retry(now, mine.get("remote_retry"), records, last_attempt)
    remembered = _pair(tie_wait)

    server_until = _number(mine.get("server_until"))
    remote_until = min(retry["until"], retry["firstSeenAt"] + RETRY_CAP) if retry else None
    if ((server_until is not None and now < server_until)
            or (remote_until is not None and now < remote_until)):
        return Decision("skip", "retry_after", remembered, retry, events)

    if any(r["attemptAt"] is not None and now - r["attemptAt"] < ATTEMPT_WINDOW for r in records):
        return Decision("skip", "remote_attempt", remembered, retry, events)

    if mine.get("manual") is not True:
        if any(r["status"] == "ok" and r["asOf"] is not None
               and now - r["asOf"] < interval + SKEW for r in records):
            return Decision("skip", "fresh_remote", remembered, retry, events)

        if last_attempt is not None and isinstance(my_id, str):
            due = last_attempt + interval
            candidates = [(r["machineId"], r["nextAt"]) for r in records
                          if r["nextAt"] is not None and abs(r["nextAt"] - due) <= SKEW
                          and r["lastSeenAt"] >= now - 900 and r["machineId"] < my_id]
            # A stable winner prevents record order / multiple peers from making
            # us alternate between pairs and wait indefinitely.
            winner = min(candidates) if candidates else None
            if winner is not None and winner != remembered:
                return Decision("skip", "tie_break", winner, retry, events)

    return Decision("poll", None, None, retry, events)
