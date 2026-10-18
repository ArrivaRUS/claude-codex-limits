"""REMOTE-LIMITS offline sandbox (docs/test-plan-remote-limits.md §0; lessons 006/011).

Order matters (lesson 006):
  1. Before any `ccl` import: take the REAL home from the passwd database (not $HOME), install an
     audit hook that refuses to open the real ~/.claude.json, ~/.claude/, ~/.codex/; `_real_guard` refuses and
     records every write of the test process to the app's real files (no mtime: a live publisher, A5).
  2. If `ccl` was not imported yet in this process, point $HOME to a temporary directory, so every
     `~` path `ccl.common` computes at import lands in the sandbox. Then import `_isolate`
     (XDG_* → temp, `common.http` / `sync.transport` / keyring → hard failures).
  3. `_isolate` points every CLI path constant of `ccl.common` — including the future `CLAUDE_JSON`
     (~/.claude.json) — into its temp ROOT; each test re-points them, `common.HOME` and $HOME into
     its own temp HOME and restores them afterwards (works whatever the import order).
Network: `common.http` and `sync.transport` stay forbidden; each test additionally refuses raw
socket connects. Clocks: `FakeClock`; nothing here reads wall time for a decision.
"""

import os
import pwd
import sys
import tempfile

if __package__:
    from . import _real_guard  # noqa: E402  (first: computes the real directories before HOME moves)
else:
    import _real_guard  # noqa: E402

REAL_HOME = pwd.getpwuid(os.getuid()).pw_dir
# The app's own real files (settings.json, publisher.jsonl, publisher-state.json, …) are guarded by `_real_guard`:
# any write of the test process is refused and recorded — no mtime, since an installed publisher (A5) rewrites them
# every 5 minutes. The live CLIs rewrite their own login files at any moment, so those are stricter still: any
# attempt to OPEN them fails.
FORBIDDEN_REAL = tuple(os.path.join(REAL_HOME, p) for p in (".claude.json", ".claude" + os.sep, ".codex" + os.sep))


def _deny_real_cli_files(event, args):
    if event == "open" and args and isinstance(args[0], (str, bytes)):
        path = os.path.abspath(os.fsdecode(args[0]))
        if path == FORBIDDEN_REAL[0] or path.startswith(FORBIDDEN_REAL[1:]):
            raise PermissionError("тест открыл реальный файл входа CLI: " + path)


sys.addaudithook(_deny_real_cli_files)  # process-wide and permanent: no test may read the owner's logins


SANDBOX_HOME = tempfile.mkdtemp(prefix="ccl-rl-home-", dir="/tmp")
if "ccl" not in sys.modules:
    os.environ["HOME"] = SANDBOX_HOME

if __package__:
    from . import _isolate  # noqa: E402
    from . import _sync_env  # noqa: E402
else:
    import _isolate  # noqa: E402
    import _sync_env  # noqa: E402

import copy  # noqa: E402
import json  # noqa: E402
from unittest import mock  # noqa: E402

from ccl import common  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FIXTURES = os.path.join(ROOT, "fixtures", "remote-limits")
LEGACY_MERGE = os.path.join(ROOT, "linux", "tests", "fixtures", "legacy_merge_045.py")
CLI_CONSTANTS = {"CLAUDE_JSON": ".claude.json", "CLAUDE_CREDENTIALS": ".claude/.credentials.json",
                 "CODEX_AUTH": ".codex/auth.json", "CLAUDE_PROJECTS": ".claude/projects",
                 "CODEX_SESSIONS": ".codex/sessions"}
NEW_KEYS = ("accounts", "unattributedDays", "captions", "lastSeenAt")
NOW = 1_791_800_000.0  # 2026-10-12T12:53:20Z — fixed; fixtures are dated 2026-10-10…12


def point_cli_paths(home):
    for name, rel in CLI_CONSTANTS.items():
        setattr(common, name, os.path.join(home, rel))


# Module level: `_isolate` already points every CLI constant (CLAUDE_JSON included) into its temp ROOT.
assert all(getattr(common, n).startswith(_isolate.ROOT) for n in CLI_CONSTANTS), "CLI paths outside the sandbox"


def assert_real_files_untouched():
    _real_guard.assert_clean()


def fixture_text(name):
    with open(os.path.join(FIXTURES, name), encoding="utf-8") as f:
        return f.read()


def fixture(name):
    return json.loads(fixture_text(name))


def strip_v11(obj):
    """The same machine file as an old (v1) writer would produce: new top-level keys removed."""
    return {k: copy.deepcopy(v) for k, v in obj.items() if k not in NEW_KEYS}


def load_legacy_merge():
    import importlib.util
    spec = importlib.util.spec_from_file_location("ccl_legacy_merge_045", LEGACY_MERGE)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def sentinels():
    """Synthetic PII/secrets; token-like values assembled here, never stored as literals."""
    raw = fixture("pii-sentinels.json")
    out = {k: v for k, v in raw.items() if isinstance(v, str) and not k.startswith("_")}
    for k, parts in raw["token_parts"].items():
        out[k] = "".join(parts)
    return out


class FakeClock(object):
    def __init__(self, now=NOW):
        self.now = float(now)

    def __call__(self):
        return self.now

    def advance(self, seconds):
        self.now += seconds
        return self.now


def _no_socket(*args, **kwargs):
    raise AssertionError("сеть в тестах запрещена (socket)")


class RLEnv(_sync_env.SyncEnv):
    """SyncEnv (temp config/state, scripted GitHub, fake keyring) + temp HOME with CLI login files."""

    def setUp(self):
        super().setUp()
        self.home = os.path.join(self.tmp, "home")
        os.makedirs(self.home)
        self._saved_cli = {n: getattr(common, n, None) for n in tuple(CLI_CONSTANTS) + ("HOME",)}
        self._saved_http = common.http
        point_cli_paths(self.home)
        common.HOME = self.home
        # expanduser("~") at call time must land in the sandbox too, even when ccl was imported earlier.
        p = mock.patch.dict(os.environ, {"HOME": self.home})
        p.start()
        self.addCleanup(p.stop)
        self.clock = FakeClock()
        for target in ("socket.socket.connect", "socket.socket.connect_ex", "socket.create_connection"):
            p = mock.patch(target, _no_socket)
            p.start()
            self.addCleanup(p.stop)
        self.assertIsNot(common.http, None)

    def tearDown(self):
        common.http = self._saved_http
        for n, v in self._saved_cli.items():
            if v is None:
                if hasattr(common, n):
                    delattr(common, n)
            else:
                setattr(common, n, v)
        super().tearDown()

    # ---- synthetic CLI login files ----------------------------------------------------------------
    def write_file(self, path, data, mode=0o600):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(data if isinstance(data, bytes) else data.encode("utf-8"))
        os.chmod(path, mode)
        return path

    def write_claude_json(self, account_uuid=None, *, oauth=True, extra=None, raw=None):
        """~/.claude.json with synthetic PII around oauthAccount.accountUuid."""
        if raw is not None:
            return self.write_file(common.CLAUDE_JSON, raw)
        s = sentinels()
        obj = {"numStartups": 7, "projects": {s["home"] + "/proj": {"allowedTools": []}}}
        if oauth:
            acct = {"organizationUuid": s["organizationUuid"], "emailAddress": s["email"], "fullName": s["fullName"],
                    "displayName": s["displayName"], "organizationName": s["organizationName"],
                    "profileFetchedAt": "2026-10-12T09:00:00Z"}
            if account_uuid is not None:
                acct["accountUuid"] = account_uuid
            obj["oauthAccount"] = acct
        obj.update(extra or {})
        return self.write_file(common.CLAUDE_JSON, json.dumps(obj))

    def write_claude_credentials(self, access="fixture-access-1", refresh="fixture-refresh-1"):
        obj = {"claudeAiOauth": {"accessToken": access, "refreshToken": refresh, "expiresAt": int((NOW + 3600) * 1000),
                                 "refreshTokenExpiresAt": int((NOW + 30 * 86400) * 1000), "scopes": ["user:inference"],
                                 "subscriptionType": "max", "rateLimitTier": "default_claude_max_20x"}}
        return self.write_file(common.CLAUDE_CREDENTIALS, json.dumps(obj))

    def write_codex_auth(self, account_id=None, raw=None):
        if raw is not None:
            return self.write_file(common.CODEX_AUTH, raw)
        s = sentinels()
        tokens = {"id_token": s["id_token"], "access_token": "fixture-codex-access", "refresh_token": "fixture-codex-refresh"}
        if account_id is not None:
            tokens["account_id"] = account_id
        return self.write_file(common.CODEX_AUTH, json.dumps({"OPENAI_API_KEY": s["OPENAI_API_KEY"],
                                                              "auth_mode": "chatgpt", "tokens": tokens}))

    def snap_cred(self):
        out = {}
        for path in (common.CLAUDE_JSON, common.CLAUDE_CREDENTIALS, common.CODEX_AUTH):
            try:
                st = os.stat(path)
                with open(path, "rb") as f:
                    import hashlib
                    digest = hashlib.sha256(f.read()).hexdigest()
                out[path] = (digest, st.st_size, st.st_mtime_ns, st.st_ino)
            except FileNotFoundError:
                out[path] = None
        return out

    def assert_no_sentinel(self, value, where):
        """Deep scan: no synthetic PII/secret value (whole, or its first 8 characters) inside `value`."""
        text = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False, default=repr)
        for key, s in sentinels().items():
            for needle in {s, s[:8]}:
                if key in ("home", "users"):
                    needle = s  # "/home/al" alone is a pattern, covered by assert_no_patterns
                self.assertNotIn(needle, text, "%s leaks sentinel %s" % (where, key))


# ==== A3: shared fakes for the publisher, coordination and the two-machine simulator ===========================
# (docs/test-plan-remote-limits.md §0 «Ledger + TrapTransport», «FakeGist», «FakeProvider»; lesson 011: one ledger
# with a sequence number for every GitHub call, provider request and state-file write; clocks are injected.)
import email.utils  # noqa: E402

import hashlib  # noqa: E402
import importlib  # noqa: E402
import time  # noqa: E402
from types import SimpleNamespace  # noqa: E402

GIST_ID = "g1"
API_ROOT = "https://api.github.com"
RAW_ROOT = "https://gist.githubusercontent.com/"
U_A = "3b9d6c1e-8f42-4a7b-9c05-2e6f1d8a4b70"
U_B = "7e1f2a3b-4c5d-4e6f-8a9b-0c1d2e3f4a5b"
CODEX_ID = "acct-fixture-0001-aaaa"
TEN_YEARS = 10 * 365 * 86400
STATE_FILES = ("state.json", "publisher-state.json")
# O1 allow-list (synth v2 §C «Журнал O1» + A3 contract additions: pass_skipped, pass_failed, accounts_days_dropped).
O1_EVENTS = frozenset((
    "poll_attempt", "poll_result", "poll_skipped", "pass_skipped", "pass_failed", "token_refresh", "publish",
    "clock_skew", "label_changed", "identity_changed", "remote_retry_capped", "policy_forced_never",
    "policy_violation", "pending_rotation_lost", "accounts_days_dropped"))
SKIP_REASONS = frozenset((
    "not_due", "fresh_remote", "remote_attempt", "tie_break", "retry_after", "no_github", "no_login", "no_label",
    "state_unsaved", "publish_failed", "token_policy", "busy"))


class Kill(BaseException):
    """A simulated SIGKILL: not an Exception, so a catch-all `except Exception` in run_pass does not swallow it."""


class Ledger(object):
    """One ordered journal of side effects. `dead` = the process was killed: every instrumented side effect
    raises Kill without happening. `kill_on[kind] = n` kills the process at the n-th event of `kind`."""

    def __init__(self, clock):
        self.clock = clock
        self.events = []
        self.dead = False
        self.kill_on = {}
        self.fail_paths = {}      # basename → exception instance raised by write_atomic
        self._counts = {}

    def add(self, kind, **kw):
        if self.dead:
            raise Kill()
        n = self._counts[kind] = self._counts.get(kind, 0) + 1
        if self.kill_on.get(kind) == n:      # killed right before this side effect: it never happens
            self.dead = True
            raise Kill()
        ev = SimpleNamespace(seq=len(self.events), kind=kind, t=self.clock(), **kw)
        self.events.append(ev)
        return ev

    def of(self, kind, **match):
        return [e for e in self.events if e.kind == kind and all(getattr(e, k, None) == v for k, v in match.items())]

    def since(self, mark):
        return self.events[mark:]

    def mark(self):
        return len(self.events)


def http_date(t):
    return email.utils.formatdate(t, usegmt=True)


class FakeGist(object):
    """A private gist with revisions, a `Date` header (= true clock + skew), scripted failures, raw URLs,
    a 16 MiB-overflow mode and per-reader visibility delay (simulator). Implements the sync.transport seam."""

    def __init__(self, clock, ledger, gid=GIST_ID, created="2026-09-01T00:00:00Z"):
        from ccl import sync as _sync
        self.clock, self.ledger, self.gid, self.created = clock, ledger, gid, created
        self.public = False
        self.skew = 0.0
        self.delay = 0.0
        self.reader = "me"
        self.revs = {}
        self.truncated = {}       # file name → raw_url served instead of inline content
        self.raw = {}             # raw_url → bytes (or callable → bytes)
        self.get_script, self.patch_script, self.list_script = [], [], []
        self.get_fail = None      # callable(reader, now) → Resp | None (outage)
        self.too_large = False    # GET /gists/{id} answers like a > 16 MiB body (N8)
        self.calls = []
        self.put(_sync.MANIFEST, _sync.manifest())

    # ---- test-side API ----
    def put(self, name, content, writer=None):
        """Seed or replace a file; writer None = visible to every reader at once."""
        self.revs.setdefault(name, []).append((self.clock(), writer, content))

    def current(self, name, reader=None):
        return self._visible(name, self.reader if reader is None else reader)

    def machine_file(self, name, reader=None):
        text = self.current(name, reader)
        return json.loads(text) if text else None

    # ---- transport ----
    def _headers(self):
        return {"date": http_date(self.clock() + self.skew)}

    def _resp(self, status, obj=None, raw=None):
        data = raw if raw is not None else (json.dumps(obj).encode("utf-8") if obj is not None else None)
        return common.Resp(status, data, self._headers())

    def _visible(self, name, reader):
        now = self.clock()
        for t, writer, content in reversed(self.revs.get(name) or []):
            if writer is None or writer == reader or t + self.delay <= now:
                return content
        return None

    def _raw_url(self, name, content):
        sha = hashlib.sha1((content or "").encode("utf-8", "surrogatepass")).hexdigest()[:12]
        return RAW_ROOT + "owner/" + self.gid + "/raw/" + sha + "/" + name

    def gist_json(self, listing=False):
        files = {}
        for name in sorted(self.revs):
            content = self._visible(name, self.reader)
            if content is None:
                continue
            if name in self.truncated:
                url = self.truncated[name]
                size = len(self.raw[url]) if isinstance(self.raw.get(url), (bytes, bytearray)) else 9 * 1024 * 1024
                f = {"filename": name, "size": size, "raw_url": url}
                if not listing:
                    f.update(truncated=True, content="")
            else:
                url = self._raw_url(name, content)
                self.raw.setdefault(url, content.encode("utf-8", "surrogatepass"))
                f = {"filename": name, "size": len(content.encode("utf-8", "surrogatepass")), "raw_url": url}
                if not listing:
                    f.update(truncated=False, content=content)
            files[name] = f
        out = {"id": self.gid, "public": self.public, "created_at": self.created, "files": files,
               "description": "Claude Codex Limits — usage sync (do not edit)"}
        if not listing:
            out["history"] = []
        return out

    @staticmethod
    def _scripted(script, rec):
        if not script:
            return None
        item = script.pop(0)
        if isinstance(item, BaseException):
            raise item
        if callable(item):
            return item(rec)
        return item

    def __call__(self, url, method, headers, body, timeout):
        if self.ledger.dead:
            raise Kill()
        now = self.clock()
        path = url[len(API_ROOT):] if url.startswith(API_ROOT) else url
        if isinstance(body, (bytes, bytearray)):
            body = body.decode("utf-8")
        if isinstance(body, str):
            body = json.loads(body)
        rec = SimpleNamespace(method=method, path=path, url=url, body=body, t=now, reader=self.reader,
                              authorized=any(k.lower() == "authorization" for k in headers))
        self.calls.append(rec)
        gpath = "/gists/" + self.gid
        if url.startswith(RAW_ROOT):
            self.ledger.add("RAW", url=url, reader=self.reader)
            data = self.raw.get(url)
            if callable(data):
                data = data()
            if data is None:
                return self._resp(404)
            return self._resp(200, raw=data)
        if path == gpath and method == "GET":
            self.ledger.add("GET", reader=self.reader)
            r = self._scripted(self.get_script, rec)
            if r is None and self.get_fail is not None:
                r = self.get_fail(self.reader, now)
            if r is not None:
                return r
            if self.too_large:
                return common.Resp(0, None, self._headers(), common.BODY_TOO_LARGE)
            return self._resp(200, self.gist_json())
        if path == gpath and method == "PATCH":
            self.ledger.add("PATCH", reader=self.reader, body=body)
            r = self._scripted(self.patch_script, rec)
            if r is None and self.get_fail is not None:
                r = self.get_fail(self.reader, now)
            if r is not None:
                return r
            for name, f in ((body or {}).get("files") or {}).items():
                if isinstance(f, dict) and isinstance(f.get("content"), str):
                    self.revs.setdefault(name, []).append((now, self.reader, f["content"]))
            return self._resp(200, self.gist_json())
        if path.startswith("/gists?") and method == "GET":
            self.ledger.add("LIST", reader=self.reader)
            r = self._scripted(self.list_script, rec)
            if r is None and self.get_fail is not None:
                r = self.get_fail(self.reader, now)
            if r is not None:
                return r
            return self._resp(200, [self.gist_json(listing=True)])
        if path == "/user" and method == "GET":
            self.ledger.add("USER", reader=self.reader)
            return self._resp(200, {"login": "me", "id": 1})
        if path == "/gists" and method == "POST":
            self.ledger.add("POST", reader=self.reader)
            return self._resp(500)
        self.ledger.add("UNEXPECTED", url=url, method=method)
        raise AssertionError("FakeGist: незаказанный запрос %s %s" % (method, url))


def reading(now, session=40.0, weekly=20.0, plan="max"):
    """A fresh successful provider answer (LimitData), as limits.fetch_* returns it."""
    from ccl import limits as _limits
    d = _limits.LimitData()
    d.session, d.weekly = session, weekly
    d.session_reset, d.weekly_reset = now + 3600, now + 3 * 86400
    d.plan, d.as_of, d.api_fresh, d.auth, d.http_status = plan, now, True, _limits.OK, 200
    return d


def rate_limited(now, retry_after):
    from ccl import limits as _limits
    d = _limits.LimitData()
    d.error, d.http_status, d.failure_kind, d.poll_failed = "HTTP 429", 429, "http", True
    d.server_retry_at = now + retry_after
    return d


def expired(now):
    from ccl import limits as _limits
    d = _limits.LimitData()
    d.auth, d.error, d.http_status, d.failure_kind = _limits.EXPIRED, "HTTP 401", 401, "auth"
    d.expired_reason, d.poll_failed = "signin_required", True
    return d


class FakeProviders(object):
    """Stand-in for limits.fetch_claude / limits.fetch_codex. Captures the local id BEFORE the request (like the
    real code, П2-в), logs ("provider", product, account) and answers from a queue or `default(product, now)`."""

    def __init__(self, clock, ledger):
        self.clock, self.ledger = clock, ledger
        self.replies = {"claude": [], "codex": []}
        self.default = lambda product, now: reading(now)
        self.on_call = None
        self.kill_after = False
        self.who = None           # simulator: callable → name of the machine that makes the request

    def fetch_claude(self):
        return self._call("claude")

    def fetch_codex(self, live=True):
        return self._call("codex")

    def _call(self, product):
        from ccl import accounts as _accounts
        if self.ledger.dead:
            raise Kill()
        local_id, _reason = _accounts.read_local_id(product)
        now = self.clock()
        self.ledger.add("provider", product=product, account=local_id, machine=self.who() if self.who else None)
        if self.kill_after:
            self.ledger.dead = True
            raise Kill()
        if self.on_call:
            self.on_call(product)
        q = self.replies[product]
        r = q.pop(0) if q else self.default
        if isinstance(r, BaseException):
            raise r
        d = r(product, now) if callable(r) else r
        if getattr(d, "account", None) is None:
            d.account = local_id
        return d

    def calls(self, product=None):
        return [e for e in self.ledger.events if e.kind == "provider" and (product is None or e.product == product)]


def read_o1(state_dir=None):
    path = os.path.join(state_dir or common.STATE_DIR, "publisher.jsonl")
    try:
        with open(path, encoding="utf-8") as f:
            lines = [ln for ln in f.read().splitlines() if ln.strip()]
    except FileNotFoundError:
        return []
    out = []
    for ln in lines:
        obj = json.loads(ln)
        if isinstance(obj, dict) and "ev" not in obj and "event" in obj:
            obj = dict(obj, ev=obj["event"])
        out.append(obj)
    return out


def iso(t):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))


class PubEnv(RLEnv):
    """Offline sandbox for publisher.run_pass: fake wall clock (time.time / time.sleep), FakeGist on sync.transport,
    FakeProviders on limits.fetch_*, every write_atomic logged in the Ledger, signed in to GitHub (gist g1),
    ~/.claude.json with account U_A, no Codex login, settings of an installed publisher."""

    CLAUDE_ID = U_A
    CODEX = False

    def setUp(self):
        super().setUp()
        from ccl import limits as _limits
        from ccl import sync as _sync
        self.ledger = Ledger(self.clock)
        self.sleeps = []
        self.patch(time, "time", self.clock)
        self.patch(time, "sleep", self._fake_sleep)
        self.gist = FakeGist(self.clock, self.ledger)
        _sync.transport = self.gist                      # SyncEnv.tearDown restores
        self.providers = FakeProviders(self.clock, self.ledger)
        self.patch(_limits, "fetch_claude", self.providers.fetch_claude)
        self.patch(_limits, "fetch_codex", self.providers.fetch_codex)
        self.patch(_limits, "_PENDING", {})
        real_write = common.write_atomic
        ledger = self.ledger

        def write_atomic(path, data, mode=0o600):
            name = os.path.basename(path)
            if name in STATE_FILES or name == "sync-state.json":
                if ledger.dead:
                    raise Kill()
                exc = ledger.fail_paths.get(name)
                if exc is not None:
                    raise exc
                ledger.add("write", name=name, data=data if isinstance(data, str) else bytes(data).decode("utf-8"))
            return real_write(path, data, mode)
        self.patch(common, "write_atomic", write_atomic)
        common.ensure_dirs()
        if self.CLAUDE_ID:
            self.write_claude_json(self.CLAUDE_ID)
        if self.CODEX:
            self.write_codex_auth(CODEX_ID)
        self.write_settings(publisher=True, autoPoll=True, credential_write="never", machineName="vps")
        self.sign_in()
        del self.ledger.events[:]
        self.ledger._counts.clear()

    def patch(self, owner, name, value):
        p = mock.patch.object(owner, name, value)
        p.start()
        self.addCleanup(p.stop)

    def _fake_sleep(self, seconds):
        self.sleeps.append(seconds)
        if len(self.sleeps) > 20000:
            raise AssertionError("ожидание без предела (20000 виртуальных sleep)")
        self.clock.advance(max(0.0, float(seconds)))

    def write_settings(self, **kw):
        obj = common.read_json(common.SETTINGS_PATH, {}) or {}
        obj.update(kw)
        os.makedirs(os.path.dirname(common.SETTINGS_PATH), exist_ok=True)
        with open(common.SETTINGS_PATH, "w", encoding="utf-8") as f:
            json.dump(obj, f)
        common._settings = None

    # ---- contract access ----
    def pub(self):
        try:
            return importlib.import_module("ccl.publisher")
        except ImportError as e:
            self.fail("contract: модуль ccl.publisher отсутствует (A3 не реализован): %s" % e)

    def need_sync(self, *names):
        from ccl import sync as _sync
        for n in names:
            if not callable(getattr(_sync, n, None)):
                self.fail("contract: ccl.sync.%s отсутствует (A3 не реализован)" % n)
        return _sync

    def tick(self, kind="auto"):
        """One pass; a simulated kill ends it like SIGKILL would."""
        pub = self.pub()
        if not callable(getattr(pub, "run_pass", None)):
            self.fail("contract: ccl.publisher.run_pass(kind) отсутствует")
        try:
            return pub.run_pass(kind)
        except Kill:
            return None

    def restart(self):
        """A new process: caches dropped, modules re-imported, the ledger alive again (state stays on disk)."""
        from ccl import limits as _limits
        from ccl import sync as _sync
        self.ledger.dead = False
        self.ledger.kill_on.clear()
        self.providers.kill_after = False
        common._state = common._settings = None
        _sync._first_attempt_at = None
        _limits._PENDING.clear()
        for name in ("ccl.publisher", "ccl.coordination"):
            if name in sys.modules:
                importlib.reload(sys.modules[name])

    # ---- observations ----
    def o1(self):
        return read_o1()

    def skipped(self, reason, product=None, events=None):
        return [e for e in (self.o1() if events is None else events)
                if e.get("ev") in ("poll_skipped", "pass_skipped") and e.get("reason") == reason
                and (product is None or e.get("product") in (product, None))]

    def label(self, product="claude", local_id=None):
        from ccl import accounts as _accounts
        if local_id is None:
            local_id = self.CLAUDE_ID if product == "claude" else CODEX_ID
        return _accounts.label(product=product, local_id=local_id, gist_id=GIST_ID)

    def my_file(self):
        from ccl import sync as _sync
        return _sync.my_file_name()

    def bodies(self, events=None):
        """Parsed machine files sent by this machine's PATCHes (in order), with their ledger events."""
        mine = self.my_file()
        out = []
        for e in (self.ledger.events if events is None else events):
            if e.kind != "PATCH":
                continue
            f = ((e.body or {}).get("files") or {}).get(mine)
            if isinstance(f, dict) and isinstance(f.get("content"), str):
                out.append((e, json.loads(f["content"])))
        return out

    @staticmethod
    def record(body, label, product="claude"):
        for r in (body or {}).get("accounts") or []:
            if r.get("product") == product and r.get("label") == label:
                return r
        return None

    def published(self, product="claude", local_id=None):
        """The last record of (product, label) this machine sent to the gist."""
        lab = self.label(product, local_id)
        for _e, body in reversed(self.bodies()):
            r = self.record(body, lab, product)
            if r is not None:
                return r
        return None

    def foreign(self, mid, records, last_seen=None, updated=None, name=None):
        """Another machine's v1.1 file in the gist (visible at once)."""
        now = self.clock()
        obj = {"schema": 1, "machine": {"id": mid, "name": "other", "os": "Test OS", "app": "linux 0.5.0"},
               "updated": iso(now if updated is None else updated),
               "lastSeenAt": iso(now if last_seen is None else last_seen) if last_seen != "absent" else None,
               "tz": "UTC", "days": {}, "accounts": records, "unattributedDays": {}, "captions": {}}
        if obj["lastSeenAt"] is None:
            del obj["lastSeenAt"]
        self.gist.put(name or "machine-%s.json" % mid, json.dumps(obj))
        return obj

    def foreign_record(self, product="claude", local_id=None, **kw):
        rec = {"product": product, "label": self.label(product, local_id), "status": "ok", "days": {}}
        rec.update(kw)
        return rec

    def state(self):
        return common.read_json(common.STATE_PATH, {}) or {}

    def publisher_state_text(self):
        try:
            with open(os.path.join(common.STATE_DIR, "publisher-state.json"), encoding="utf-8") as f:
                return f.read()
        except FileNotFoundError:
            return ""
