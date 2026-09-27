"""Live limits: Claude Code (Anthropic OAuth usage) and Codex (ChatGPT backend) — port of
`fetchClaude()`, `codexUsageLive()`, `codexFromRollout()`, the cache, history and pace.

Tokens are read from the CLIs' own files and never printed or logged:
  • Claude: ~/.claude/.credentials.json → claudeAiOauth.{accessToken, refreshToken, expiresAt}
  • Codex:  ~/.codex/auth.json → tokens.{access_token, refresh_token, account_id}

Refresh tokens are single-use (they rotate). A refresh therefore happens only when the access
token is (nearly) dead, and the new pair is written back atomically with the file's other fields
untouched — otherwise the CLI on this machine would be signed out. A refresh token the server has
already refused is never sent again (its fingerprint is remembered, like `deadRefresh` on the Mac).
"""

import base64
import hashlib
import json
import os
import time

from . import common

CLAUDE_CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
CLAUDE_UA = "claude-cli/2.1.81 (external, cli)"
CODEX_CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"   # openai/codex login::CLIENT_ID
CODEX_UA = "codex_cli_rs/0.20.0 (Linux; x86_64)"

# auth states (only Claude uses anything but "ok")
OK, LOGGED_OUT, EXPIRED, READ_ERROR = "ok", "loggedOut", "expired", "readError"


class Scoped(object):
    """A weekly limit scoped to one model (`limits[].kind == "weekly_scoped"`), e.g. Fable."""
    __slots__ = ("name", "percent", "reset", "severity")

    def __init__(self, name, percent, reset=None, severity=None):
        self.name, self.percent, self.reset, self.severity = name, percent, reset, severity


class LimitData(object):
    def __init__(self):
        self.session = None          # % used, 5-hour window
        self.weekly = None           # % used, 7-day window
        self.session_reset = None    # epoch
        self.weekly_reset = None
        self.scoped = None           # Scoped
        self.plan = None
        self.reset_credits = None    # Codex banked resets
        self.as_of = None
        self.error = None
        self.stale = False
        self.from_cache = False
        self.present = True          # False → product not set up on this machine
        self.auth = OK

    def to_dict(self):
        m = {}
        for k, key in (("session", "session"), ("weekly", "weekly"), ("session_reset", "sReset"),
                       ("weekly_reset", "wReset"), ("plan", "plan"), ("reset_credits", "resetCredits"),
                       ("as_of", "asOf")):
            v = getattr(self, k)
            if v is not None:
                m[key] = v
        if self.scoped:
            s = {"name": self.scoped.name, "percent": self.scoped.percent}
            if self.scoped.reset is not None:
                s["reset"] = self.scoped.reset
            if self.scoped.severity:
                s["severity"] = self.scoped.severity
            m["scoped"] = s
        return m

    @classmethod
    def from_dict(cls, m):
        d = cls()
        d.session, d.weekly = m.get("session"), m.get("weekly")
        d.session_reset, d.weekly_reset = m.get("sReset"), m.get("wReset")
        d.plan, d.reset_credits, d.as_of = m.get("plan"), m.get("resetCredits"), m.get("asOf")
        s = m.get("scoped")
        if isinstance(s, dict) and s.get("name") and s.get("percent") is not None:
            d.scoped = Scoped(s["name"], s["percent"], s.get("reset"), s.get("severity"))
        d.from_cache = True
        return d


def _num(v):
    if isinstance(v, bool):
        return None
    if isinstance(v, (int, float)):
        return float(v)
    return None


def _fingerprint(s):
    """One-way fingerprint — only ever answers "is this the token the server already refused?"."""
    return hashlib.sha256(s.encode("utf-8")).hexdigest()[:16]


def _rewrite_json(path, obj):
    """Atomic rewrite keeping the file's permission bits (0600 at most)."""
    try:
        mode = os.stat(path).st_mode & 0o777
    except OSError:
        mode = 0o600
    common.write_atomic(path, json.dumps(obj, indent=2, ensure_ascii=False), mode & 0o600 or 0o600)


# ---- Claude Code ---------------------------------------------------------------------------

def fetch_claude():
    d = LimitData()
    st = common.state()
    path = common.CLAUDE_CREDENTIALS
    if not os.path.exists(path):
        d.auth = LOGGED_OUT
        return d
    try:
        with open(path, "rb") as f:
            creds = json.loads(f.read().decode("utf-8"))
    except (OSError, ValueError):
        d.auth = READ_ERROR
        d.error = "credentials read failed"
        return d
    oauth = creds.get("claudeAiOauth") if isinstance(creds, dict) else None
    if not isinstance(oauth, dict):
        d.auth = LOGGED_OUT
        return d

    d.plan = oauth.get("subscriptionType")
    tier = oauth.get("rateLimitTier")
    if tier and st.get("claudeTier") != tier:
        st.set("claudeTier", tier)
    at = oauth.get("accessToken") or ""
    exp = _num(oauth.get("expiresAt")) or 0.0
    now_ms = time.time() * 1000

    # A token that expires in under two minutes is treated as spent — a reading started now
    # could outlive it. `usable`: is there still something to ask with if the refresh fails?
    if not at or exp - now_ms < 120000:
        usable = bool(at) and exp > now_ms
        rt = oauth.get("refreshToken") or ""
        if not rt:
            if not usable:
                d.auth, d.error = EXPIRED, "no refresh token"
                return d
        else:
            fp = _fingerprint(rt)
            refused = st.get("deadRefresh") == fp
            if not refused:
                r = common.http("https://api.anthropic.com/v1/oauth/token", "POST",
                                {"Content-Type": "application/json", "User-Agent": CLAUDE_UA,
                                 "Accept": "application/json"},
                                {"grant_type": "refresh_token", "refresh_token": rt, "client_id": CLAUDE_CLIENT_ID})
                tok = r.json() if r.status == 200 else None
                if isinstance(tok, dict) and tok.get("access_token"):
                    at = tok["access_token"]
                    _save_claude_tokens(path, rt, tok)
                    st.remove("deadRefresh")
                else:
                    err = (r.json() or {}).get("error") if r.data else None
                    if err == "invalid_grant" or r.status in (400, 401):
                        st.set("deadRefresh", fp)
                        refused = True
                    elif not usable:
                        d.auth, d.error = EXPIRED, "refresh failed (HTTP %d)" % r.status
                        return d
            if refused and not usable:
                d.auth, d.error = EXPIRED, "sign-in expired"
                return d

    r = common.http("https://api.anthropic.com/api/oauth/usage", "GET",
                    {"Authorization": "Bearer " + at, "User-Agent": CLAUDE_UA, "Accept": "application/json",
                     "anthropic-beta": "oauth-2025-04-20", "anthropic-version": "2023-06-01"})
    j = r.json() if r.status == 200 else None
    if not isinstance(j, dict):
        if r.status == 401:
            d.auth = EXPIRED
        d.error = ("usage HTTP %d" % r.status) if r.status else (r.error or "network")
        return d
    _apply_claude_usage(d, j)
    d.as_of = time.time()
    return d


def _save_claude_tokens(path, old_rt, tok):
    """Write the rotated pair back — re-reading the file first so nothing the CLI wrote in the
    meantime is lost, and only if the file still holds the refresh token we just spent."""
    try:
        with open(path, "rb") as f:
            creds = json.loads(f.read().decode("utf-8"))
    except (OSError, ValueError):
        return
    oauth = creds.get("claudeAiOauth")
    if not isinstance(oauth, dict) or oauth.get("refreshToken") != old_rt:
        return                      # the CLI refreshed on its own meanwhile — its pair wins
    oauth["accessToken"] = tok["access_token"]
    if tok.get("refresh_token"):
        oauth["refreshToken"] = tok["refresh_token"]
    oauth["expiresAt"] = int((time.time() + float(tok.get("expires_in") or 28800)) * 1000)
    creds["claudeAiOauth"] = oauth
    _rewrite_json(path, creds)


def _apply_claude_usage(d, j):
    fh = j.get("five_hour")
    if isinstance(fh, dict):
        d.session = _num(fh.get("utilization"))
        d.session_reset = common.parse_iso(fh.get("resets_at"))
    sd = j.get("seven_day")
    if isinstance(sd, dict):
        d.weekly = _num(sd.get("utilization"))
        d.weekly_reset = common.parse_iso(sd.get("resets_at"))
    limits = j.get("limits")
    if isinstance(limits, list):
        ents = [e for e in limits if isinstance(e, dict)]
        for e in ents:
            if e.get("kind") == "session":
                if d.session is None:
                    d.session = _num(e.get("percent"))
                if d.session_reset is None:
                    d.session_reset = common.parse_iso(e.get("resets_at"))
            elif e.get("kind") == "weekly_all":
                if d.weekly is None:
                    d.weekly = _num(e.get("percent"))
                if d.weekly_reset is None:
                    d.weekly_reset = common.parse_iso(e.get("resets_at"))
        # the one that actually constrains you: the backend's own is_active, else the highest %
        scoped = [e for e in ents if e.get("kind") == "weekly_scoped"]
        chosen = next((e for e in scoped if e.get("is_active") is True), None)
        if chosen is None and scoped:
            chosen = max(scoped, key=lambda e: _num(e.get("percent")) or 0)
        if chosen is not None:
            name = (((chosen.get("scope") or {}).get("model") or {}).get("display_name"))
            p = _num(chosen.get("percent"))
            if name and p is not None:
                d.scoped = Scoped(name, p, common.parse_iso(chosen.get("resets_at")), chosen.get("severity"))
                if common.state().get("scopedName") != name:
                    common.state().set("scopedName", name)


# ---- Codex ---------------------------------------------------------------------------------

def codex_apply_window(win, d, positional_weekly):
    """Assign a window to Session or Week by its DURATION (≥ 2 days ⇒ weekly), whichever slot
    the backend put it in; positional guess only when the duration is absent."""
    used = _num(win.get("used_percent"))
    reset = _num(win.get("reset_at"))
    if reset is None:
        reset = _num(win.get("resets_at"))
    dur = _num(win.get("limit_window_seconds"))
    if dur is None and _num(win.get("window_minutes")) is not None:
        dur = _num(win.get("window_minutes")) * 60
    weekly = dur >= 2 * 86400 if dur is not None else positional_weekly
    if weekly:
        if used is not None:
            d.weekly = used
        if reset is not None:
            d.weekly_reset = reset
    else:
        if used is not None:
            d.session = used
        if reset is not None:
            d.session_reset = reset


def _rollout_files():
    out = []
    for root, _dirs, files in os.walk(common.CODEX_SESSIONS):
        for fn in files:
            if fn.endswith(".jsonl") and fn.startswith("rollout-"):
                p = os.path.join(root, fn)
                try:
                    out.append((os.stat(p).st_mtime, p))
                except OSError:
                    pass
    out.sort(reverse=True)
    return out


def codex_from_rollout():
    d = LimitData()
    if not os.path.isdir(common.CODEX_SESSIONS):
        d.present = False
        return d
    files = _rollout_files()
    if not files:
        d.error = "no Codex rollout files"
        return d
    best_ts, best_rl, last_plan, last_plan_ts = "", None, None, ""
    for _m, path in files[:6]:
        try:
            with open(path, "rb") as f:
                # the newest reading is near the end: read the tail only
                f.seek(0, 2)
                size = f.tell()
                f.seek(max(0, size - 4 * 1024 * 1024))
                tail = f.read()
        except OSError:
            continue
        for line in tail.split(b"\n"):
            if b'"rate_limits"' not in line:
                continue
            try:
                o = json.loads(line)
            except ValueError:
                continue
            ts = o.get("timestamp") if isinstance(o, dict) else None
            p = o.get("payload") if isinstance(o, dict) else None
            rl = p.get("rate_limits") if isinstance(p, dict) else None
            if not isinstance(ts, str) or not isinstance(rl, dict):
                continue
            if ts > best_ts:
                best_ts, best_rl = ts, rl
            if isinstance(rl.get("plan_type"), str) and ts > last_plan_ts:
                last_plan_ts, last_plan = ts, rl["plan_type"]
    if best_rl is None:
        d.error = "no limits in rollout"
        return d
    if isinstance(best_rl.get("primary"), dict):
        codex_apply_window(best_rl["primary"], d, False)
    if isinstance(best_rl.get("secondary"), dict):
        codex_apply_window(best_rl["secondary"], d, True)
    d.plan = best_rl.get("plan_type") or last_plan
    d.as_of = common.parse_iso(best_ts)
    if d.as_of and time.time() - d.as_of > 2 * 3600:
        d.stale = True
    return d


def _jwt_exp(jwt):
    parts = jwt.split(".")
    if len(parts) < 2:
        return None
    p = parts[1] + "=" * (-len(parts[1]) % 4)
    try:
        return _num(json.loads(base64.urlsafe_b64decode(p.encode()).decode()).get("exp"))
    except (ValueError, TypeError, AttributeError):
        return None


def codex_access_token():
    """(access_token, account_id) from ~/.codex/auth.json, refreshed through the official
    OpenAI token endpoint (and written back) if it has expired."""
    root = common.read_json(common.CODEX_AUTH)
    if not isinstance(root, dict):
        return None
    tokens = root.get("tokens")
    if not isinstance(tokens, dict):
        return None
    acc, at = tokens.get("account_id"), tokens.get("access_token")
    if not acc or not at:
        return None
    exp = _jwt_exp(at)
    if exp is not None and exp > time.time() + 60:
        return at, acc
    rt = tokens.get("refresh_token")
    if not rt:
        return None
    st = common.state()
    fp = _fingerprint(rt)
    if st.get("deadCodexRefresh") == fp:
        return None
    r = common.http("https://auth.openai.com/oauth/token", "POST",
                    {"Content-Type": "application/json", "Accept": "application/json", "User-Agent": CODEX_UA},
                    {"client_id": CODEX_CLIENT_ID, "grant_type": "refresh_token", "refresh_token": rt})
    tok = r.json() if r.status == 200 else None
    if not isinstance(tok, dict) or not tok.get("access_token"):
        if r.status in (400, 401):
            st.set("deadCodexRefresh", fp)
        return None
    # re-read and write back only if the CLI hasn't rotated the pair itself meanwhile
    root = common.read_json(common.CODEX_AUTH)
    if isinstance(root, dict) and isinstance(root.get("tokens"), dict) and root["tokens"].get("refresh_token") == rt:
        root["tokens"]["access_token"] = tok["access_token"]
        for k in ("id_token", "refresh_token"):
            if tok.get(k):
                root["tokens"][k] = tok[k]
        root["last_refresh"] = common.iso_utc()
        _rewrite_json(common.CODEX_AUTH, root)
    return tok["access_token"], acc


def codex_usage_live():
    got = codex_access_token()
    if not got:
        return None
    at, acc = got
    r = common.http("https://chatgpt.com/backend-api/wham/usage", "GET",
                    {"Authorization": "Bearer " + at, "chatgpt-account-id": acc, "User-Agent": CODEX_UA,
                     "originator": "codex_cli_rs", "Accept": "application/json"})
    obj = r.json() if r.status == 200 else None
    if not isinstance(obj, dict) or not isinstance(obj.get("rate_limit"), dict):
        return None
    rl = obj["rate_limit"]
    d = LimitData()
    if isinstance(rl.get("primary_window"), dict):
        codex_apply_window(rl["primary_window"], d, False)
    if isinstance(rl.get("secondary_window"), dict):
        codex_apply_window(rl["secondary_window"], d, True)
    d.plan = obj.get("plan_type")
    rc = obj.get("rate_limit_reset_credits")
    if isinstance(rc, dict) and isinstance(rc.get("available_count"), int):
        d.reset_credits = rc["available_count"]
    d.as_of = time.time()
    return d


def fetch_codex(live=True):
    rollout = codex_from_rollout()
    if not rollout.present:
        return rollout
    if live:
        d = codex_usage_live()
        if d is not None:
            return d
    best = rollout
    cached = (common.read_json(common.CACHE_PATH, {}) or {}).get("codex")
    if isinstance(cached, dict):
        c = LimitData.from_dict(cached)
        if (c.as_of or 0) > (best.as_of or 0):
            best = c
            best.present, best.from_cache = True, False
    if best.as_of and time.time() - best.as_of > 2 * 3600:
        best.stale = True
    return best


# ---- cache ---------------------------------------------------------------------------------

def apply_cache(claude, codex):
    """Restore last-known numbers behind an error flag; persist only genuinely good readings."""
    cache = common.read_json(common.CACHE_PATH, {})
    if not isinstance(cache, dict):
        cache = {}
    if claude.present and claude.error is not None and isinstance(cache.get("claude"), dict):
        e, a = claude.error, claude.auth
        claude = LimitData.from_dict(cache["claude"])
        claude.error, claude.auth = e, a
    if codex.present and codex.error is not None and isinstance(cache.get("codex"), dict):
        e = codex.error
        codex = LimitData.from_dict(cache["codex"])
        codex.error = e
    changed = False
    if claude.present and claude.error is None and claude.auth == OK and not claude.from_cache:
        cache["claude"] = claude.to_dict()
        changed = True
    if codex.present and codex.error is None and not codex.from_cache:
        cache["codex"] = codex.to_dict()
        changed = True
    if changed:
        common.ensure_dirs()
        common.write_json(common.CACHE_PATH, cache)
    return claude, codex


def is_stale(d, now=None):
    """True when a card shows a frozen / aged snapshot instead of live data."""
    if not d.present:
        return False
    now = now or time.time()
    if d.session_reset and d.session_reset < now - 120:
        return True
    if d.weekly_reset and d.weekly_reset < now - 120:
        return True
    age = now - d.as_of if d.as_of else float("inf")
    if d.error is not None or d.stale:
        return age > 15 * 60
    return age > 3600


def severity(v):
    if v is None:
        return 0
    return 2 if v >= 80 else 1 if v >= 50 else 0


# ---- utilization history (feeds "recent pace" and the first-day notice) --------------------

HISTORY_KEEP_DAYS = 35


class History(object):
    def __init__(self):
        self.samples = []

    def load(self):
        cutoff = time.time() - HISTORY_KEEP_DAYS * 86400
        out = []
        try:
            with open(common.HISTORY_PATH, "rb") as f:
                for line in f:
                    try:
                        o = json.loads(line)
                    except ValueError:
                        continue
                    if isinstance(o, dict) and _num(o.get("t")) and o["t"] >= cutoff and o.get("p"):
                        out.append(o)
        except OSError:
            pass
        self.samples = out
        try:
            common.write_atomic(common.HISTORY_PATH, "".join(json.dumps(s) + "\n" for s in out))
        except OSError:
            pass

    def record(self, d, product):
        if not d.present or d.error is not None or d.auth != OK or d.from_cache:
            return
        if d.session is None and d.weekly is None:
            return
        s = {"t": time.time(), "p": product}
        for k, v in (("s", d.session), ("w", d.weekly), ("sr", d.session_reset), ("wr", d.weekly_reset)):
            if v is not None:
                s[k] = v
        if d.scoped:
            s["m"], s["mn"] = d.scoped.percent, d.scoped.name
        self.samples.append(s)
        try:
            common.ensure_dirs()
            with open(common.HISTORY_PATH, "a") as f:
                f.write(json.dumps(s) + "\n")
        except OSError:
            pass

    def first(self, product):
        for s in self.samples:
            if s["p"] == product:
                return s["t"]
        return None

    def recent_rate(self, product, key, minutes):
        since = time.time() - minutes * 60
        pts = [(s["t"], s[key]) for s in self.samples if s["p"] == product and s["t"] >= since and key in s]
        if len(pts) < 2 or pts[-1][0] - pts[0][0] < 600:
            return None
        dv = pts[-1][1] - pts[0][1]
        if dv < 0:
            return None
        return dv / ((pts[-1][0] - pts[0][0]) / 3600)


# ---- pace ----------------------------------------------------------------------------------

class WindowPace(object):
    """Where a linear plan (0% at open → 100% at reset) says you should be, how far off you are,
    the average burn since the window opened, and whether the window lasts to its reset."""

    def __init__(self, used, reset, window_h, recent_rate=None, now=None):
        now = now or time.time()
        self.used, self.reset, self.window_h = used, reset, window_h
        self.start = reset - window_h * 3600
        self.elapsed_h = max(0.0, min(window_h, (now - self.start) / 3600))
        frac = self.elapsed_h / window_h
        self.plan_pct = frac * 100
        self.delta_pts = used - self.plan_pct
        early = self.elapsed_h < 10.0 / 60
        self.avg_rate_h = 0.0 if early else used / self.elapsed_h
        self.projected = None if early or frac <= 0 else used / frac
        self.remaining_h = window_h - self.elapsed_h
        self.runs_out_at = None
        if self.avg_rate_h > 0:
            at = self.start + 100 / self.avg_rate_h * 3600
            if at < reset:
                self.runs_out_at = at
        if used >= 100:
            self.runs_out_at = now
        self.recent_rate_h = recent_rate

    @property
    def severity(self):
        if self.runs_out_at is not None:
            return 2
        if self.projected is not None and self.projected >= 85:
            return 1
        return 0


def window_pace(used, reset, window_h, recent_rate=None, now=None):
    if used is None or reset is None:
        return None
    return WindowPace(used, reset, window_h, recent_rate, now)


def paced_limits(d, product, history=None):
    """The windows the Advanced view lists for a product, in display order:
    session → per-model week → all-models week. Codex shows a session row only if the
    backend reports one."""
    h = history
    rr = (lambda k, mins: h.recent_rate(product, k, mins)) if h else (lambda k, mins: None)
    out = []
    if product == "claude" or d.session is not None:
        out.append({"id": "session", "name": common.tr("Сессия · 5 ч", "Session · 5 h"), "color": 0,
                    "pace": window_pace(d.session, d.session_reset, 5, rr("s", 60))})
    if d.scoped:
        out.append({"id": "scoped", "name": common.tr("Неделя · ", "Week · ") + d.scoped.name, "color": 2,
                    "pace": window_pace(d.scoped.percent, d.scoped.reset, 168, rr("m", 180))})
    out.append({"id": "weekly", "color": 1,
                "name": common.tr("Неделя · все модели", "Week · all models") if product == "claude" else common.tr("Неделя", "Week"),
                "pace": window_pace(d.weekly, d.weekly_reset, 168, rr("w", 180))})
    return out
