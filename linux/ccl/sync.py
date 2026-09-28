"""Cross-machine sync through one secret GitHub gist — docs/sync-protocol.md, schema 1.

Each computer writes one whole-snapshot file of daily per-model token totals
(`machine-<id>.json`) and reads everyone else's. Only aggregates travel; the token never
leaves the token store except in the Authorization header, and is never logged.
"""

import hashlib
import json
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
UA = "ClaudeCodexLimits"
API = "https://api.github.com"


def sync_state():
    return common.Store(common.SYNC_STATE_PATH)


def my_file_name():
    return "machine-%s.json" % common.machine_id()


# ---- GitHub API ---------------------------------------------------------------------------

def gh(path, token, method="GET", body=None, timeout=20):
    h = {"Authorization": "Bearer " + token, "Accept": "application/vnd.github+json",
         "X-GitHub-Api-Version": "2022-11-28", "User-Agent": UA}
    if body is not None:
        h["Content-Type"] = "application/json"
    url = path if path.startswith("https://") else API + path
    return common.http(url, method, h, body, timeout)


def _form(url, fields):
    body = urllib.parse.urlencode(fields)
    r = common.http(url, "POST", {"Accept": "application/json", "User-Agent": UA,
                                  "Content-Type": "application/x-www-form-urlencoded"}, body)
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


def login_finish(token):
    """Step 4: store the token, learn who we are. Returns the GitHub login."""
    me = gh("/user", token).json() or {}
    login = me.get("login")
    with common.file_lock("sync", timeout=60):        # never interleave with a running cycle
        backend = vault.write(token)
        sync_state().update(login=login, revoked=False, tokenBackend=backend, lastError=None)
    return login


def logout():
    """Sign-out deletes the local token; the gist stays."""
    with common.file_lock("sync", timeout=60):
        vault.delete()
        sync_state().remove("login", "gistId", "pushHash", "pushedAt", "revoked", "backoffUntil", "lastError",
                            "tokenBackend", "lastSync", "discoveredAt")
        try:
            os.unlink(common.SYNC_REMOTE_PATH)
        except OSError:
            pass


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
    machines, sources = [], []
    for name in sorted(contents):
        try:
            obj = json.loads(contents[name])
        except (ValueError, TypeError):
            continue
        if not isinstance(obj, dict) or obj.get("schema") != SCHEMA:
            continue
        m = obj.get("machine") or {}
        mid = m.get("id")
        if not isinstance(mid, str) or mid == my_id:
            continue
        updated = common.parse_iso(obj.get("updated"))
        if updated is not None and updated < oldest:
            continue
        machines.append({"id": mid, "name": m.get("name") or "?", "os": m.get("os") or "",
                         "app": m.get("app") or "", "updated": updated, "tz": obj.get("tz") or ""})
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
                        usage.add_usage(clean, p, d, model,
                                        {k: v.get(k) if isinstance(v.get(k), int) else 0 for k in usage.FIELDS})
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
            return seg[0].strip().strip("<>")
    return None


class SyncResult(object):
    def __init__(self):
        self.ok = False
        self.pushed = False
        self.skipped = None        # why nothing was done ("signed-out", "revoked", "backoff", "busy")
        self.error = None
        self.remote = None


def _handle(r, st, res, token):
    """Common HTTP failure handling. Returns True when the cycle must stop."""
    if r.status in (200, 201):
        return False
    if r.status == 401:
        if vault.delete_if(token):
            st.update(revoked=True, gistId=None, pushHash=None,
                      lastError=common.tr("Войдите в GitHub заново", "Sign in to GitHub again"))
        res.error = "401"
        return True
    if r.status in (403, 429):
        # secondary limits say Retry-After; x-ratelimit-reset only matters once the primary
        # budget is actually spent (GitHub sends it on every response)
        retry = r.headers.get("retry-after")
        reset = r.headers.get("x-ratelimit-reset") if r.headers.get("x-ratelimit-remaining") == "0" else None
        until = time.time() + 15 * 60
        try:
            if retry:
                until = time.time() + float(retry)
            elif reset:
                until = float(reset) + 5
        except ValueError:
            pass
        st.update(backoffUntil=until, lastError="HTTP %d" % r.status)
        res.error = "HTTP %d (rate limit)" % r.status
        return True
    res.error = ("HTTP %d" % r.status) if r.status else (r.error or "network")
    st.update(lastError=res.error)
    return True


def sync_cycle(days, force=False, auto=False):
    """One pass: make sure the gist exists, write this machine's snapshot when it changed,
    read and merge everyone else's. `days` = this machine's local index days.
    `auto` (timer / tray) honours the 10-minute minimum between writes."""
    res = SyncResult()
    with common.file_lock("sync", blocking=False) as held:
        if not held:
            res.skipped = "busy"
            return res
        st = sync_state()
        token, backend = vault.read()
        if not token:
            if backend == "locked":
                res.skipped = "locked"
            elif st.get("tokenBackend") == "secret-service" and st.get("login") and not vault.reachable():
                res.skipped = "unreachable"          # e.g. cron without the session bus — not a sign-out
            else:
                res.skipped = "revoked" if st.get("revoked") else "signed-out"
            return res
        if time.time() < float(st.get("backoffUntil") or 0):
            res.skipped = "backoff"
            return res

        snap = usage.snapshot_days({"days": days})
        h = snapshot_hash(snap)
        mine = my_file_name()

        # If two machines ever created a gist each, "earliest created_at wins" must keep being
        # applied, not only on the first discovery — look again after a create and once a day.
        if st.get("gistId") and time.time() - float(st.get("discoveredAt") or 0) > 86400:
            gid, bad = _find_gist(token)
            if bad is None:
                st.update(discoveredAt=time.time())
                if gid and gid != st.get("gistId"):
                    st.update(gistId=gid, pushHash=None)

        gist = None
        for attempt in range(2):
            gid = st.get("gistId")
            if not gid:
                gid, bad = _find_gist(token)
                if bad is not None:
                    _handle(bad, st, res, token)
                    return res
                if not gid:
                    c = gh("/gists", token, "POST", {
                        "description": DESCRIPTION, "public": False,
                        "files": {MANIFEST: {"content": manifest()}, mine: {"content": machine_file(snap)}}})
                    if _handle(c, st, res, token):
                        return res
                    gid = (c.json() or {}).get("id")
                    if not gid:
                        res.error = "gist create: no id"
                        return res
                    st.update(pushHash=h, pushedAt=time.time())
                    res.pushed = True
                    again, _bad = _find_gist(token)      # did another machine create one at the same time?
                    if again and again != gid:
                        gid = again
                        st.update(pushHash=None)
                st.update(gistId=gid, discoveredAt=time.time())
            g = gh("/gists/" + gid, token)
            if g.status == 404:                        # deleted or not ours any more → rediscover
                st.update(gistId=None, pushHash=None)
                continue
            if _handle(g, st, res, token):
                return res
            gist = g.json() or {}
            break
        if gist is None:
            res.error = "gist not found"
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
                res.error = "gist gone"
                return res
            if _handle(p, st, res, token):
                return res
            st.update(pushHash=h, pushedAt=time.time())
            res.pushed = True

        # read + merge everyone else
        contents = {}
        incomplete = False
        for name, f in files.items():
            if not (name.startswith("machine-") and name.endswith(".json")) or name == mine:
                continue
            text = f.get("content")
            if f.get("truncated") and f.get("raw_url"):
                r = gh(f["raw_url"], token, timeout=30)
                text = r.data.decode("utf-8", "replace") if r.status == 200 and r.data else None
                if text is None:
                    incomplete = True
            if text:
                contents[name] = text
        if incomplete:
            # a machine we couldn't download would vanish from the sum — keep the last merge
            st.update(lastError="raw_url fetch failed")
            res.ok = True
            res.remote = load_remote()
            return res
        remote = merge(contents, common.machine_id())
        remote["fetched"] = time.time()
        common.write_json(common.SYNC_REMOTE_PATH, remote)
        st.update(lastSync=time.time(), lastError=None, backoffUntil=None)
        res.ok = True
        res.remote = remote
        return res


def machine_list():
    """This machine first, then the others from the last merge (for status / UI)."""
    st = sync_state()
    out = [{"name": common.machine_name(), "os": common.os_name(), "updated": st.get("pushedAt"), "self": True}]
    for m in sorted(load_remote().get("machines", []), key=lambda m: m.get("name") or ""):
        out.append(dict(m, self=False))
    return out
