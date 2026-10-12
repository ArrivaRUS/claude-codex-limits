"""Frozen reader of Linux 0.4.5 (`ccl.sync.merge` + the helpers it calls), for REMOTE-LIMITS C1.

Contract v1.1 promises that an OLD reader sums a new machine file exactly like the same file without
the new keys. `ccl.sync.merge` will change in this feature, so the compatibility oracle is a frozen copy.
Pure: no I/O, no ccl imports. Do not edit except to re-freeze from a released tag.

Copied verbatim (logic unchanged; module references inlined) from linux/ccl at 0.4.5 (APP_VERSION "0.4.5"):
  sync.merge        sha256 580342ffdf3a1de67bd38f42978b23ceb2bb809fe19c711c1d0729785a785e6c (function source)
  common.parse_iso  sha256 5c2543c6061600cd6bf26262cfd83a1b8709d199435e35c27b2f857910c5634d (function source)
  usage.FIELDS / MAX_VALUE / clamp_number / empty_usage / add_usage / merge_days, sync.SCHEMA / KEEP_DAYS
"""

import calendar
import json
import math
import re
import time

SCHEMA = 1
KEEP_DAYS = 45
FIELDS = ("input", "output", "cacheRead", "cacheWrite5m", "cacheWrite1h", "turns")
MAX_VALUE = 10 ** 15

_TS_RE = re.compile(r"^(\d{4})-(\d\d)-(\d\d)[T ](\d\d):(\d\d):(\d\d)(\.\d+)?(Z|[+-]\d\d:?\d\d)?$")


def parse_iso(s):
    if not isinstance(s, str):
        return None
    m = _TS_RE.match(s.strip())
    if not m:
        return None
    y, mo, d, h, mi, se, frac, tz = m.groups()
    try:
        parts = tuple(map(int, (y, mo, d, h, mi, se)))
        if not (1 <= parts[2] <= calendar.monthrange(parts[0], parts[1])[1]
                and 0 <= parts[3] < 24 and 0 <= parts[4] < 60 and 0 <= parts[5] < 60):
            return None
        t = calendar.timegm(parts)
        if tz and tz != "Z":
            sign = 1 if tz[0] == "+" else -1
            tz = tz[1:].replace(":", "")
            hours, minutes = int(tz[:2]), int(tz[2:4])
            if hours >= 24 or minutes >= 60:
                return None
            t -= sign * (hours * 3600 + minutes * 60)
        return t + (float(frac) if frac else 0.0)
    except (ValueError, OverflowError):
        return None


def clamp_number(value):
    if isinstance(value, bool):
        return 0
    if isinstance(value, int):
        return max(0, min(MAX_VALUE, value))
    try:
        value = float(value)
        return max(0, min(MAX_VALUE, value)) if not math.isnan(value) else 0
    except (TypeError, ValueError, OverflowError):
        return 0


def empty_usage():
    return dict.fromkeys(FIELDS, 0)


def add_usage(days, product, day, model, u):
    cur = days.setdefault(product, {}).setdefault(day, {}).setdefault(model, empty_usage())
    for k in FIELDS:
        cur[k] = min(MAX_VALUE, int(clamp_number(cur[k])) + int(clamp_number(u.get(k, 0))))


def merge_days(*sources):
    out = {}
    for src in sources:
        for p, by_day in (src or {}).items():
            for d, by_model in by_day.items():
                for m, u in by_model.items():
                    add_usage(out, p, d, m, u)
    return out


def merge(contents, my_id, now=None):
    now = now or time.time()
    oldest = now - KEEP_DAYS * 86400
    machines, sources, seen = [], [], set()
    for name in sorted(contents):
        try:
            obj = json.loads(contents[name])
        except (ValueError, TypeError, RecursionError):
            continue
        if not isinstance(obj, dict) or type(obj.get("schema")) is not int or obj["schema"] != SCHEMA:
            continue
        m = obj.get("machine")
        if not isinstance(m, dict):
            continue
        mid = m.get("id")
        if (not isinstance(mid, str) or not mid or mid == my_id or mid in seen
                or name != "machine-%s.json" % mid):
            continue
        updated = parse_iso(obj.get("updated"))
        if "updated" in obj and updated is None:
            continue
        if updated is not None and updated < oldest:
            continue
        seen.add(mid)
        metadata = {k: m[k] if isinstance(m.get(k), str) else "" for k in ("name", "os", "app")}
        machines.append(dict(metadata, id=mid, name=metadata["name"] or "?", updated=updated,
                             tz=obj["tz"] if isinstance(obj.get("tz"), str) else ""))
        days = obj.get("days")
        if not isinstance(days, dict):
            continue
        clean = {}
        for p, by_day in days.items():
            if not isinstance(by_day, dict):
                continue
            for d, by_model in by_day.items():
                if not isinstance(by_model, dict):
                    continue
                for model, v in by_model.items():
                    if isinstance(v, dict):
                        counts = {k: v.get(k, 0) for k in FIELDS}
                        if all(type(n) is int and 0 <= n <= MAX_VALUE for n in counts.values()):
                            add_usage(clean, p, d, model, counts)
        sources.append(clean)
    return {"machines": machines, "days": merge_days(*sources)}
