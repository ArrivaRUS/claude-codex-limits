"""Local usage logs → per-day, per-model token counts (port of `UsageLogs` / `scanFile`).

Sources, exactly as in docs/sync-protocol.md («One file per machine»):
  • Claude Code: ~/.claude/projects/**.jsonl — INCLUDING <session>/subagents/agent-*.jsonl.
    One assistant `message.id` counts once per day: transcripts repeat messages after a
    resume or a compaction, sometimes far from the first copy.
  • Codex: ~/.codex/sessions/**/rollout-*.jsonl — every `token_count` event's
    `info.last_token_usage`; `input = input_tokens − cached_input_tokens`; the model comes
    from the latest `turn_context`.

The scan is incremental: for every file the index remembers how many bytes were consumed and
reads only what was appended since, whole lines only (the CLI may be mid-write on the last one).
Logs run to gigabytes, so a full re-parse on every pass is not an option.
"""

import hashlib
import json
import math
import os
import time

from . import common

KEEP_DAYS = 45
FIELDS = ("input", "output", "cacheRead", "cacheWrite5m", "cacheWrite1h", "turns")
CHUNK = 32 * 1024 * 1024
INDEX_VERSION = 1
MAX_VALUE = 10 ** 15


def clamp_number(value):
    """Bound counts and display amounts before float arithmetic (including old caches)."""
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


def total_tokens(u):
    return clamp_number(sum(clamp_number(u.get(k, 0)) for k in FIELDS if k != "turns"))


def add_usage(days, product, day, model, u):
    cur = days.setdefault(product, {}).setdefault(day, {}).setdefault(model, empty_usage())
    for k in FIELDS:
        cur[k] = min(MAX_VALUE, int(clamp_number(cur[k])) + int(clamp_number(u.get(k, 0))))


def _int(v):
    try:
        return int(v or 0)
    except (TypeError, ValueError, OverflowError):
        return 0


def _id_hash(s):
    """Stable 64-bit fingerprint of a message id (the index only ever compares them)."""
    return int.from_bytes(hashlib.blake2b(s.encode("utf-8"), digest_size=8).digest(), "big")


# ---- the index ----------------------------------------------------------------------------

def new_index():
    return {"v": INDEX_VERSION, "files": {}, "days": {}, "seen": {}}


def load_index():
    ix = common.read_json(common.USAGE_INDEX_PATH)
    if not isinstance(ix, dict) or ix.get("v") != INDEX_VERSION:
        return new_index()
    for k in ("files", "days", "seen"):
        if not isinstance(ix.get(k), dict):
            ix[k] = {}
    return ix


def save_index(ix):
    common.ensure_dirs()
    common.write_json(common.USAGE_INDEX_PATH, ix)


def cutoff_day(now=None, keep=KEEP_DAYS):
    return common.day_key((now or time.time()) - keep * 86400)


def prune(ix, now=None):
    """Forget days beyond the retention window so the index can't grow forever."""
    cut = cutoff_day(now)
    changed = False
    for p in list(ix["days"].keys()):
        kept = {d: v for d, v in ix["days"][p].items() if d >= cut}
        if len(kept) != len(ix["days"][p]):
            changed = True
        ix["days"][p] = kept
    seen = {d: v for d, v in ix["seen"].items() if d >= cut}
    if len(seen) != len(ix["seen"]):
        changed = True
    ix["seen"] = seen
    return changed


def _walk(root, want):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for fn in sorted(filenames):
            if want(fn):
                yield os.path.join(dirpath, fn)


def scan(ix, now=None, claude_root=None, codex_root=None, progress=None):
    """Incremental rescan of both CLIs' logs into `ix`. Returns True when anything changed."""
    now = now or time.time()
    claude_root = claude_root or common.CLAUDE_PROJECTS
    codex_root = codex_root or common.CODEX_SESSIONS
    oldest = now - KEEP_DAYS * 86400
    seen = {d: set(v) for d, v in ix["seen"].items()}
    changed = False
    alive = set()

    def recent(path):
        try:
            return os.stat(path).st_mtime >= oldest
        except OSError:
            return False

    jobs = [(p, "claude") for p in _walk(claude_root, lambda f: f.endswith(".jsonl"))]
    jobs += [(p, "codex") for p in _walk(codex_root, lambda f: f.endswith(".jsonl") and f.startswith("rollout-"))]
    for n, (path, product) in enumerate(jobs):
        alive.add(path)
        if not recent(path):
            continue
        if progress:
            progress(n, len(jobs), path)
        if _scan_file(path, product, ix, seen):
            changed = True
    # marks of files that are gone (a pruned project, a deleted session) are dead weight
    for path in list(ix["files"].keys()):
        if path not in alive and (path.startswith(claude_root) or path.startswith(codex_root)):
            del ix["files"][path]
            changed = True
    ix["seen"] = {d: sorted(s) for d, s in seen.items()}
    return changed


def _scan_file(path, product, ix, seen):
    try:
        size = os.stat(path).st_size
    except OSError:
        return False
    mark = ix["files"].get(path) or {"size": 0}
    if size < mark.get("size", 0):          # truncated / rewritten → start over
        mark = {"size": 0}
    start = mark.get("size", 0)
    if size <= start:
        return False
    st = {"lastId": mark.get("lastId"), "model": mark.get("model")}
    consumed = 0
    try:
        with open(path, "rb") as f:
            f.seek(start)
            buf = b""
            while True:
                chunk = f.read(CHUNK)
                if not chunk:
                    break
                buf = buf + chunk if buf else chunk
                end = buf.rfind(b"\n") + 1        # only complete lines
                if end == 0:
                    continue
                if product == "claude":
                    _claude_lines(buf, end, ix, seen, st)
                else:
                    _codex_lines(buf, end, ix, st)
                consumed += end
                buf = buf[end:]
    except OSError:
        return False
    if consumed == 0:
        return False
    ix["files"][path] = {"size": start + consumed, "lastId": st["lastId"], "model": st["model"]}
    return True


def _lines_with(data, end, needles):
    """Yield (line_bytes) for every line in data[:end] that contains any of `needles`, in file
    order, each line once. `bytes.find` is the C-speed equivalent of the Mac's memmem pass."""
    nxt = [data.find(n, 0, end) for n in needles]
    while True:
        cands = [i for i in nxt if i >= 0]
        if not cands:
            return
        i = min(cands)
        ls = data.rfind(b"\n", 0, i) + 1
        le = data.find(b"\n", i, end)
        if le < 0:
            le = end
        yield data[ls:le]
        for k, n in enumerate(needles):
            if 0 <= nxt[k] <= le:
                nxt[k] = data.find(n, le + 1, end)


def _claude_lines(data, end, ix, seen, st):
    days = ix["days"]
    for line in _lines_with(data, end, (b'"usage"',)):
        try:
            o = json.loads(line)
        except ValueError:
            continue
        if not isinstance(o, dict):
            continue
        t = common.parse_iso(o.get("timestamp"))
        if t is None:
            continue
        if o.get("type") != "assistant":
            continue
        msg = o.get("message")
        if not isinstance(msg, dict) or not isinstance(msg.get("usage"), dict):
            continue
        usage = msg["usage"]
        # A message with several content blocks is written as several lines that repeat the
        # same id and the same usage — count each message once …
        mid = msg.get("id")
        if mid is not None and mid == st["lastId"]:
            continue
        st["lastId"] = mid
        day = common.day_key(t)
        # … and once per day across ALL files: a resume/compaction copies it elsewhere.
        if isinstance(mid, str):
            h = _id_hash(mid)
            s = seen.setdefault(day, set())
            if h in s:
                continue
            s.add(h)
        model = msg.get("model") or "?"
        if model == "<synthetic>":
            continue
        u = empty_usage()
        u["input"] = _int(usage.get("input_tokens"))
        u["output"] = _int(usage.get("output_tokens"))
        u["cacheRead"] = _int(usage.get("cache_read_input_tokens"))
        cc = usage.get("cache_creation")
        if isinstance(cc, dict):
            u["cacheWrite5m"] = _int(cc.get("ephemeral_5m_input_tokens"))
            u["cacheWrite1h"] = _int(cc.get("ephemeral_1h_input_tokens"))
        else:
            u["cacheWrite5m"] = _int(usage.get("cache_creation_input_tokens"))
        u["turns"] = 1
        add_usage(days, "claude", day, model, u)


def _codex_lines(data, end, ix, st):
    days = ix["days"]
    for line in _lines_with(data, end, (b'"token_count"', b'"turn_context"')):
        try:
            o = json.loads(line)
        except ValueError:
            continue
        if not isinstance(o, dict):
            continue
        p = o.get("payload")
        if not isinstance(p, dict):
            continue
        if o.get("type") == "turn_context":
            if isinstance(p.get("model"), str):
                st["model"] = p["model"]
            continue
        if p.get("type") != "token_count":
            continue
        t = common.parse_iso(o.get("timestamp"))
        if t is None:
            continue
        info = p.get("info")
        lu = info.get("last_token_usage") if isinstance(info, dict) else None
        if not isinstance(lu, dict):
            continue
        # OpenAI's input_tokens INCLUDES the cached part — split it out for pricing.
        inp, cached = _int(lu.get("input_tokens")), _int(lu.get("cached_input_tokens"))
        u = empty_usage()
        u["input"] = max(0, inp - cached)
        u["cacheRead"] = cached
        u["cacheWrite5m"] = _int(lu.get("cache_write_input_tokens"))
        u["output"] = _int(lu.get("output_tokens"))      # reasoning tokens are inside output
        u["turns"] = 1
        add_usage(days, "codex", common.day_key(t), st["model"] or "?", u)


def refresh(blocking=True, progress=None):
    """Load the index, rescan, prune, save — under the shared lock so the tray and the timer
    never scan at the same time. Returns (index, changed, fresh). When `blocking` is False and
    another process is scanning, returns the index as it is on disk with fresh=False."""
    with common.file_lock("usage-index", blocking=blocking) as held:
        ix = load_index()
        if not held:
            return ix, False, False
        changed = scan(ix, progress=progress)
        if prune(ix):
            changed = True
        if changed:
            save_index(ix)
        return ix, changed, True


def snapshot_days(ix, now=None):
    """What goes into this machine's gist file: product → day → model, last 45 days."""
    cut = cutoff_day(now)
    out = {}
    for p, by_day in ix.get("days", {}).items():
        out[p] = {d: {m: dict(u) for m, u in by_model.items()} for d, by_model in by_day.items() if d >= cut}
    return out


def merge_days(*sources):
    out = {}
    for src in sources:
        for p, by_day in (src or {}).items():
            for d, by_model in by_day.items():
                for m, u in by_model.items():
                    add_usage(out, p, d, m, u)
    return out


# ---- prices & money (port of MODEL_PRICES / apiCost / dailyUsage / moneySummary) ------------

# USD per 1M tokens: (input, output, cacheRead, cacheWrite 5-minute tier). Anthropic's 1-hour
# writes are billed at 2× input (see api_cost). Matched by prefix, most specific first; an
# unknown model costs nothing, so the money figures never silently include a guess.
MODEL_PRICES = [
    ("claude-fable-5-1", (10, 50, 0.25, 12.5)),
    ("claude-fable", (10, 50, 1.0, 12.5)),
    ("claude-opus", (5, 25, 0.5, 6.25)),
    ("claude-sonnet", (2, 10, 0.2, 2.5)),
    ("claude-haiku", (1, 5, 0.1, 1.25)),
    ("gpt-6-astra", (10, 50, 1.0, 12.5)),
    ("gpt-6-luna", (1, 5, 0.1, 1.25)),
    ("gpt-5.6", (4, 20, 0.4, 5.0)),
    ("gpt-6-sol", (4, 20, 0.4, 5.0)),
    ("gpt-reserve", (4, 20, 0.4, 5.0)),
    ("codex-auto-review", (4, 20, 0.4, 5.0)),
]


def model_price(model):
    for prefix, price in MODEL_PRICES:
        if model.startswith(prefix):
            return price
    return None


def api_cost(model, u):
    p = model_price(model)
    if p is None:
        return None
    u = {k: clamp_number(u.get(k, 0)) for k in FIELDS} if isinstance(u, dict) else empty_usage()
    pin, pout, pcr, pcw = p
    return (u["input"] * pin + u["output"] * pout + u["cacheRead"] * pcr
            + u["cacheWrite5m"] * pcw + u["cacheWrite1h"] * pin * 2) / 1e6


def model_display_name(mid):
    """"claude-fable-5-1" → "Fable 5.1", "gpt-6-astra" → "Astra 6"."""
    s = mid
    for pre in ("claude-", "gpt-"):
        if s.startswith(pre):
            s = s[len(pre):]
    parts = s.split("-")
    if parts and parts[0] == "codex":
        return "-".join(parts[1:])
    if parts and parts[0][:1].isdigit() and len(parts) >= 2:
        ver = parts.pop(0)
        name = parts.pop(0)
        return name.capitalize() + " " + ".".join([ver] + parts)
    name = parts.pop(0) if parts else mid
    return name.capitalize() if not parts else name.capitalize() + " " + ".".join(parts)


def last_days(n, now=None):
    """Local day keys for the last `n` calendar days, oldest first (DST-safe: noon steps)."""
    now = now or time.time()
    lt = time.localtime(now)
    noon = time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday, 12, 0, 0, 0, 0, -1))
    return [common.day_key(noon - back * 86400) for back in range(n - 1, -1, -1)]


def daily_usage(days, product, n, now=None):
    """Per-day rollup for the last `n` days (oldest first), per-model rows sorted by cost."""
    out = []
    for key in last_days(n, now):
        models = days.get(product, {}).get(key, {})
        rows, usd, tokens, turns = [], 0.0, 0, 0
        for m, u in models.items():
            if m == "?":
                continue
            c = api_cost(m, u) or 0.0
            rows.append((m, total_tokens(u), c))
            usd = clamp_number(usd + c)
            tokens = clamp_number(tokens + total_tokens(u))
            turns = clamp_number(turns + clamp_number(u.get("turns", 0)))
        rows.sort(key=lambda r: -r[2])
        out.append({"day": key, "byModel": rows, "usd": usd, "tokens": tokens, "turns": turns})
    return out


def subscription_usd(product, plan, tier=None):
    """Monthly subscription price in USD — the user's own setting first, else an inference
    from the plan the backend reports. Returns (usd, estimated)."""
    st = common.settings()
    key = "subClaude" if product == "claude" else "subCodex"
    if st.has(key):
        try:
            value = st.get(key)
            return clamp_number(value if isinstance(value, int) else float(value)), False
        except (TypeError, ValueError, OverflowError):
            pass
    if product == "claude":
        tier = tier or common.state().get("claudeTier") or ""
        if "max_20x" in tier:
            return 200.0, False
        if "max_5x" in tier:
            return 100.0, False
        if "pro" in tier or plan == "pro":
            return 20.0, False
        return 200.0, True
    return {"free": (0.0, False), "go": (8.0, False), "plus": (20.0, False),
            "pro": (200.0, True)}.get(plan or "", (100.0, True))


def money_summary(days, product, plan, n=35, now=None):
    rows = daily_usage(days, product, n, now)
    active = [r for r in rows if r["turns"] > 0]
    total = clamp_number(sum(r["usd"] for r in rows))
    sub, est = subscription_usd(product, plan)
    return {
        "days": n, "activeDays": len(active), "usdApi": total,
        "perCalendarDay": total / n, "perActiveDay": total / len(active) if active else 0.0,
        "subMonthly": sub, "subEstimated": est,
        "subPerDay": sub / 30, "subPerWeek": sub * 12 / 52,
        "ratio": clamp_number(total / max(sub * n / 30, 1e-300)) if sub > 0 else 0.0,
    }
