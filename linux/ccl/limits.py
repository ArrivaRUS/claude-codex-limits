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
import contextlib
import hashlib
import json
import os
import re
import time
import math
import threading

from . import common
from . import quota_refresh
from . import accounts

CLAUDE_CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
CLAUDE_UA = "claude-cli/2.1.81 (external, cli)"
CODEX_CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"   # openai/codex login::CLIENT_ID
CODEX_UA = "codex_cli_rs/0.20.0 (Linux; x86_64)"
PROVIDER_MAX_BODY = 16 * 1024 * 1024

# Provider auth state is independent of snapshot age or network availability.
OK, LOGGED_OUT, EXPIRED, READ_ERROR = "ok", "loggedOut", "expired", "readError"


_ATTEMPT = threading.local()


@contextlib.contextmanager
def _credential_attempt(policy=None):
    """Pin one policy under quota, including nested token/save calls in this thread.

    An explicit policy is only used to finish a pair already rotated by this process.
    """
    current = getattr(_ATTEMPT, "policy", None)
    if current is not None:
        yield current
        return
    lock = (contextlib.nullcontext(True) if common.lock_held_by_thread("quota")
            else common.file_lock("quota", timeout=60))
    with contextlib.ExitStack() as stack:
        try:
            held = stack.enter_context(lock)
        except OSError:
            # Only acquisition failures belong here, not errors inside the attempt.
            raise common.CredentialPolicyRefused("quota unavailable; retry later") from None
        if not held:
            raise common.CredentialPolicyRefused("quota is busy; retry after the current attempt")
        _ATTEMPT.policy = common.credential_write() if policy is None else policy
        try:
            yield _ATTEMPT.policy
        finally:
            del _ATTEMPT.policy


def _write_allowed(product=None):
    """Called only inside an attempt; never re-read settings halfway through it."""
    if _ATTEMPT.policy == "guarded":
        return True
    common.credential_policy_event("policy_violation", product=product, policy="never")
    return False


def _quota_busy(data):
    data.auth, data.expired_reason = OK, None
    data.error = "quota is busy or unavailable; retry later"
    data.failure_kind, data.poll_failed, data.api_fresh = "busy", True, False
    data._signed_out_no_values = False
    return data


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
        self.poll_failed = False     # transient last-request status, not part of snapshot/cache
        self.next_poll_at = None
        self.server_retry_at = None  # actual Retry-After deadline; None means unknown
        self.http_status = None      # sanitized current-attempt metadata, never cached
        self.failure_kind = None     # network/http/auth/credentials/invalid_response/busy
        self.refresh_in_flight = False
        self.local_retry_at = 0
        self.api_fresh = False       # only successful live usage responses
        self.present = True          # False → product not set up on this machine
        self.auth = OK
        self.expired_reason = None
        self.account = None          # local identity captured before provider I/O
        self._cli_refresh_available = False
        self._signed_out_no_values = False

    def to_dict(self):
        m = {}
        for k, key in (("session", "session"), ("weekly", "weekly"), ("session_reset", "sReset"),
                       ("weekly_reset", "wReset"), ("plan", "plan"), ("reset_credits", "resetCredits"),
                       ("as_of", "asOf"), ("expired_reason", "expiredReason")):
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
        if m.get("expiredReason") in ("cli_refresh_pending", "signin_required"):
            d.expired_reason = m["expiredReason"]
        s = m.get("scoped")
        if isinstance(s, dict) and s.get("name") and s.get("percent") is not None:
            d.scoped = Scoped(s["name"], s["percent"], s.get("reset"), s.get("severity"))
        d.from_cache = True
        return d


def selected_limits(data, product):
    if common.product_enabled(product):
        return data
    return absent_limits()


def absent_limits():
    data = LimitData()
    data.present = False
    return data


def _credential_failure(data, auth, message):
    data.auth, data.error = auth, message
    data.expired_reason = "signin_required" if auth == EXPIRED else None
    data._signed_out_no_values = (auth == LOGGED_OUT
                                  and getattr(_ATTEMPT, "policy", None) == "never")
    data.poll_failed = True
    data.failure_kind = "credentials" if auth == READ_ERROR else "auth"
    return data


def _cli_expired(data):
    """Read-only attempts leave renewal to the CLI, without marking refresh dead."""
    _credential_failure(data, EXPIRED, "CLI credentials expired")
    if data._cli_refresh_available:
        data.expired_reason = "cli_refresh_pending"
    return data


def _read_login(path, data):
    """Read an initial CLI snapshot; retry partial writes independently of save-back."""
    for attempt in range(5):
        try:
            with open(path, "rb") as stream:
                root = json.loads(stream.read().decode("utf-8"))
            if not isinstance(root, dict):
                raise ValueError("invalid credentials shape")
            return root
        except FileNotFoundError:
            _credential_failure(data, LOGGED_OUT, "CLI sign-in required")
            return None
        except (OSError, ValueError, RecursionError):
            if attempt < 4:
                time.sleep(0.2)
    _credential_failure(data, READ_ERROR, "credentials read failed")
    return None


def _rotation_failure(data, outcome):
    if outcome == "superseded":
        data.error, data.failure_kind, data.poll_failed = "CLI credentials changed; retry", "credentials", True
        return data
    return _credential_failure(data, READ_ERROR, "credentials update unavailable")


def _prepare_rotation(product, data):
    """A marker failure must not spend a single-use refresh token."""
    try:
        common.write_rotation_marker(product)
        return True
    except (OSError, ValueError):
        _rotation_failure(data, "pending")
        return False


def _credential_block_complete(block, keys):
    """Only a complete identity can prove that the CLI replaced a pending pair."""
    return isinstance(block, dict) and all(
        isinstance(block.get(key), str) and bool(block[key].strip()) for key in keys)


def _token_response_usable(tok):
    """A missing/empty refresh keeps the current one; a supplied one must be valid."""
    return (_credential_block_complete(tok, ("access_token",))
            and (tok.get("refresh_token") in (None, "")
                 or _credential_block_complete(tok, ("refresh_token",))))


def _http_failure(data, response, token_endpoint=False):
    # Do not expose response bodies, headers, exception text or credentials to UI/cache.
    body = response.json() if token_endpoint else None
    error = body.get("error") if isinstance(body, dict) else None
    if isinstance(error, dict):
        error = error.get("type")
    failure = quota_refresh.http_failure(response.status, response.headers, time.time(),
                                         token_endpoint=token_endpoint, oauth_error=error)
    data.http_status, data.server_retry_at = failure.status, failure.retry_at
    data.auth = EXPIRED if failure.authentication_required else OK
    data.expired_reason = None
    if failure.authentication_required:
        data.expired_reason = ("cli_refresh_pending" if not token_endpoint
                               and getattr(_ATTEMPT, "policy", None) == "never"
                               and data._cli_refresh_available else "signin_required")
    data.failure_kind = ("auth" if failure.authentication_required else
                         "network" if not response.status else
                         "invalid_response" if response.status == 200 else "http")
    data.error = ("network unavailable" if not response.status else
                  "invalid response" if response.status == 200 else "HTTP %d" % response.status)
    data.poll_failed = True
    return data


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
    with _credential_attempt():
        if not _write_allowed():
            raise common.CredentialPolicyRefused("credential writing is disabled")
        _rewrite_json_guarded(path, obj)


def _rewrite_json_guarded(path, obj):
    try:
        mode = os.stat(path).st_mode & 0o777
    except OSError:
        mode = 0o600
    common.write_atomic(path, json.dumps(obj, indent=2, ensure_ascii=False), mode & 0o600 or 0o600)


# ---- Claude Code ---------------------------------------------------------------------------

def fetch_claude():
    try:
        with _credential_attempt():
            return _fetch_claude()
    except common.CredentialPolicyRefused:
        return _quota_busy(LimitData())


def _fetch_claude():
    if not common.product_enabled("claude"):
        return absent_limits()
    d = LimitData()
    st = common.state()
    path = common.CLAUDE_CREDENTIALS
    creds = _read_login(path, d)
    if creds is None:
        return d
    oauth = creds.get("claudeAiOauth")
    if not isinstance(oauth, dict):
        return _credential_failure(d, LOGGED_OUT, "CLI sign-in required")
    d.account, _ = accounts.read_local_id("claude")

    p = _PENDING.get("claude") if _ATTEMPT.policy == "guarded" else None
    if p is not None:
        if not _credential_block_complete(oauth, ("accessToken", "refreshToken")):
            return _rotation_failure(d, "pending")
        if oauth.get("refreshToken") == p["old"]:
            outcome = _save_claude_tokens(path, p["old"], p["tok"], p["t"], creds)
            if outcome != "saved":
                return _rotation_failure(d, outcome)
            _claude_apply_pair(oauth, p["tok"], p["t"])
        else:
            with contextlib.suppress(OSError):
                common.remove_rotation_marker("claude")
            _PENDING.pop("claude", None)

    if oauth.get("refreshToken") and not _credential_block_complete(oauth, ("accessToken", "refreshToken")):
        return _credential_failure(d, LOGGED_OUT, "CLI sign-in required")
    d.plan = oauth.get("subscriptionType")
    tier = oauth.get("rateLimitTier")
    if tier and st.get("claudeTier") != tier:
        st.set("claudeTier", tier)
    at = oauth.get("accessToken") or ""
    exp = _num(oauth.get("expiresAt")) or 0.0
    now_ms = time.time() * 1000
    refresh_exp = _num(oauth.get("refreshTokenExpiresAt"))
    d._cli_refresh_available = bool(oauth.get("refreshToken")) and (
        refresh_exp is None or refresh_exp > now_ms)

    # A token that expires in under two minutes is treated as spent — a reading started now
    # could outlive it. `usable`: is there still something to ask with if the refresh fails?
    if not at or exp - now_ms < 120000:
        if _ATTEMPT.policy != "guarded":
            return _cli_expired(d)
        usable = bool(at) and exp > now_ms
        rt = oauth.get("refreshToken") or ""
        if not rt:
            if not usable:
                return _credential_failure(d, EXPIRED, "no refresh token")
        else:
            fp = _fingerprint(rt)
            refused = st.get("deadRefresh") == fp
            if not refused:
                if not _prepare_rotation("claude", d):
                    return d
                r = common.http("https://api.anthropic.com/v1/oauth/token", "POST",
                                {"Content-Type": "application/json", "User-Agent": CLAUDE_UA,
                                 "Accept": "application/json"},
                                {"grant_type": "refresh_token", "refresh_token": rt, "client_id": CLAUDE_CLIENT_ID},
                                follow_redirects=False, max_body=PROVIDER_MAX_BODY)
                tok = r.json() if r.status == 200 else None
                if _token_response_usable(tok):
                    at = tok["access_token"]
                    outcome = _save_claude_tokens(path, rt, tok, time.time(), creds)
                    if outcome != "saved":
                        return _rotation_failure(d, outcome)
                    with contextlib.suppress(OSError):
                        st.remove("deadRefresh")
                else:
                    with contextlib.suppress(OSError):
                        common.remove_rotation_marker("claude")
                    body = r.json()
                    err = body.get("error") if isinstance(body, dict) else None
                    if isinstance(err, dict):
                        err = err.get("type")
                    if err == "invalid_grant" or r.status == 401:
                        with contextlib.suppress(OSError):
                            st.set("deadRefresh", fp)
                    # Preserve the actual refresh failure, including a server deadline.
                    # A timeout/429/5xx or generic 400 does not prove revoked credentials.
                    return _http_failure(d, r, token_endpoint=True)
            if refused and not usable:
                return _credential_failure(d, EXPIRED, "sign-in expired")

    r = common.http("https://api.anthropic.com/api/oauth/usage", "GET",
                    {"Authorization": "Bearer " + at, "User-Agent": CLAUDE_UA, "Accept": "application/json",
                     "anthropic-beta": "oauth-2025-04-20", "anthropic-version": "2023-06-01"},
                    follow_redirects=False, max_body=PROVIDER_MAX_BODY)
    j = r.json() if r.status == 200 else None
    if not isinstance(j, dict):
        return _http_failure(d, r)
    _apply_claude_usage(d, j)
    if not quota_refresh.has_readings(d):
        return _http_failure(d, r)
    d.as_of = time.time()
    d.api_fresh = True
    return d


# A refreshed pair that could not be written back yet (file unreadable mid-write, disk full…).
# The server has already rotated the refresh token, so losing this pair would sign the CLI out:
# it is kept in memory and write-back is retried against the same credential identity.
# An unreadable/missing current record never authorizes writing an older snapshot.
_PENDING = {}


def flush_pending():
    """At graceful exit, try each rotated pair once under its original policy.

    Only entries produced by a guarded save authorize finishing a rotation after
    settings changed. No token endpoint is called, and stale documents never win.
    """
    try:
        with _credential_attempt(policy="guarded"):
            for product, pending in list(_PENDING.items()):
                outcome = "pending"
                try:
                    if pending.get("policy") == "guarded":
                        if product == "claude":
                            outcome = _save_claude_tokens(
                                pending.get("path", common.CLAUDE_CREDENTIALS),
                                pending["old"], pending["tok"], pending["t"], {})
                        elif product == "codex":
                            outcome = _save_codex_tokens(pending["old"], pending["tok"], {})
                except (OSError, ValueError, KeyError, TypeError):
                    # Sanitized event below: never log token-bearing exception text.
                    pass
                finally:
                    if outcome not in ("saved", "superseded"):
                        common.credential_policy_event("pending_rotation_lost", product=product)
                    try:
                        common.remove_rotation_marker(product)
                    except OSError:
                        common.credential_policy_event("pending_rotation_lost", product=product)
                    finally:
                        _PENDING.pop(product, None)
    except (common.CredentialPolicyRefused, OSError):
        # Quota may be busy or inaccessible: never discard a worker's pair unlocked.
        for product in list(_PENDING):
            common.credential_policy_event("pending_rotation_lost", product=product)


def _read_json_retry(path, tries=5):
    for i in range(tries):
        try:
            with open(path, "rb") as f:
                return json.loads(f.read().decode("utf-8"))
        except (OSError, ValueError, RecursionError):
            if i + 1 < tries:
                time.sleep(0.2)
    return None


def _claude_apply_pair(oauth, tok, t):
    oauth["accessToken"] = tok["access_token"]
    if tok.get("refresh_token"):
        oauth["refreshToken"] = tok["refresh_token"]
    lifetime = tok.get("expires_in")
    # Validate before arithmetic: malformed expiry must not strand a rotated pair.
    if (isinstance(lifetime, bool) or not isinstance(lifetime, (int, float))
            or not 0 < lifetime <= 1e9):
        lifetime = 28800
    oauth["expiresAt"] = int((t + lifetime) * 1000)


def _save_claude_tokens(path, old_rt, tok, t, first):
    """Re-read/merge only the expected pair. Return saved/pending/superseded/refused.

    `first` supplies identity only, never a replacement document. This is not an
    atomic CAS with the external CLI: a writer after this read can still race replace.
    """
    try:
        with _credential_attempt():
            if not _write_allowed("claude"):
                return "refused"
            return _save_claude_tokens_guarded(path, old_rt, tok, t, first)
    except common.CredentialPolicyRefused:
        return "refused"


def _save_claude_tokens_guarded(path, old_rt, tok, t, first):
    initial = first.get("claudeAiOauth") if isinstance(first, dict) else None
    access = initial.get("accessToken") if isinstance(initial, dict) else None
    pending = _PENDING.get("claude")
    if pending is not None and pending["old"] == old_rt:
        access = pending.get("access", access)
    _PENDING["claude"] = {"old": old_rt, "access": access, "tok": tok, "t": t,
                          "policy": _ATTEMPT.policy, "path": path}
    # The token request reserved the marker; replay must not rewrite it after rotation.
    creds = _read_json_retry(path)
    oauth = creds.get("claudeAiOauth") if isinstance(creds, dict) else None
    if not _credential_block_complete(oauth, ("accessToken", "refreshToken")):
        return "pending"               # missing/corrupt/unreadable: do not resurrect it
    if oauth.get("refreshToken") != old_rt or oauth.get("accessToken") != access:
        with contextlib.suppress(OSError):
            common.remove_rotation_marker("claude")
        _PENDING.pop("claude", None)     # the CLI refreshed on its own meanwhile — its pair wins
        return "superseded"
    _claude_apply_pair(oauth, tok, t)
    try:
        _rewrite_json(path, creds)
        with contextlib.suppress(OSError):
            common.remove_rotation_marker("claude")
        _PENDING.pop("claude", None)
        common.o1_event("token_refresh", product="claude", credentialWrite=1, policy=_ATTEMPT.policy)
        return "saved"
    except OSError:
        return "pending"


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
                f.seek(max(0, size - 1024 * 1024))
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


def _codex_apply_pair(root, tok):
    for k in ("access_token", "id_token", "refresh_token"):
        if tok.get(k):
            root["tokens"][k] = tok[k]
    root["last_refresh"] = common.iso_utc()


def _save_codex_tokens(old_rt, tok, first):
    """Same guarded re-read/merge as Claude; never write a stale `first` document."""
    try:
        with _credential_attempt():
            if not _write_allowed("codex"):
                return "refused"
            return _save_codex_tokens_guarded(old_rt, tok, first)
    except common.CredentialPolicyRefused:
        return "refused"


def _save_codex_tokens_guarded(old_rt, tok, first):
    initial = first.get("tokens") if isinstance(first, dict) else None
    access = initial.get("access_token") if isinstance(initial, dict) else None
    account = initial.get("account_id") if isinstance(initial, dict) else None
    pending = _PENDING.get("codex")
    if pending is not None and pending["old"] == old_rt:
        access, account = pending.get("access", access), pending.get("account", account)
    _PENDING["codex"] = {"old": old_rt, "access": access, "account": account, "tok": tok,
                         "policy": _ATTEMPT.policy}
    # The token request reserved the marker; replay must not rewrite it after rotation.
    root = _read_json_retry(common.CODEX_AUTH)
    current = root.get("tokens") if isinstance(root, dict) else None
    if not _credential_block_complete(current, ("access_token", "refresh_token", "account_id")):
        return "pending"
    if (current.get("refresh_token") != old_rt or current.get("access_token") != access
            or current.get("account_id") != account):
        with contextlib.suppress(OSError):
            common.remove_rotation_marker("codex")
        _PENDING.pop("codex", None)
        return "superseded"
    _codex_apply_pair(root, tok)
    try:
        _rewrite_json(common.CODEX_AUTH, root)
        with contextlib.suppress(OSError):
            common.remove_rotation_marker("codex")
        _PENDING.pop("codex", None)
        common.o1_event("token_refresh", product="codex", credentialWrite=1, policy=_ATTEMPT.policy)
        return "saved"
    except OSError:
        return "pending"


def codex_access_token(result=None):
    """(access_token, account_id) from ~/.codex/auth.json, refreshed through the official
    OpenAI token endpoint (and written back) if it has expired.

    Optional result receives sanitized failure metadata; token return shape is unchanged.
    """
    result = result if result is not None else LimitData()
    try:
        with _credential_attempt():
            return _codex_access_token(result)
    except common.CredentialPolicyRefused:
        _quota_busy(result)
        return None


def _codex_access_token(result):
    if _ATTEMPT.policy == "guarded":
        root = common.read_json(common.CODEX_AUTH)
        if not isinstance(root, dict):
            _credential_failure(result, READ_ERROR if os.path.exists(common.CODEX_AUTH) else LOGGED_OUT,
                                "CLI credentials unavailable")
            return None
    else:
        root = _read_login(common.CODEX_AUTH, result)
    if root is None:
        return None
    tokens = root.get("tokens")
    if not isinstance(tokens, dict):
        _credential_failure(result, LOGGED_OUT, "CLI sign-in required")
        return None
    acc = tokens.get("account_id")
    # The provider needs the original id; normalization applies only to the local label.
    normalized_acc = acc.strip().lower() if isinstance(acc, str) else None
    if normalized_acc is not None and re.fullmatch(r"[0-9a-z-]{8,64}", normalized_acc) is None:
        normalized_acc = None
    result.account = normalized_acc or None
    result._cli_refresh_available = bool(tokens.get("refresh_token"))
    p = _PENDING.get("codex") if _ATTEMPT.policy == "guarded" else None
    if p is not None:
        if not _credential_block_complete(tokens, ("access_token", "refresh_token", "account_id")):
            _rotation_failure(result, "pending")
            return None
        if tokens.get("refresh_token") == p["old"]:
            outcome = _save_codex_tokens(p["old"], p["tok"], root)
            if outcome != "saved":
                _rotation_failure(result, outcome)
                return None
            _codex_apply_pair(root, p["tok"])
            tokens = root["tokens"]
        else:
            with contextlib.suppress(OSError):
                common.remove_rotation_marker("codex")
            _PENDING.pop("codex", None)
    at = tokens.get("access_token")
    if not _credential_block_complete(tokens, ("access_token", "account_id")):
        _credential_failure(result, LOGGED_OUT, "CLI sign-in required")
        return None
    exp = _jwt_exp(at)
    grace = 60 if _ATTEMPT.policy == "guarded" else 0
    if exp is not None and exp > time.time() + grace:
        return at, acc
    if _ATTEMPT.policy != "guarded":
        _cli_expired(result)
        return None
    rt = tokens.get("refresh_token")
    if not rt:
        _credential_failure(result, EXPIRED, "no refresh token")
        return None
    if not _credential_block_complete(tokens, ("access_token", "refresh_token", "account_id")):
        _credential_failure(result, LOGGED_OUT, "CLI sign-in required")
        return None
    st = common.state()
    fp = _fingerprint(rt)
    if st.get("deadCodexRefresh") == fp:
        _credential_failure(result, EXPIRED, "sign-in expired")
        return None
    if not _prepare_rotation("codex", result):
        return None
    r = common.http("https://auth.openai.com/oauth/token", "POST",
                    {"Content-Type": "application/json", "Accept": "application/json", "User-Agent": CODEX_UA},
                    {"client_id": CODEX_CLIENT_ID, "grant_type": "refresh_token", "refresh_token": rt},
                    follow_redirects=False, max_body=PROVIDER_MAX_BODY)
    tok = r.json() if r.status == 200 else None
    if not _token_response_usable(tok):
        with contextlib.suppress(OSError):
            common.remove_rotation_marker("codex")
        _http_failure(result, r, token_endpoint=True)
        if result.auth == EXPIRED:
            with contextlib.suppress(OSError):
                st.set("deadCodexRefresh", fp)
        return None
    outcome = _save_codex_tokens(rt, tok, root)
    if outcome != "saved":
        _rotation_failure(result, outcome)
        return None
    return tok["access_token"], acc


def codex_usage_live():
    """Always return LimitData, including the reason a live attempt failed."""
    try:
        with _credential_attempt():
            return _codex_usage_live()
    except common.CredentialPolicyRefused:
        return _quota_busy(LimitData())


def _codex_usage_live():
    d = LimitData()
    got = codex_access_token(d)
    if not got:
        return d
    at, acc = got
    r = common.http("https://chatgpt.com/backend-api/wham/usage", "GET",
                    {"Authorization": "Bearer " + at, "chatgpt-account-id": acc, "User-Agent": CODEX_UA,
                     "originator": "codex_cli_rs", "Accept": "application/json"},
                    follow_redirects=False, max_body=PROVIDER_MAX_BODY)
    obj = r.json() if r.status == 200 else None
    if not isinstance(obj, dict) or not isinstance(obj.get("rate_limit"), dict):
        return _http_failure(d, r)
    rl = obj["rate_limit"]
    if isinstance(rl.get("primary_window"), dict):
        codex_apply_window(rl["primary_window"], d, False)
    if isinstance(rl.get("secondary_window"), dict):
        codex_apply_window(rl["secondary_window"], d, True)
    d.plan = obj.get("plan_type")
    rc = obj.get("rate_limit_reset_credits")
    if isinstance(rc, dict) and isinstance(rc.get("available_count"), int):
        d.reset_credits = rc["available_count"]
    if not quota_refresh.has_readings(d):
        return _http_failure(d, r)
    d.as_of = time.time()
    d.api_fresh = True
    return d


def fetch_codex(live=True):
    if not live:
        return _fetch_codex(live=False)
    try:
        with _credential_attempt():
            return _fetch_codex(live=True)
    except common.CredentialPolicyRefused:
        return _quota_busy(LimitData())


def _fetch_codex(live=True):
    if not common.product_enabled("codex"):
        return absent_limits()
    if not os.path.isdir(common.CODEX_SESSIONS) and not os.path.exists(common.CODEX_AUTH):
        d = LimitData()
        if live:
            return _credential_failure(d, LOGGED_OUT, "CLI sign-in required")
        d.present = False                  # Codex isn't set up on this machine
        return d
    attempt = None
    if live:
        attempt = codex_usage_live()
        if attempt is not None and attempt.api_fresh:
            return attempt
        if attempt is not None and attempt._signed_out_no_values:
            return attempt  # signed out must not resurrect an old account's readings
        if attempt is None:                # compatibility with offline injected adapters
            attempt = LimitData()
            attempt.error, attempt.failure_kind = "live usage unavailable", "network"
        attempt.poll_failed = True
    # offline / signed out: the freshest of the local rollout files and the last cached reading
    try:
        best = codex_from_rollout()
        best.present = True
        cache = common.read_json(common.CACHE_PATH, {})
        cached = cache.get("codex") if isinstance(cache, dict) else None
        if isinstance(cached, dict):
            c = LimitData.from_dict(cached)
            best = quota_refresh.select_snapshot(best, c)
        if best.as_of and time.time() - best.as_of > 2 * 3600:
            best.stale = True
    except Exception:
        if attempt is not None:
            return attempt  # A broken fallback must not erase live auth/Retry-After.
        raise
    return quota_refresh.select_snapshot(attempt, best) if attempt is not None else best


# ---- cache ---------------------------------------------------------------------------------

def apply_provider_cache(product, data, previous=None):
    """Apply ONE accepted completion on the GUI thread, never in parallel workers.

    Read/merge/write only this provider, so independent completions cannot write back
    the other provider's stale captured snapshot. Call only after the ticket fence.
    """
    if product not in ("claude", "codex"):
        raise ValueError("unknown quota provider")
    data = selected_limits(data, product)
    if not data.present:
        return data
    if data._signed_out_no_values:
        return data
    if previous is not None:
        data = quota_refresh.select_snapshot(data, previous)
    cache = common.read_json(common.CACHE_PATH, {})
    if not isinstance(cache, dict):
        cache = {}
    cached = cache.get(product)
    if isinstance(cached, dict):
        data = quota_refresh.select_snapshot(data, LimitData.from_dict(cached))
    if data.api_fresh and data.error is None and data.auth == OK and not data.from_cache:
        cache[product] = data.to_dict()
        common.ensure_dirs()
        common.write_json(common.CACHE_PATH, cache)
    return data


def apply_cache(claude, codex):
    """Legacy serial caller; phase-2 workers must use main-thread per-provider apply."""
    return apply_provider_cache("claude", claude), apply_provider_cache("codex", codex)


SNAPSHOT_MAX_AGE = 14400


def snapshot_window_pace(used, reset, window_h, as_of, recent_rate=None):
    def finite(v):
        return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)
    if not all(finite(v) for v in (used, reset, as_of)) or used < 0:
        return None
    if not as_of < reset <= as_of + window_h * 3600:
        return None
    return window_pace(used, reset, window_h, recent_rate=recent_rate, now=as_of)


def metric_is_stale(d, metric, now=None):
    now = time.time() if now is None else now
    if d.as_of is None or not math.isfinite(d.as_of) or not 0 <= now - d.as_of <= SNAPSHOT_MAX_AGE:
        return True
    used, reset, hours = {"session": (d.session, d.session_reset, 5),
                          "weekly": (d.weekly, d.weekly_reset, 168),
                          "model": (d.scoped.percent, d.scoped.reset, 168) if d.scoped else (None, None, 168)}[metric]
    return (snapshot_window_pace(used, reset, hours, d.as_of) is None or reset <= now)


def is_stale(d, now=None):
    """A reset session must not hide a valid week; paint each metric independently."""
    return d.present and all(metric_is_stale(d, m, now) for m in ("session", "weekly", "model"))


def with_poll_status(d, state, next_at):
    d.poll_failed = state.failed if state else False
    d.next_poll_at = next_at
    return d


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
        if not common.product_enabled(product) or not d.present or d.error is not None or d.auth != OK or d.from_cache:
            return
        if d.session is None and d.weekly is None:
            return
        if d.poll_failed or d.as_of is None or not math.isfinite(d.as_of) or d.as_of > time.time():
            return
        previous = next((s for s in reversed(self.samples) if s["p"] == product), None)
        if previous and previous["t"] >= d.as_of:
            return
        s = {"t": d.as_of, "p": product}
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
        if not common.product_enabled(product):
            return None
        for s in self.samples:
            if s["p"] == product:
                return s["t"]
        return None

    def recent_rate(self, product, key, minutes, now=None):
        if not common.product_enabled(product):
            return None
        now = time.time() if now is None else now
        since = now - minutes * 60
        pts = [(s["t"], s[key]) for s in self.samples if s["p"] == product and since <= s["t"] <= now and key in s]
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
        now = time.time() if now is None else now
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
    def rr(key, minutes):
        return history.recent_rate(product, key, minutes, now=d.as_of) if history and d.as_of is not None else None
    out = []
    if product == "claude" or d.session is not None:
        out.append({"id": "session", "name": common.tr("Сессия · 5 ч", "Session · 5 h"), "color": 0,
                    "used": d.session, "pace": snapshot_window_pace(d.session, d.session_reset, 5, d.as_of, rr("s", 60))})
    if d.scoped:
        out.append({"id": "scoped", "name": common.tr("Неделя · ", "Week · ") + d.scoped.name, "color": 2,
                    "used": d.scoped.percent, "pace": snapshot_window_pace(d.scoped.percent, d.scoped.reset, 168, d.as_of, rr("m", 180))})
    out.append({"id": "weekly", "color": 1,
                "name": common.tr("Неделя · все модели", "Week · all models") if product == "claude" else common.tr("Неделя", "Week"),
                "used": d.weekly, "pace": snapshot_window_pace(d.weekly, d.weekly_reset, 168, d.as_of, rr("w", 180))})
    return out


# ---- reset / limit-reached events (port of checkAlarms, made pure so it can be tested) --------

def detect_alarms(claude, codex, prev, baseline):
    """Compare this reading with the remembered one. `prev` is the state dict (rst_*/use_*/rch_*
    keys), `baseline` False on the first reading after launch. Returns (events, updates):
    events are dicts {kind: "reset"|"reached", product, window, is5h, reset}; `updates` go back
    into the state.

    A reset is a window rolling over — resets_at jumped forward, something had been used in the
    old window and usage did not climb — so an idle 0% never chimes and a real rollover chimes
    once. "Reached" (≥ 99.5%, the shown 100%) is persisted, so it fires once per crossing and
    survives restarts, including a limit hit while the app was closed."""
    session_name = common.tr("Сессия · 5 ч", "Session · 5 h")
    week_name = common.tr("Неделя", "Week")
    wins = [("rst_c5", "use_c5", "rch_c5", "Claude Code", session_name, claude.session_reset, claude.session, True),
            ("rst_x5", "use_x5", "rch_x5", "Codex", session_name, codex.session_reset, codex.session, True),
            ("rst_c7", "use_c7", "rch_c7", "Claude Code", week_name + common.tr(" · все модели", " · all models"),
             claude.weekly_reset, claude.weekly, False),
            ("rst_x7", "use_x7", "rch_x7", "Codex", week_name, codex.weekly_reset, codex.weekly, False)]
    if claude.scoped:
        k = claude.scoped.name.lower()
        wins.append(("rst_cs_" + k, "use_cs_" + k, "rch_cs_" + k, "Claude Code", week_name + " · " + claude.scoped.name,
                     claude.scoped.reset, claude.scoped.percent, False))
    events, upd = [], {}
    for rkey, ukey, chkey, product, window, date, used, is5 in wins:
        if date is not None:
            old_r = float(prev.get(rkey) or 0)
            rolled = old_r > 0 and date > old_r + 60
            if used is not None:
                old_u = float(prev.get(ukey) or 0)
                if baseline and rolled and old_u > 0 and used <= old_u + 0.5:
                    events.append({"kind": "reset", "product": product, "window": window, "is5h": is5, "reset": date})
                upd[ukey] = used
            upd[rkey] = date
        if used is not None:
            now_r = used >= 99.5
            if now_r and not prev.get(chkey):
                events.append({"kind": "reached", "product": product, "window": window, "is5h": is5, "reset": date})
            upd[chkey] = now_r
    return events, upd
