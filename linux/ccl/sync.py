"""Cross-machine sync through one secret GitHub gist — docs/sync-protocol.md, schema 1.

Each computer writes one whole-snapshot file of daily per-model token totals
(`machine-<id>.json`) and reads everyone else's. Only aggregates travel; the token never
leaves the token store except in the Authorization header, and is never logged.
"""

from contextlib import nullcontext
import hashlib
import json
import math
import os
import secrets
import threading
import time
import urllib.parse

from . import APP_VERSION, common, vault, usage, auth

GITHUB_CLIENT_ID = "Ov23lipk8voUWUAr59qS"     # docs/sync-protocol.md → Client ID (public, no secret)
MANIFEST = "ccl-sync.json"
DESCRIPTION = "Claude Codex Limits — usage sync (do not edit)"
ABOUT = "https://github.com/ArrivaRUS/claude-codex-limits/blob/main/docs/sync-protocol.md"
SCHEMA = 1
KEEP_DAYS = 45
MIN_PUSH_INTERVAL = 10 * 60
STALE_AFTER = 30 * 60        # signed in, no good cycle for this long → say so on the main screen
UA = "ClaudeCodexLimits"
API = "https://api.github.com"
LOGIN_LOCK_TIMEOUT = 60.0   # test seam: deadline for sign-in/out serialization
REVOKE_RECHECK_DELAY = 4.0
_sleep = time.sleep
_first_attempt_at = None
_login_lock = threading.RLock()
_login_counter = 0
_login_current = None


def sync_state():
    return common.Store(common.SYNC_STATE_PATH)


def my_file_name():
    return "machine-%s.json" % common.machine_id()


# ---- GitHub API ---------------------------------------------------------------------------

def _transport(url, method, headers, body, timeout):
    return common.http(url, method, headers, body, timeout,
                       follow_redirects=not (any(k.lower() == "authorization" for k in headers)
                                            or url.startswith("https://github.com/login/")))


# Test seam: every request of this module (gist, /user, Device Flow) goes through `transport`
# (url, method, headers, body, timeout) → common.Resp. Replace it to run a cycle offline.
transport = _transport


def _api_origin(url):
    """Only the ASCII HTTPS GitHub API origin may receive a bearer token."""
    if not isinstance(url, str) or not url.isascii() or "%" in url or "@" in url:
        return False
    if any(ord(c) <= 32 or ord(c) == 127 for c in url):
        return False
    try:
        parsed = urllib.parse.urlsplit(url)
        return (url.partition(":")[0] == "https" and parsed.scheme == "https"
                and parsed.hostname == "api.github.com" and parsed.port in (None, 443))
    except ValueError:
        return False


def gh(path, token, method="GET", body=None, timeout=20):
    url = API + path if path[:1] == "/" and path[:2] != "//" else path
    if not _api_origin(url):
        return common.Resp(0, error="Invalid GitHub API origin")
    h = {"Authorization": "Bearer " + token, "Accept": "application/vnd.github+json",
         "X-GitHub-Api-Version": "2022-11-28", "User-Agent": UA}
    if body is not None:
        h["Content-Type"] = "application/json"
    return transport(url, method, h, body, timeout)


def _raw(url):
    """Gist raw URLs carry their own secret path; never attach the OAuth token."""
    return transport(url, "GET", {"User-Agent": UA}, None, 30)


def _form_result(url, fields):
    if url not in ("https://github.com/login/device/code", auth.REFRESH_URL):
        return 0, None, {}
    body = urllib.parse.urlencode(fields)
    r = transport(url, "POST", {"Accept": "application/json", "User-Agent": UA,
                                "Content-Type": "application/x-www-form-urlencoded"}, body, 15)
    if url == auth.REFRESH_URL and fields.get("grant_type") == "refresh_token" and getattr(r, "definitely_not_sent", False):
        raise auth.RefreshNotSent()
    j = r.json()
    return r.status, j if isinstance(j, dict) else None, r.headers


def _form(url, fields):
    return _form_result(url, fields)[1]


# ---- sign-in: OAuth Device Flow -----------------------------------------------------------

class LoginError(Exception):
    pass


def begin_login():
    """Publish a durable attempt before Device Flow; supersede other processes."""
    global _login_current
    with common.file_lock("sync", timeout=LOGIN_LOCK_TIMEOUT) as held:
        if not held:
            raise LoginError(auth_reason("busy"))
        try:
            auth_owner()._load()
            attempt = secrets.token_hex(16)
            sync_state().update(loginAttempt=attempt)
        except (OSError, ValueError):
            raise LoginError(auth_reason("manifest_unavailable"))
        with _login_lock:
            _login_current = attempt
        return attempt


def cancel_login(attempt):
    global _login_current
    with _login_lock:
        if _login_current == attempt:
            _login_current = None
    # Never wait for the process flock while holding the publication mutex.
    context = nullcontext(True) if common.lock_held_by_thread("sync") else common.file_lock("sync", timeout=LOGIN_LOCK_TIMEOUT)
    with context as held:
        if not held:
            return False
        owner = auth_owner()
        current = owner._load()
        if owner.manifest.current_attempt() == attempt and attempt is not None:
            sync_state().update(loginAttempt=None)
            if current and (current.get("transition") or {}).get("attemptID") == attempt:
                owner._abort_login(current)
        return True


def is_current(attempt):
    with _login_lock:
        local_current = attempt is not None and attempt == _login_current
    if not local_current:
        return False
    try:
        return auth.LinuxManifest().current_attempt() == attempt
    except (OSError, ValueError):
        return False


def device_start(attempt=None):
    """Step 1: ask GitHub for a device code. Returns the response dict (user_code, …)."""
    attempt = _login_current if attempt is None else attempt
    if not is_current(attempt):
        raise LoginError("cancelled")
    j = _form("https://github.com/login/device/code", {"client_id": GITHUB_CLIENT_ID, "scope": "gist offline_access"})
    if not j or "device_code" not in j or "user_code" not in j:
        raise LoginError(common.tr("GitHub не ответил. Попробуйте ещё раз.", "GitHub didn't answer. Try again."))
    if not is_current(attempt):
        raise LoginError("cancelled")
    j.setdefault("verification_uri", "https://github.com/login/device")
    j["_attempt"] = attempt
    return j


def device_poll(dev, cancelled=lambda: False, sleep=time.sleep):
    """Step 3: return the full issuance, including optional refresh/issuer lifetimes."""
    supplied_cancelled = cancelled
    cancelled = lambda: supplied_cancelled() or (dev.get("_attempt") is not None and not is_current(dev["_attempt"]))
    interval = float(dev.get("interval") or 5)
    deadline = time.time() + float(dev.get("expires_in") or 900)
    while time.time() < deadline:
        # sleep in short slices so a cancel from the UI is honoured quickly
        until = time.time() + interval
        while time.time() < until:
            if cancelled():
                raise LoginError("cancelled")
            sleep(min(0.5, max(0.0, until - time.time())))
        if cancelled():
            raise LoginError("cancelled")
        t = _form("https://github.com/login/oauth/access_token", {
            "client_id": GITHUB_CLIENT_ID, "device_code": dev["device_code"],
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code"})
        if t is None:
            continue                                  # network blip — keep polling
        if t.get("access_token"):
            if cancelled():
                raise LoginError("cancelled")
            return t
        err = t.get("error")
        if err == "authorization_pending":
            continue
        if err == "slow_down":
            interval += 5
            continue
        if err == "access_denied":
            raise LoginError(common.tr("Вход отклонён в GitHub.", "Sign-in was declined on GitHub."))
        raise LoginError(common.tr("Код устарел. Попробуйте ещё раз.", "The code expired. Try again."))
    raise LoginError(common.tr("Код устарел. Попробуйте ещё раз.", "The code expired. Try again."))


def login_finish(token, cancelled=lambda: False, attempt=None):
    """Step 4: verify identity before storing the token. Returns the GitHub login."""
    if isinstance(token, dict):
        attempt = _login_current if attempt is None else attempt
        if not is_current(attempt):
            raise LoginError("cancelled")
        with common.file_lock("sync", timeout=LOGIN_LOCK_TIMEOUT) as held:
            if not held:
                raise LoginError(common.tr("Синхронизация занята, повторите", "Sync is busy, try again"))
            def stale():
                return cancelled() or (attempt is not None and not is_current(attempt))
            if stale():
                raise LoginError("cancelled")
            owner = auth_owner()
            try:
                owner._load()  # strict JSON/schema read before any Store update
            except (OSError, ValueError):
                raise LoginError(auth_reason("manifest_unavailable"))
            st = sync_state()
            old = vault.active(st)
            if old[1] != "credential-v2":
                # Durable retirement intent BEFORE V2 can replace the old pointer.
                st.update(tokenDeletePending=vault._pending(st, old))
            result = owner.accept_login(token, owner.store.login_backend(), cancelled=stale, lock_held=True, attempt_id=attempt)
            if result.reason == "cancelled":
                raise LoginError("cancelled")
            _publish_auth_status(owner, result)
            if result.kind != "ready":
                raise LoginError(auth_reason(result.reason))
            _retire_legacy_pending()
            return sync_state().get("login")
    if cancelled():
        raise LoginError("cancelled")
    response = gh("/user", token)
    if cancelled():
        raise LoginError("cancelled")
    me = response.json()
    login = me.get("login") if isinstance(me, dict) else None
    if response.status != 200 or not isinstance(login, str) or not login.strip():
        raise LoginError(str(response.status))
    login = login.strip()
    with common.file_lock("sync", timeout=LOGIN_LOCK_TIMEOUT) as held:
        if not held:
            raise LoginError(common.tr("Синхронизация занята, повторите", "Sync is busy, try again"))
        try:
            auth_owner()._load()  # strict read for legacy explicit-login path too
        except (OSError, ValueError):
            raise LoginError(auth_reason("manifest_unavailable"))
        if cancelled():
            raise LoginError("cancelled")
        ref = vault.store(token)
        # Cancellation can happen while the keyring call is in flight. Serialize the
        # final check and publication with begin/cancel, as well as other processes.
        with _login_lock:
            aborted = cancelled() or (attempt is not None and not is_current(attempt))
            if not aborted:
                retired = vault.publish(ref, cleanup=False)
                # Only an explicit sign-in lifts revocation.
                sync_state().update(login=login, revoked=False, lastError=None, lastErrorAt=None)
        # Secret Service deletion may block; begin/cancel must remain responsive.
        if aborted:
            vault.delete_ref(ref)
            raise LoginError("cancelled")
        vault.retire(retired)
    return login


def delete_pending():
    """Whether stored references still need removal, including during a live sign-in."""
    st = sync_state()
    return bool(st.get("tokenDeletePending") or (st.get("authV2") or {}).get("cleanupRefs"))


def sign_out_incomplete(st=None) -> bool:
    """Whether pending deletions belong to a missing or revoked sign-in."""
    if st is None:
        st = sync_state()
    v2 = st.get("authV2") or {}
    return bool((st.get("tokenDeletePending") and (not st.get("login") or st.get("revoked")))
                or (v2.get("signedOut") and v2.get("cleanupRefs")))


def _delete_pending_text():
    return common.tr(
        "Выход не завершён: хранилище не ответило, токен мог остаться — повторите выход",
        "Sign-out isn't complete: the keyring didn't answer, the token may still be stored — sign out again")


def logout():
    """Sign out locally; return False when a stored copy could not be removed."""
    with common.file_lock("sync", timeout=LOGIN_LOCK_TIMEOUT) as held:
        if not held:
            raise LoginError(common.tr("Синхронизация занята, повторите", "Sync is busy, try again"))
        try:
            v2 = auth_owner()._load()  # never interpret corrupt JSON as legacy/empty
        except (OSError, ValueError):
            raise LoginError(auth_reason("manifest_unavailable"))
        sync_state().update(loginAttempt=None)
        if v2 is not None:
            deleted = auth_owner().logout(lock_held=True)
            _retire_legacy_pending()
            deleted = deleted and not sync_state().get("tokenDeletePending")
            sync_state().update(authStatus=dict(kind="signedOut", reason="signedOut"))
            try:
                os.unlink(common.SYNC_REMOTE_PATH)
            except OSError:
                pass
            return deleted
        deleted = vault.delete()
        error = None if deleted else _delete_pending_text()
        sync_state().update(login=None, gistId=None, pushHash=None, pushedAt=None,
                            revoked=True if not deleted else None, backoffUntil=None, lastError=error,
                            lastErrorAt=time.time() if error else None, lastOkAt=None, lastAttemptAt=None,
                            tokenGeneration="", tokenBackend=None, lastSync=None, discoveredAt=None)
        try:
            os.unlink(common.SYNC_REMOTE_PATH)
        except OSError:
            pass
        return deleted


# ---- the files ----------------------------------------------------------------------------

def snapshot_hash(days):
    s = json.dumps(days, sort_keys=True, separators=(",", ":"))
    return hashlib.sha1(s.encode("utf-8")).hexdigest()[:16]


def machine_file(days, now=None):
    obj = {
        "schema": SCHEMA,
        "machine": {"id": common.machine_id(), "name": common.machine_name(),
                    "os": common.os_name(), "app": "linux " + APP_VERSION},
        "updated": common.iso_utc(now),
        "tz": common.local_tz_name(),
        "days": days,
    }
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def manifest():
    return json.dumps({"about": ABOUT, "created": common.iso_utc(), "schema": SCHEMA},
                      sort_keys=True, separators=(",", ":"))


def merge(contents, my_id, now=None):
    """Other machines' files (name → JSON text) → {"machines": [...], "days": {...}}.
    Skips this machine's own id, other schemas, unparsable JSON, and files not updated in
    45 days. Merge = plain sum per product → day → model. Pure — no network."""
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
        updated = common.parse_iso(obj.get("updated"))
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
                        counts = {k: v.get(k, 0) for k in usage.FIELDS}
                        # Reject the whole model record; never convert unbounded ints to float.
                        if all(type(n) is int and 0 <= n <= usage.MAX_VALUE for n in counts.values()):
                            usage.add_usage(clean, p, d, model, counts)
        sources.append(clean)
    return {"machines": machines, "days": usage.merge_days(*sources)}


def remote_matches_session(remote, st=None):
    st = st or sync_state()
    manifest = st.get("authV2")
    if not manifest:
        return True  # compatible legacy cache
    return (not manifest.get("signedOut") and bool(manifest.get("active"))
            and remote.get("authEpoch") == manifest.get("epoch")
            and remote.get("authUserID") == manifest.get("userID"))


def load_remote():
    r = common.read_json(common.SYNC_REMOTE_PATH, {})
    if not isinstance(r, dict) or not remote_matches_session(r):
        r = {}
    r.setdefault("machines", [])
    r.setdefault("days", {})
    return r


# ---- push + pull --------------------------------------------------------------------------

def _find_gist(token):
    """Oldest gist holding the manifest → (id or None, status)."""
    best = None
    url = "/gists?per_page=100"
    for _ in range(30):
        r = gh(url, token)
        if r.status != 200:
            return None, r
        arr = r.json() or []
        for g in arr:
            if not isinstance(g, dict) or g.get("public") is not False:
                continue
            files = g.get("files") or {}
            if MANIFEST in files and g.get("id"):
                created = g.get("created_at") or ""
                if best is None or created < best[1]:
                    best = (g["id"], created)
        nxt = _next_link(r.headers.get("link", ""))
        if not nxt or not arr:
            break
        url = nxt
    return (best[0] if best else None), None


def _next_link(link):
    for part in link.split(","):
        seg = part.split(";")
        if len(seg) >= 2 and 'rel="next"' in seg[1]:
            url = seg[0].strip().strip("<>")
            return url if _api_origin(url) else None
    return None


class SyncResult(object):
    def __init__(self):
        self.ok = False
        self.pushed = False
        self.skipped = None        # why nothing was done ("signed-out", "revoked", "backoff", "busy",
        #                            "locked", "unreachable")
        self.error = None
        self.remote = None
        self.attempted = False


def record_error(msg, st=None):
    """Remember the last error with its time (docs/sync-protocol.md → Errors → Visibility)."""
    (st or sync_state()).update(lastError=msg, lastErrorAt=time.time())


def _fail(st, res, msg):
    res.ok = False
    res.error = msg
    record_error(msg, st)
    return True


def status_text(r):
    """An HTTP answer for a human: 0 is a transport failure (no network, timeout), not a code."""
    if r.status == 403 and not _rate_limited(r):
        return common.tr("доступ запрещён (403)", "access denied (403)")
    return common.tr("ответ %d" % r.status, "HTTP %d" % r.status) if r.status else \
        common.tr("нет связи с GitHub", "no connection to GitHub")


def _rate_limited(r):
    return r.status == 429 or (r.status == 403 and
                              ("retry-after" in r.headers or r.headers.get("x-ratelimit-remaining") == "0"))


def _backoff_until(r):
    # secondary limits say Retry-After; x-ratelimit-reset only matters once the primary
    # budget is actually spent (GitHub sends it on every response)
    retry = r.headers.get("retry-after")
    reset = r.headers.get("x-ratelimit-reset") if r.headers.get("x-ratelimit-remaining") == "0" else None
    now = time.time()
    until = now + 15 * 60
    try:
        if retry is not None:
            value = float(retry)
            until = now + value
        elif reset is not None:
            value = float(reset)
            until = value + 5
        else:
            return until
        if not math.isfinite(value) or value < 0:
            return now + 15 * 60
    except (TypeError, ValueError, OverflowError):
        return now + 15 * 60
    return min(until, now + 3600)


def _revoked(st, res, active):
    """Two /user 401s confirmed the captured sign-in; invalidate before deleting it."""
    st.reload()
    if vault.active(st) != active:
        return _fail(st, res, common.tr("Вход в хранилище изменился; повторим синхронизацию",
                                        "The stored sign-in changed; sync will retry"))
    note = common.tr("Вход в GitHub отозван", "GitHub sign-in revoked")
    if active[1] == "credential-v2":
        auth_owner().logout(lock_held=True)
        st.update(revoked=True, authStatus=dict(kind="actionRequired", reason="access_revoked"))
        return _fail(st, res, note)
    pending = list(st.get("tokenDeletePending") or [])
    if active[0] and list(active) not in pending:
        pending.append(list(active))
    st.update(revoked=True, gistId=None, pushHash=None, discoveredAt=None,
              lastError=note, lastErrorAt=time.time(), tokenDeletePending=pending or None)
    vault.delete_ref(active)
    if sign_out_incomplete():
        note = _delete_pending_text()
    return _fail(st, res, note)


def _handle(r, st, res, token, what, active):
    """Common HTTP failure handling for request `what` ("GET /gists/{id}" …).
    Returns True when the cycle must stop."""
    if r.status in (200, 201):
        return False
    if r.status == 401:
        if active[1] == "credential-v2":
            owner = auth_owner()
            credential = owner.read_credential()
            if credential.kind != "ready":
                return _fail(st, res, auth_reason(credential.kind))
            if credential.credential.get("refreshToken"):
                access = ensure_access(reason="access401", lock_held=True)
                if access.kind == "ready" and access.access != token:
                    res.skipped = "renewed"
                    return True
                return _fail(st, res, auth_reason(access.reason))
        # a single 401 is not proof of revocation (GitHub sends stray ones): ask /user
        me = gh("/user", token)
        if me.status == 401:
            _sleep(REVOKE_RECHECK_DELAY)
            st.reload()
            if vault.active(st) != active:
                return _fail(st, res, common.tr("Вход в хранилище изменился; повторим синхронизацию",
                                                "The stored sign-in changed; sync will retry"))
            me = gh("/user", token)
            if me.status == 401:
                return _revoked(st, res, active)
        if me.status == 200:
            return _fail(st, res, common.tr("401 на %s, вход подтверждён" % what,
                                            "401 on %s, sign-in confirmed" % what))
        # can't tell (network, 5xx, rate limit): keep the token, retry next cycle
        if _rate_limited(me):
            st.update(backoffUntil=_backoff_until(me))
        return _fail(st, res, common.tr("401 на %s, проверка входа не прошла (%s)" % (what, status_text(me)),
                                        "401 on %s, sign-in check failed (%s)" % (what, status_text(me))))
    if _rate_limited(r):
        st.update(backoffUntil=_backoff_until(r))
        return _fail(st, res, "%s: %s" % (what, status_text(r)) + common.tr(" (лимит запросов)", " (rate limit)"))
    return _fail(st, res, "%s: %s" % (what, status_text(r)))


def sync_cycle(days, force=False, auto=False, allow_push=True):
    """One pass: make sure the gist exists, write this machine's snapshot when it changed,
    read and merge everyone else's. `days` = this machine's local index days.
    `auto` (timer / tray) honours the 10-minute minimum between writes."""
    res = SyncResult()
    result = _sync_cycle(days, force, auto, res, allow_push)
    # A successful access401 recovery must resume actual protected sync now.
    return _sync_cycle(days, force, auto, SyncResult(), allow_push) if result.skipped == "renewed" else result


def _sync_cycle(days, force, auto, res, allow_push=True):
    global _first_attempt_at
    with common.file_lock("sync", blocking=False) as held:
        if not held:
            res.skipped = "busy"
            return res
        try:
            auth.LinuxManifest().read()  # strict read before any generic state write
        except (OSError, ValueError):
            res.error = auth_reason("manifest_unavailable")
            res.skipped = "manifest_unavailable"
            return res
        st = sync_state()
        if st.get("revoked"):
            # stays off until a new sign-in (login_finish) — not lifted by a token that happens
            # to be found in a store
            res.skipped = "revoked"
            return res
        if not st.get("login") and not (st.get("authV2") or {}).get("transition"):
            res.skipped = "signed-out"
            return res
        if time.time() < float(st.get("backoffUntil") or 0):
            res.skipped = "backoff"
            return res
        res.attempted = True
        attempted_at = time.time()
        if _first_attempt_at is None:
            _first_attempt_at = attempted_at
        st.update(lastAttemptAt=attempted_at)
        access = ensure_access(lock_held=True)
        st.reload()
        if access.kind != "ready":
            res.skipped = "signed-out" if access.kind == "signedOut" else access.reason or "auth-pending"
            if access.reason == "manifest_unavailable":
                res.error = auth_reason(access.reason)
            elif access.kind != "signedOut":
                _fail(st, res, auth_reason(access.reason))
            return res
        token = access.access
        active = vault.active(st)

        snap = usage.snapshot_days({"days": days})
        h = snapshot_hash(snap)
        mine = my_file_name()

        # If two machines ever created a gist each, "earliest created_at wins" must keep being
        # applied, not only on the first discovery — look again after a create and once a day.
        if st.get("gistId") and time.time() - float(st.get("discoveredAt") or 0) > 86400:
            gid, bad = _find_gist(token)
            if bad is not None:
                _handle(bad, st, res, token, "GET /gists", active)
                return res
            st.update(discoveredAt=time.time())
            if gid and gid != st.get("gistId"):
                st.update(gistId=gid, pushHash=None)

        gist = None
        for attempt in range(2):
            gid = st.get("gistId")
            if not gid:
                gid, bad = _find_gist(token)
                if bad is not None:
                    _handle(bad, st, res, token, "GET /gists", active)
                    return res
                if not gid:
                    c = gh("/gists", token, "POST", {
                        "description": DESCRIPTION, "public": False,
                        "files": {MANIFEST: {"content": manifest()}, mine: {"content": machine_file(snap)}}})
                    if _handle(c, st, res, token, "POST /gists", active):
                        return res
                    gid = (c.json() or {}).get("id")
                    if not gid:
                        _fail(st, res, "POST /gists: " + common.tr("нет id в ответе", "no id in the answer"))
                        return res
                    st.update(pushHash=h, pushedAt=time.time())
                    res.pushed = True
                    again, _bad = _find_gist(token)      # did another machine create one at the same time?
                    if _bad is not None:
                        _handle(_bad, st, res, token, "GET /gists", active)
                        return res
                    if again and again != gid:
                        gid = again
                        st.update(pushHash=None)
                st.update(gistId=gid, discoveredAt=time.time())
            g = gh("/gists/" + gid, token)
            if g.status == 404:                        # deleted or not ours any more → rediscover
                st.update(gistId=None, pushHash=None)
                continue
            if _handle(g, st, res, token, "GET /gists/{id}", active):
                return res
            candidate = g.json()
            if not isinstance(candidate, dict) or candidate.get("public") is not False:
                st.update(gistId=None, pushHash=None, discoveredAt=None)
                continue
            gist = candidate
            break
        if gist is None:
            _fail(st, res, "GET /gists/{id}: " + common.tr("gist не найден", "gist not found"))
            return res
        files = gist.get("files") or {}

        # write — whole snapshot, only when it changed (or our file went missing)
        missing = mine not in files
        due = force or missing or st.get("pushHash") != h
        if due and auto and not missing and not force:
            if time.time() - float(st.get("pushedAt") or 0) < MIN_PUSH_INTERVAL - 30:
                due = False
        if due and allow_push:
            p = gh("/gists/" + st.get("gistId"), token, "PATCH", {"files": {mine: {"content": machine_file(snap)}}})
            if p.status == 404:
                st.update(gistId=None, pushHash=None)
                _fail(st, res, "PATCH /gists/{id}: " + common.tr("gist пропал, найдём заново", "gist gone, will rediscover"))
                return res
            if _handle(p, st, res, token, "PATCH /gists/{id}", active):
                return res
            st.update(pushHash=h, pushedAt=time.time())
            res.pushed = True

        # read + merge everyone else
        contents = {}
        for name, f in files.items():
            if not (name.startswith("machine-") and name.endswith(".json")) or name == mine:
                continue
            text = f.get("content")
            if f.get("truncated") and f.get("raw_url"):
                r = _raw(f["raw_url"])
                if r.status != 200 or not r.data:
                    if _rate_limited(r):
                        st.update(backoffUntil=_backoff_until(r))
                    _fail(st, res, "GET raw_url: " + status_text(r))
                    res.remote = load_remote()
                    return res
                text = r.data.decode("utf-8", "replace")
            if text:
                contents[name] = text
        remote = merge(contents, common.machine_id())
        remote["fetched"] = time.time()
        if active[1] == "credential-v2":
            remote["authEpoch"] = access.epoch
            remote["authUserID"] = (st.get("authV2") or {}).get("userID")
        common.write_json(common.SYNC_REMOTE_PATH, remote)
        st.update(lastOkAt=time.time(), lastSync=None, lastError=None, lastErrorAt=None, backoffUntil=None)
        res.ok = True
        res.remote = remote
        return res


def last_ok_at(st=None):
    """Time of the last good cycle (read included); `lastSync` is the pre-0.3.2 name."""
    st = st or sync_state()
    return st.get("lastOkAt") or st.get("lastSync")


def warning(st=None, now=None, moment=None, require_attempt=True):
    """The orange line for the main screen, or None when sync is fine or off
    (docs/sync-protocol.md → Errors → Visibility). `moment` formats a time ("HH:MM")."""
    st = st or sync_state()
    now = time.time() if now is None else now
    moment = moment or (lambda t: time.strftime("%H:%M", time.localtime(t)))
    presentation = auth_snapshot(st)
    if presentation.get("kind") == "actionRequired":
        return auth_reason(presentation.get("reason"))
    if presentation.get("kind") == "temporary" and st.get("login"):
        return auth_reason(presentation.get("reason"))
    if st.get("revoked"):
        return common.tr("Войдите в GitHub заново — суммы без других компьютеров",
                         "Sign in to GitHub again — totals exclude other computers")
    if not st.get("login") or (require_attempt and _first_attempt_at is None):
        return None
    err = st.get("lastError")
    since = last_ok_at(st) or st.get("pushedAt")
    if not since:
        return (common.tr("Синхронизация не работает: ", "Sync isn't working: ") + str(err)) if err else None
    # A post-threshold error confirms the stall; sleeping through the threshold doesn't.
    try:
        since, error_at = float(since), float(st.get("lastErrorAt") or 0)
    except (TypeError, ValueError, OverflowError):
        return None
    if (not math.isfinite(since) or not math.isfinite(error_at) or
            now - since <= STALE_AFTER or not err or error_at <= since + STALE_AFTER or
            (require_attempt and error_at < _first_attempt_at)):
        return None
    try:
        since_text = moment(since)
    except (ValueError, OverflowError, OSError):
        return None
    return common.tr("Синхронизация стоит с %s: %s" % (since_text, str(err)),
                     "Sync stalled since %s: %s" % (since_text, str(err)))


def machine_list():
    """This machine first, then the others from the last merge (for status / UI)."""
    st = sync_state()
    out = [{"name": common.machine_name(), "os": common.os_name(), "updated": st.get("pushedAt"), "self": True}]
    for m in sorted(load_remote().get("machines", []), key=lambda m: m.get("name") or ""):
        out.append(dict(m, self=False))
    return out


_auth_owner = None
_auth_owner_path = None


def _legacy_credential():
    st = sync_state()
    if st.get("revoked") or not st.get("login"):
        return auth.AuthRead("signedOut")
    active = vault.active(st)
    token, backend = vault.read()
    if not token:
        return auth.AuthRead(backend or "missing")
    return auth.AuthRead("ready", dict(accessToken=token, epoch=active[0], generation=active[0],
                                     login=st.get("login"), obtainedAt=0),
                         dict(generation=active[0], backend=backend))


def auth_owner():
    """Lazy integration factory. Tests must inject dependencies before first use."""
    global _auth_owner, _auth_owner_path
    if _auth_owner is None or _auth_owner_path != common.SYNC_STATE_PATH:
        def identity(token):
            r = gh("/user", token)
            return r.status, r.json(), r.headers
        _auth_owner = auth.AuthOwner(auth.LinuxManifest(), vault.CredentialStore(),
            transport=lambda url, fields: _form_result(url, fields), identity=identity,
            lock=lambda: common.file_lock("sync", timeout=LOGIN_LOCK_TIMEOUT), clock=lambda: time.time(),
            legacy=_legacy_credential, defer=vault._sigint_deferred, publication_lock=lambda: _login_lock)
        _auth_owner_path = common.SYNC_STATE_PATH
    return _auth_owner


def auth_reason(reason):
    messages = {
        "missing": ("Ключ GitHub не найден на этом компьютере — войдите заново", "GitHub key not found on this computer — sign in again"),
        "locked": ("Хранилище секретов заблокировано — синхронизация продолжится после разблокировки", "The Secret Service is locked — sync resumes after unlocking"),
        "unreachable": ("Хранилище секретов недоступно — повторим автоматически", "The Secret Service is unavailable — retrying automatically"),
        "timeout": ("Хранилище секретов не ответило — повторим автоматически", "The Secret Service did not answer — retrying automatically"),
        "network": ("Нет связи с GitHub — повторим автоматически", "No connection to GitHub — retrying automatically"),
        "refresh_invalid": ("GitHub отклонил продление входа — войдите заново, когда доступ перестанет работать", "GitHub rejected sign-in renewal — sign in again when access stops working"),
        "refresh_expired": ("Срок продления входа истёк — войдите заново", "Sign-in renewal has expired — sign in again"),
        "lost_result": ("Результат обновления входа не удалось восстановить — войдите заново", "Could not recover the sign-in renewal result — sign in again"),
        "incomplete_response": ("GitHub вернул неполный вход — требуется новый вход", "GitHub returned incomplete credentials — sign in again"),
        "identity_changed": ("GitHub вернул другой аккаунт — войдите заново", "GitHub returned a different account — sign in again"),
        "busy": ("Синхронизация уже идёт — повторим автоматически", "Sync is already running — retrying automatically"),
        "signedOut": ("Вход не выполнен", "Not signed in"),
        "access_revoked": ("GitHub отклонил вход — войдите заново", "GitHub rejected sign-in — sign in again"),
        "manifest_unavailable": ("Состояние входа недоступно — повторим автоматически", "Sign-in state is unavailable — retrying automatically"),
        "corrupt": ("Не удалось прочитать сохранённый вход — повторим автоматически", "Could not read the saved sign-in — retrying automatically"),
    }
    ru, en = messages.get(reason, ("Восстанавливаем вход GitHub — повторим автоматически", "Restoring GitHub sign-in — retrying automatically"))
    return common.tr(ru, en)


def _publish_auth_status(owner, result):
    snapshot = owner.snapshot()
    if result.reason == "manifest_unavailable":
        return  # Never replace an unreadable/corrupt manifest with an empty Store.
    st = sync_state()
    st.update(authStatus=snapshot)
    if result.reason:
        record_error(auth_reason(result.reason), st)


def _retire_legacy_pending():
    """Caller holds sync flock. V2 tombstone/active pointer cannot be raw legacy."""
    st = sync_state()
    if st.get("tokenBackend") == "credential-v2":
        vault.retire(list(st.get("tokenDeletePending") or []))


def ensure_access(reason="sync", lock_held=False):
    owner = auth_owner()
    result = owner.ensure_access(reason=reason, lock_held=lock_held)
    _publish_auth_status(owner, result)
    if result.kind == "ready":
        if lock_held:
            _retire_legacy_pending()
        else:
            with common.file_lock("sync", blocking=False) as held:
                if held:
                    _retire_legacy_pending()
    return result


def auth_snapshot(st=None):
    """Nonsecret projection only: safe on the GUI thread; no vault or HTTP."""
    st = st or sync_state()
    snapshot = st.get("authStatus")
    if isinstance(snapshot, dict):
        return snapshot
    return dict(kind="actionRequired" if st.get("revoked") else "ready" if st.get("login") else "signedOut",
                reason="access_revoked" if st.get("revoked") else None,
                backend=st.get("tokenBackend"), login=st.get("login"))
