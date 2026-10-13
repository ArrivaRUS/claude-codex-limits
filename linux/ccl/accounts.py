"""Local account identity and gist-scoped labels, without credential updates."""

import hashlib
import hmac
import json
import math
import re
import time
import unicodedata

from . import common


_MAX_LOGIN_BYTES = 8 * 1024 * 1024
_READ_ATTEMPTS = 5


def label(*, product, local_id, gist_id):
    """Compute a v1 label under the current gist; never cache it locally."""
    if product not in ("claude", "codex"):
        raise ValueError("unsupported product")
    if not isinstance(local_id, str) or not local_id.strip():
        raise ValueError("local account id is required")
    if not isinstance(gist_id, str) or not gist_id.strip():
        raise ValueError("gist id is required")
    try:
        key = hashlib.sha256(("ccl-label-key-v1|" + gist_id).encode("utf-8")).digest()
        message = ("ccl-account-v1|" + product + "|" + local_id.strip().lower()).encode("utf-8")
    except UnicodeEncodeError:
        raise ValueError("account label arguments must be valid UTF-8") from None
    return hmac.new(key, message, hashlib.sha256).hexdigest()[:16]


def read_local_id(product):
    """Re-read the CLI profile and return only (normalized id, failure reason).

    A partial CLI write may recover within five reads. Profile fields and raw
    bytes are transient parser inputs: they are never cached, logged or returned.
    """
    if product == "claude":
        path, block_key, id_key = common.CLAUDE_JSON, "oauthAccount", "accountUuid"
    elif product == "codex":
        path, block_key, id_key = common.CODEX_AUTH, "tokens", "account_id"
    else:
        raise ValueError("unsupported product")

    reason = "unreadable"
    for attempt in range(_READ_ATTEMPTS):
        raw = root = block = local_id = None
        try:
            with open(path, "rb") as stream:
                raw = stream.read(_MAX_LOGIN_BYTES + 1)
            if len(raw) > _MAX_LOGIN_BYTES:
                return None, "unreadable"
            root = json.loads(raw.decode("utf-8"))
            if not isinstance(root, dict):
                raise ValueError("invalid profile shape")
            block = root.get(block_key)
            if block is None:
                return None, "no_login"
            if not isinstance(block, dict):
                raise ValueError("invalid account block shape")
            local_id = block.get(id_key)
            if not isinstance(local_id, str) or not local_id.strip():
                return None, "no_account_uuid"
            local_id = local_id.strip().lower()
            if re.fullmatch(r"[0-9a-z-]{8,64}", local_id) is None:
                return None, "no_account_uuid"
            return local_id, None
        except FileNotFoundError:
            return None, "no_login"
        except (OSError, ValueError, RecursionError):
            reason = "unreadable"
        finally:
            # Do not retain profile contents across retry sleeps or after return.
            raw = root = block = local_id = None
        if attempt + 1 < _READ_ATTEMPTS:
            time.sleep(0.2)
    return None, reason


_PRODUCTS = ("claude", "codex")
_STATUSES = ("ok", "stale", "signed_out", "expired", "rate_limited", "error")
_COUNTERS = ("input", "output", "cacheRead", "cacheWrite5m", "cacheWrite1h", "turns")
_MAX_COUNTER = 10 ** 15
_HEX_LABEL = re.compile(r"[0-9a-f]{16}\Z")


def _text(value, limit=None, nfc=False):
    """Reject an unsafe string whole; never strip or truncate remote text."""
    if not isinstance(value, str) or (limit is not None and len(value) > limit):
        return None
    if any(unicodedata.category(ch) in ("Cc", "Cf") for ch in value):
        return None
    try:
        value.encode("utf-8")
    except UnicodeEncodeError:
        return None
    value = unicodedata.normalize("NFC", value) if nfc else value
    return value if limit is None or len(value) <= limit else None


def _label(value):
    return value if isinstance(value, str) and _HEX_LABEL.fullmatch(value) else None


def _epoch(value):
    # No valid metadata record can contain a time longer than its entire cap.
    if _text(value, 4096) is None:
        return None
    parsed = common.parse_iso(value)
    return parsed if parsed is not None and math.isfinite(parsed) else None


def _copy_time(source, target, key):
    if _epoch(source.get(key)) is not None:
        target[key] = source[key]


def _window(value):
    if not isinstance(value, dict):
        return None
    pct = value.get("pct")
    # Bounds precede isfinite so arbitrarily large JSON integers cannot overflow
    # its float conversion. Booleans are never numbers in the wire contract.
    if type(pct) not in (int, float) or not 0 <= pct <= 100 or not math.isfinite(pct):
        return None
    out = {"pct": pct}
    _copy_time(value, out, "resetAt")
    return out


def _days(value):
    """Validate day/model counters like v1 merge, without a product level."""
    out = {}
    if not isinstance(value, dict):
        return out
    for day, models in value.items():
        if _text(day) is None or not isinstance(models, dict):
            continue
        for model, counts in models.items():
            if _text(model) is None or not isinstance(counts, dict):
                continue
            clean = {key: counts.get(key, 0) for key in _COUNTERS}
            if all(type(n) is int and 0 <= n <= _MAX_COUNTER and math.isfinite(n)
                   for n in clean.values()):
                out.setdefault(day, {})[model] = clean
    return out


def _product_days(value):
    if not isinstance(value, dict):
        return {}
    return {product: clean for product, days in value.items()
            if _text(product) is not None and (clean := _days(days))}


def validate_entry(entry):
    """Return a fresh, allow-listed v1.1 record, or None for an invalid record.

    Timestamps stay ISO strings. Invalid optional fields cannot poison other
    records or the machine's root usage. This function performs no I/O.
    """
    if not isinstance(entry, dict) or entry.get("product") not in _PRODUCTS or "status" not in entry:
        return None
    status = entry["status"]
    out = {"product": entry["product"], "label": _label(entry.get("label")),
           "status": status if status in _STATUSES else "error"}
    for key, allowed in (
            ("labelReason", ("no_login", "no_account_uuid", "unreadable", "no_gist")),
            ("expiredReason", ("cli_refresh_pending", "signin_required")),
            ("attemptKind", ("auto", "activity", "manual", "initial"))):
        if entry.get(key) in allowed:
            out[key] = entry[key]
    for key in ("plan", "tier"):
        value = _text(entry.get(key), 64)
        if value is not None:
            out[key] = value
    for key in ("asOf", "attemptAt", "retryUntil"):
        _copy_time(entry, out, key)
    if "retryUntil" in entry and entry["retryUntil"] is None:
        out["retryUntil"] = None

    windows = entry.get("windows")
    if isinstance(windows, dict):
        out["windows"] = {}
        for key in ("session", "weekly"):
            window = _window(windows.get(key))
            if window is not None:
                out["windows"][key] = window
    models = entry.get("models")
    if isinstance(models, list):
        out["models"] = []
        for model in models[:8]:
            window = _window(model)
            name = _text(model.get("name"), 48, nfc=True) if isinstance(model, dict) else None
            if window is not None and name is not None:
                out["models"].append(dict(window, name=name))
    credits = entry.get("resetCredits")
    if type(credits) is int and 0 <= credits <= 1000 and math.isfinite(credits):
        out["resetCredits"] = credits
    schedule = entry.get("schedule")
    if (isinstance(schedule, dict) and schedule.get("mode") in ("auto", "fixed")
            and type(schedule.get("interval")) is int
            and schedule["interval"] in (900, 1800, 3600, 14400)
            and math.isfinite(schedule["interval"])):
        clean = {"mode": schedule["mode"], "interval": schedule["interval"]}
        _copy_time(schedule, clean, "nextAt")
        if type(schedule.get("backoff")) is bool:
            clean["backoff"] = schedule["backoff"]
        out["schedule"] = clean

    # Apply the metadata cap after sanitizing fields and dropping the model tail;
    # days have a separate file-level budget, and unknown fields are not retained.
    if len(json.dumps(out, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode("utf-8")) > 4096:
        return None
    out["days"] = _days(entry.get("days"))
    return out


def _captions(value):
    out = {}
    if not isinstance(value, dict):
        return out
    for key, caption in value.items():
        if _label(key) is None or not isinstance(caption, dict):
            continue
        text = _text(caption.get("text"), 32, nfc=True)
        if text is None:
            continue
        out[key] = {"text": text}
        _copy_time(caption, out[key], "setAt")
        if len(out) == 64:
            break
    return out


def _sum_days(target, source):
    """Sum validated counters exactly, so overflow cannot mask a mismatch."""
    for day, models in source.items():
        for model, counts in models.items():
            total = target.setdefault(day, {}).setdefault(model, dict.fromkeys(_COUNTERS, 0))
            for key in _COUNTERS:
                total[key] += counts[key]


def parse_block(machine_obj):
    """Parse v1.1 fields without changing input or counting root usage twice.

    The caller validates the outer v1 envelope and transport caps. A legacy or
    broken block still returns its valid root days as unattributed usage.
    """
    if not isinstance(machine_obj, dict):
        machine_obj = {}
    unique = {}
    entries = machine_obj.get("accounts")
    if isinstance(entries, list):
        for raw in entries[:64]:
            entry = validate_entry(raw)
            if entry is None:
                continue
            key = (entry["product"], entry["label"])
            previous = unique.get(key)
            if previous is None:
                # Equivalent to capping after dedup: retain the first eight
                # valid keys, but still look for newer versions of those keys.
                if len(unique) < 8:
                    unique[key] = entry
            else:
                old_time, new_time = _epoch(previous.get("asOf")), _epoch(entry.get("asOf"))
                if new_time is not None and (old_time is None or new_time > old_time):
                    unique[key] = entry
    accounts = list(unique.values())
    root = _product_days(machine_obj.get("days"))
    unattributed = _product_days(machine_obj.get("unattributedDays"))
    projection = {}
    for product, days in unattributed.items():
        _sum_days(projection.setdefault(product, {}), days)
    for entry in accounts:
        _sum_days(projection.setdefault(entry["product"], {}), entry["days"])
    for product in root.keys() | projection.keys():
        if root.get(product, {}) != projection.get(product, {}):
            if product in root:
                unattributed[product] = root[product]
            else:
                unattributed.pop(product, None)
            for entry in accounts:
                if entry["product"] == product:
                    entry["days"] = {}
    return {"accounts": accounts, "captions": _captions(machine_obj.get("captions")),
            "unattributedDays": unattributed, "lastSeenAt": _epoch(machine_obj.get("lastSeenAt"))}


def _writer_text(value, limit):
    """Clean local display text before passing it to the strict reader validator."""
    if not isinstance(value, str):
        return None
    value = unicodedata.normalize("NFC", "".join(
        ch for ch in value if unicodedata.category(ch) not in ("Cc", "Cf")))
    try:
        value.encode("utf-8")
    except UnicodeEncodeError:
        return None
    return value[:limit]


def _writer_name(value, limit):
    """Refuse email/path markers after NFKC, before NFC cleanup and truncation."""
    if not isinstance(value, str):
        return None
    folded = unicodedata.normalize("NFKC", value)
    if any(ch in folded for ch in ("@", "/", "\\")):
        return None
    return _writer_text(value, limit)


def _writer_entry(raw, gist_id):
    if not isinstance(raw, dict) or raw.get("product") not in _PRODUCTS or "status" not in raw:
        return None
    # Copy contract fields only; credentials and localId never enter the result.
    keys = ("product", "status", "labelReason", "expiredReason", "plan", "tier", "asOf",
            "attemptAt", "attemptKind", "windows", "models", "resetCredits", "schedule",
            "retryUntil", "days")
    candidate = {key: raw[key] for key in keys if key in raw}
    candidate["label"] = None
    reason = None
    if not isinstance(gist_id, str) or not gist_id.strip():
        reason = "no_gist"
    elif not isinstance(raw.get("localId"), str) or not raw["localId"].strip():
        reason = raw.get("labelReason")
        if reason not in ("no_login", "no_account_uuid", "unreadable"):
            reason = "no_account_uuid"
    else:
        try:
            candidate["label"] = label(product=raw["product"], local_id=raw["localId"], gist_id=gist_id)
        except ValueError:
            reason = "unreadable"
    if reason is not None:
        candidate["labelReason"] = reason
        candidate["status"] = "signed_out" if reason == "no_login" else "error"
        # A missing identity cannot justify cached readings, even if supplied.
        for key in ("plan", "tier", "asOf", "windows", "models", "resetCredits", "expiredReason"):
            candidate.pop(key, None)
    else:
        candidate.pop("labelReason", None)
        if candidate["status"] == "stale":
            candidate["status"] = "error"  # stale is a reader-only state
        for key in ("plan", "tier"):
            if key in candidate:
                candidate[key] = _writer_text(candidate[key], 64)
        if isinstance(candidate.get("models"), list):
            models = []
            for model in candidate["models"][:8]:
                if not isinstance(model, dict):
                    continue
                name = _writer_name(model.get("name"), 48)
                if name is None:
                    continue
                models.append({"name": name,
                               "pct": model.get("pct"), "resetAt": model.get("resetAt")})
            candidate["models"] = models
    return validate_entry(candidate)


def _writer_captions(value):
    out = {}
    if not isinstance(value, dict):
        return out
    for key, caption in value.items():
        if _label(key) is None or not isinstance(caption, dict):
            continue
        text = _writer_name(caption.get("text"), 32)
        if text is None:
            continue
        out[key] = {"text": text}
        _copy_time(caption, out[key], "setAt")
        if len(out) == 64:
            break
    return out


def _writer_sum_days(target, source):
    _sum_days(target, source)
    if any(n > _MAX_COUNTER for models in target.values()
           for counts in models.values() for n in counts.values()):
        # Clamping only the projection would break account attribution. Refuse
        # the whole local build rather than publish inconsistent usage totals.
        raise ValueError("usage projection exceeds counter limit")


def build(*, gist_id, entries, unattributed_days, captions):
    """Build a fresh v1.1 block, computing labels only under this gist id.

    Duplicate snapshots keep the latest successful asOf (first wins a tie).
    Usage beyond the eight-record cap, or lacking a label, stays unattributed.
    The returned root days is exactly the sum of the returned split.
    """
    unattributed = {product: days for product, days in _product_days(unattributed_days).items()
                    if product in _PRODUCTS}
    unique = {}
    if isinstance(entries, (list, tuple)):
        for raw in entries:
            entry = _writer_entry(raw, gist_id)
            if entry is None:
                continue
            # With no gist, different local accounts all have label=None.
            # Keep their usage distinct until it has been moved to unattributed
            # days; the local key is transient and never reaches the wire block.
            local_id = raw.get("localId")
            local_key = local_id.strip().lower() if isinstance(local_id, str) else None
            key = (entry["product"], entry["label"], local_key if entry["label"] is None else None)
            new_time = _epoch(raw.get("asOf"))
            previous = unique.get(key)
            if previous is None:
                unique[key] = (entry, new_time)
            else:
                old_time = previous[1]
                if new_time is not None and (old_time is None or new_time > old_time):
                    unique[key] = (entry, new_time)

    accounts = []
    null_products = set()
    for entry, _ in unique.values():
        if entry["label"] is None or len(accounts) == 8:
            if entry["days"]:
                _writer_sum_days(unattributed.setdefault(entry["product"], {}), entry["days"])
            if len(accounts) == 8:
                continue
            entry["days"] = {}
            if entry["product"] in null_products:
                continue
            null_products.add(entry["product"])
        accounts.append(entry)

    projection = {}
    for product, days in unattributed.items():
        _writer_sum_days(projection.setdefault(product, {}), days)
    for entry in accounts:
        if entry["days"]:
            _writer_sum_days(projection.setdefault(entry["product"], {}), entry["days"])
    return {"accounts": accounts, "unattributedDays": unattributed,
            "captions": _writer_captions(captions), "days": projection}
