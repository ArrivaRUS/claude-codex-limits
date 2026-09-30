"""Shared offline sandbox for the sync regression tests (lesson 006).

Import `_isolate` first (done here), then `ccl`. Every test gets:
  * its own temp copy of every config/state path of `ccl.common` (token file, sync state, remote cache);
  * a fake Secret Service (`vault._ss`) whose calls can hang on a threading.Event — released in tearDown;
  * a scripted GitHub (`sync.transport`) that fails the test on any request it was not told about;
  * zero recheck pause, short keyring and lock deadlines.
"""

if __package__:
    from . import _isolate  # noqa: F401
else:
    import _isolate  # noqa: F401

import json
import os
import secrets
import shutil
import sys
import tempfile
import threading
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from ccl import common, sync, usage, vault  # noqa: E402

API = "https://api.github.com"
GIST = "g1"


def make_token():
    """A realistic-looking fake OAuth token, built at run time (no literal for secrets-check)."""
    return "gho" + "_" + "TESTTOKEN" + secrets.token_hex(16).upper()


def resp(status, obj=None, headers=None, raw=None):
    data = raw if raw is not None else (json.dumps(obj).encode("utf-8") if obj is not None else None)
    return common.Resp(status, data, {k.lower(): v for k, v in (headers or {}).items()})


class Call(object):
    def __init__(self, url, method, headers, body):
        self.url, self.method, self.headers, self.body = url, method, dict(headers), body

    @property
    def auth(self):
        return next((v for k, v in self.headers.items() if k.lower() == "authorization"), None)

    def __repr__(self):
        return "%s %s" % (self.method, self.url)


class FakeGitHub(object):
    """Scripted transport: queue responses per (method, url); anything else fails the test."""

    def __init__(self):
        self.calls = []
        self.queues = {}

    def on(self, method, url, *responses):
        if url.startswith("/"):
            url = API + url
        self.queues.setdefault((method, url), []).extend(responses)
        return self

    def __call__(self, url, method, headers, body, timeout):
        self.calls.append(Call(url, method, headers, body))
        q = self.queues.get((method, url))
        if not q:
            raise AssertionError("unexpected request: %s %s" % (method, url))
        r = q.pop(0)
        if callable(r):
            r = r(url, method, headers, body)
        return r

    def urls(self):
        return [(c.method, c.url[len(API):] if c.url.startswith(API) else c.url) for c in self.calls]


class FakeSecretService(object):
    """In-memory org.freedesktop.secrets keyed by the `generation` attribute ("legacy" = none).
    `hang_set` / `hang_delete`: an Event the call waits on (a keyring that doesn't answer).
    `zombie_effective`: whether a released hung call still performs its effect."""

    def __init__(self):
        self.items = {}
        self.locked = set()
        self.hang_set = None
        self.hang_delete = None
        self.zombie_effective = True
        self.zombie_done = threading.Event()
        self.on_delete = None
        self.deleted = []
        self._events = []
        self._lock = threading.Lock()

    def factory(self):
        return self

    def event(self):
        ev = threading.Event()
        self._events.append(ev)
        return ev

    def release_all(self):
        for ev in self._events:
            ev.set()

    # the _SecretService surface used by vault
    def get(self, generation):
        with self._lock:
            return self.items.get(generation)

    def has_locked(self, generation):
        return generation in self.locked

    def set(self, token, generation):
        ev = self.hang_set
        if ev is not None:
            ev.wait(30)
            if not self.zombie_effective:
                self.zombie_done.set()
                return
        with self._lock:
            self.items[generation] = token
        if ev is not None:
            self.zombie_done.set()

    def delete(self, generation):
        ev = self.hang_delete
        if ev is not None:
            ev.wait(30)
            if not self.zombie_effective:
                self.zombie_done.set()
                return False
        if self.on_delete:
            self.on_delete(generation)
        with self._lock:
            self.items.pop(generation, None)
            self.deleted.append(generation)
        if ev is not None:
            self.zombie_done.set()
        return True


def gist_json(files, gid=GIST, public=False, created="2026-09-01T00:00:00Z"):
    out = {"id": gid, "created_at": created, "files": {}}
    if public is not None:
        out["public"] = public
    for name, f in files.items():
        out["files"][name] = f if isinstance(f, dict) else {"content": f}
    return out


def machine_json(mid, input_=1, updated=None, **extra):
    obj = {"schema": 1, "machine": {"id": mid, "name": "pc-" + mid, "os": "Test OS", "app": "linux 0"},
           "updated": updated or common.iso_utc(), "tz": "UTC",
           "days": {"claude": {common.today_key(): {"claude-opus-5-5": dict(
               input=input_, output=2, cacheRead=3, cacheWrite5m=4, cacheWrite1h=5, turns=6)}}}}
    obj.update(extra)
    return json.dumps(obj)


class SyncEnv(unittest.TestCase):
    """Offline sandbox for sync/vault. Subclasses call `self.sign_in()` for a stored token."""

    TIMEOUT = 0.3

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ccl-sync-test-")
        roots = (common.CONFIG_DIR, common.STATE_DIR)
        paths = {name: value for name, value in vars(common).items()
                 if isinstance(value, str) and name.isupper() and
                 any(value == root or value.startswith(root + os.sep) for root in roots)}
        self._saved_common = dict(paths, _state=common._state, _settings=common._settings)
        for name, value in paths.items():
            root = next(root for root in roots if value == root or value.startswith(root + os.sep))
            base = "config" if root == roots[0] else "state"
            setattr(common, name, os.path.normpath(os.path.join(self.tmp, base, os.path.relpath(value, root))))
        common._state = common._settings = None
        self._saved = [(vault, "_ss", vault._ss), (vault, "TIMEOUT", vault.TIMEOUT),
                       (sync, "transport", sync.transport), (sync, "REVOKE_RECHECK_DELAY", sync.REVOKE_RECHECK_DELAY),
                       (sync, "_sleep", sync._sleep), (sync, "LOGIN_LOCK_TIMEOUT", sync.LOGIN_LOCK_TIMEOUT),
                       (sync, "_first_attempt_done", sync._first_attempt_done)]
        self.ss = FakeSecretService()
        vault._ss = self.ss.factory
        vault.TIMEOUT = self.TIMEOUT
        self.gh = FakeGitHub()
        sync.transport = self.gh
        sync.REVOKE_RECHECK_DELAY = 0
        self.sleeps = []
        sync._sleep = self.sleeps.append
        sync.LOGIN_LOCK_TIMEOUT = 0.3
        sync._first_attempt_done = False
        self.token = make_token()

    def tearDown(self):
        self.ss.release_all()
        self.ss.zombie_done.wait(2) if self.ss._events else None
        time.sleep(0.05)                       # let released workers finish before paths are restored
        for mod, name, value in self._saved:
            setattr(mod, name, value)
        for name, value in self._saved_common.items():
            setattr(common, name, value)
        shutil.rmtree(self.tmp, ignore_errors=True)

    # ---- helpers ----------------------------------------------------------------------------
    def st(self):
        return sync.sync_state()

    def sign_in(self, token=None, gist=GIST):
        """Store `token` as a fresh generation (fake Secret Service) and mark the sign-in active."""
        with common.file_lock("sync") as held:
            self.assertTrue(held)
            backend = vault.write(token or self.token)
        self.st().update(login="me", revoked=False, gistId=gist, discoveredAt=time.time())
        self.assertEqual(backend, "secret-service")
        return vault._active(self.st())

    def empty_hash(self):
        return sync.snapshot_hash(usage.snapshot_days({"days": {}}))

    def ok_gist(self, others=None, gid=GIST):
        """A private gist that already holds this machine's current (empty) snapshot."""
        files = {sync.MANIFEST: "{}", sync.my_file_name(): "{}"}
        files.update(others or {})
        return resp(200, gist_json(files, gid=gid))

    def mark_pushed(self):
        self.st().update(pushHash=self.empty_hash(), pushedAt=time.time())

    def cycle(self, **kw):
        return sync.sync_cycle({}, **kw)

    def state_text(self):
        try:
            with open(common.SYNC_STATE_PATH, encoding="utf-8") as f:
                return f.read()
        except FileNotFoundError:
            return ""


def assert_real_files_untouched(case=None):
    now = _isolate.real_files_state()
    if now != _isolate.REAL_BEFORE:
        changed = [p for p in now if now[p] != _isolate.REAL_BEFORE.get(p)]
        raise AssertionError("real files changed during tests: %s" % changed)
