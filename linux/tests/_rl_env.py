"""REMOTE-LIMITS offline sandbox (docs/test-plan-remote-limits.md §0; lessons 006/011).

Order matters (lesson 006):
  1. Before any `ccl` import: take the REAL home from the passwd database (not $HOME), install an
     audit hook that refuses to open the real ~/.claude.json, ~/.claude/, ~/.codex/, and stat the
     app's own real files (presence + mtime only — contents are never read).
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

REAL_HOME = pwd.getpwuid(os.getuid()).pw_dir
# Files only this app writes: mtime must not move during the run. The live CLIs rewrite their own
# login files at any moment, so those are protected differently: any attempt to open them fails.
REAL_CLI_FILES = tuple(os.path.join(REAL_HOME, p) for p in (
    ".local/state/claude-codex-limits/publisher.jsonl", ".local/state/claude-codex-limits/publisher-state.json",
    ".config/claude-codex-limits/settings.json"))
FORBIDDEN_REAL = tuple(os.path.join(REAL_HOME, p) for p in (".claude.json", ".claude" + os.sep, ".codex" + os.sep))


def _deny_real_cli_files(event, args):
    if event == "open" and args and isinstance(args[0], (str, bytes)):
        path = os.path.abspath(os.fsdecode(args[0]))
        if path == FORBIDDEN_REAL[0] or path.startswith(FORBIDDEN_REAL[1:]):
            raise PermissionError("тест открыл реальный файл входа CLI: " + path)


sys.addaudithook(_deny_real_cli_files)  # process-wide and permanent: no test may read the owner's logins


def _real_state():
    out = {}
    for p in REAL_CLI_FILES:
        try:
            out[p] = os.stat(p).st_mtime_ns
        except OSError:
            out[p] = None
    return out


REAL_BEFORE = _real_state()
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
    now = _real_state()
    changed = [p for p in REAL_CLI_FILES if now[p] != REAL_BEFORE[p]]
    if changed:
        raise AssertionError("real CLI/publisher files changed during tests: %s" % changed)
    _sync_env.assert_real_files_untouched()


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
