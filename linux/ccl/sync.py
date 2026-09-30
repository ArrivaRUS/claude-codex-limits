"""Cross-machine sync through one secret GitHub gist — docs/sync-protocol.md, schema 1.

Each computer writes one whole-snapshot file of daily per-model token totals
(`machine-<id>.json`) and reads everyone else's. Only aggregates travel; the token never
leaves the token store except in the Authorization header, and is never logged.
"""

import hashlib
import json
import math
import os
import time
import urllib.parse

from . import APP_VERSION, common, vault, usage

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
_first_attempt_done = False


def sync_state():
    return common.Store(common.SYNC_STATE_PATH)


def my_file_name():
    return "machine-%s.json" % common.machine_id()


# ---- GitHub API ---------------------------------------------------------------------------

def _transport(url, method, headers, body, timeout):
    return common.http(url, method, headers, body, timeout,
                       follow_redirects=not any(k.lower() == "authorization" for k in headers))


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


def _form(url, fields):
    body = urllib.parse.urlencode(fields)
    r = transport(url, "POST", {"Accept": "application/json", "User-Agent": UA,
                                "Content-Type": "application/x-www-form-urlencoded"}, body, 15)
    j = r.json()
    return j if isinstance(j, dict) else None


# ---- sign-in: OAuth Device Flow -----------------------------------------------------------

class LoginError(Exception):
    pass


def device_start():
    """Step 1: ask GitHub for a device code. Returns the response dict (user_code, …)."""
    j = _form("https://github.com/login/device/code", {"client_id": GITHUB_CLIENT_ID, "scope": "gist"})
    if not j or "device_code" not in j or "user_code" not in j:
        raise LoginError(common.tr("GitHub не ответил. Попробуйте ещё раз.", "GitHub didn't answer. Try again."))
    j.setdefault("verification_uri", "https://github.com/login/device")
    return j


def device_poll(dev, cancelled=lambda: False, sleep=time.sleep):
    """Step 3: poll until the user confirms. Returns the access token; raises LoginError."""
    interval = float(dev.get("interval") or 5)
    deadline = time.time() + float(dev.get("expires_in") or 900)
    while time.time() < deadline:
        # sleep in short slices so a cancel from the UI is honoured quickly
        until = time.time() + interval
        while time.time() < until:
            if cancelled():
                raise LoginError("cancelled")
            sleep(min(0.5, max(0.0, until - time.time())))
        t = _form("https://github.com/login/oauth/access_token", {
            "client_id": GITHUB_CLIENT_ID, "device_code": dev["device_code"],
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code"})
        if t is None:
            continue                                  # network blip — keep polling
        if t.get("access_token"):
            if cancelled():
                raise LoginError("cancelled")
            return t["access_token"]
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


def login_finish(token, cancelled=lambda: False):
    """Step 4: verify identity before storing the token. Returns the GitHub login."""
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
        if cancelled():
            raise LoginError("cancelled")
        backend = vault.write(token)
        # the only place a revoked sign-in is lifted: a token found in a store by chance isn't
        sync_state().update(login=login, revoked=False, tokenBackend=backend, lastError=None, lastErrorAt=None)
    return login


def logout():
    """Sign out locally; return False when a stored copy could not be removed."""
    with common.file_lock("sync", timeout=LOGIN_LOCK_TIMEOUT) as held:
        if not held:
            raise LoginError(common.tr("Синхронизация занята, повторите", "Sync is busy, try again"))
        deleted = vault.delete()
        error = None if deleted else common.tr(
            "Хранилище не ответило, токен мог остаться — повторите выход после разблокировки KWallet "
            "или удалите запись “Claude Codex Limits GitHub” в KWallet Manager",
            "The keyring didn't answer, the token may still be stored — sign out again after unlocking KWallet, "
            "or delete the “Claude Codex Limits GitHub” entry in KWallet Manager")
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
        except (ValueError, TypeError):
            continue
        if not isinstance(obj, dict) or obj.get("schema") != SCHEMA:
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


def load_remote():
    r = common.read_json(common.SYNC_REMOTE_PATH, {})
    if not isinstance(r, dict):
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
    if vault._active(st) != active:
        return _fail(st, res, common.tr("Вход в хранилище изменился; повторим синхронизацию",
                                        "The stored sign-in changed; sync will retry"))
    note = common.tr("Вход в GitHub отозван", "GitHub sign-in revoked")
    st.update(revoked=True, gistId=None, pushHash=None, discoveredAt=None,
              lastError=note, lastErrorAt=time.time())
    if not vault._delete(*active):
        note += " · " + vault.timeout_text()
    return _fail(st, res, note)


def _handle(r, st, res, token, what, active):
    """Common HTTP failure handling for request `what` ("GET /gists/{id}" …).
    Returns True when the cycle must stop."""
    if r.status in (200, 201):
        return False
    if r.status == 401:
        # a single 401 is not proof of revocation (GitHub sends stray ones): ask /user
        me = gh("/user", token)
        if me.status == 401:
            _sleep(REVOKE_RECHECK_DELAY)
            st.reload()
            if vault._active(st) != active:
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


def sync_cycle(days, force=False, auto=False):
    """One pass: make sure the gist exists, write this machine's snapshot when it changed,
    read and merge everyone else's. `days` = this machine's local index days.
    `auto` (timer / tray) honours the 10-minute minimum between writes."""
    global _first_attempt_done
    res = SyncResult()
    try:
        return _sync_cycle(days, force, auto, res)
    finally:
        if res.attempted:
            _first_attempt_done = True


def _sync_cycle(days, force, auto, res):
    with common.file_lock("sync", blocking=False) as held:
        if not held:
            res.skipped = "busy"
            return res
        st = sync_state()
        if st.get("revoked"):
            # stays off until a new sign-in (login_finish) — not lifted by a token that happens
            # to be found in a store
            res.skipped = "revoked"
            return res
        if not st.get("login"):
            res.skipped = "signed-out"
            return res
        if time.time() < float(st.get("backoffUntil") or 0):
            res.skipped = "backoff"
            return res
        active = vault._active(st)
        res.attempted = True
        signed_in = bool(st.get("login"))
        if signed_in:
            st.update(lastAttemptAt=time.time())
        token, backend = vault.read()
        if not token:
            if backend == "timeout":
                if signed_in:
                    _fail(st, res, vault.timeout_text())
                else:
                    res.skipped = "signed-out"
            elif backend == "locked":
                res.skipped = "locked"
                if signed_in:
                    record_error(common.tr("Хранилище секретов заблокировано", "The Secret Service is locked"), st)
            elif st.get("tokenBackend") == "secret-service" and signed_in and not vault.reachable():
                res.skipped = "unreachable"          # e.g. cron without the session bus — not a sign-out
                _fail(st, res, common.tr("Хранилище секретов недоступно (нет D-Bus)",
                                        "The Secret Service is unreachable (no D-Bus)"))
            else:
                res.skipped = "signed-out"
                if signed_in:
                    record_error(common.tr("Токен GitHub не найден — войдите заново",
                                           "GitHub token not found — sign in again"), st)
            return res

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
        if due:
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
        common.write_json(common.SYNC_REMOTE_PATH, remote)
        st.update(lastOkAt=time.time(), lastSync=None, lastError=None, lastErrorAt=None, backoffUntil=None)
        res.ok = True
        res.remote = remote
        return res


def last_ok_at(st=None):
    """Time of the last good cycle (read included); `lastSync` is the pre-0.3.2 name."""
    st = st or sync_state()
    return st.get("lastOkAt") or st.get("lastSync")


def warning(st=None, now=None, moment=None):
    """The orange line for the main screen, or None when sync is fine or off
    (docs/sync-protocol.md → Errors → Visibility). `moment` formats a time ("HH:MM")."""
    st = st or sync_state()
    now = time.time() if now is None else now
    moment = moment or (lambda t: time.strftime("%H:%M", time.localtime(t)))
    if st.get("revoked"):
        return common.tr("Войдите в GitHub заново — суммы без других компьютеров",
                         "Sign in to GitHub again — totals exclude other computers")
    if not st.get("login") or not _first_attempt_done:
        return None
    err = st.get("lastError")
    since = last_ok_at(st) or st.get("pushedAt")
    if not since:
        return (common.tr("Синхронизация не работает: ", "Sync isn't working: ") + str(err)) if err else None
    # An error after the last success marks the start of the failed interval. The process
    # must have completed an attempt too, so stale persisted state alone cannot warn.
    try:
        since, error_at = float(since), float(st.get("lastErrorAt") or 0)
    except (TypeError, ValueError, OverflowError):
        return None
    if (not math.isfinite(since) or not math.isfinite(error_at) or
            now - since <= STALE_AFTER or not err or error_at <= since):
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
