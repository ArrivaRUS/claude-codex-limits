"""REMOTE-LIMITS A2 — token policy `never` by default (docs/test-plan-remote-limits.md A2-01…A2-11; T1 Т7–Т10, Т33, Т35).

Written BEFORE the code ("red first"). Until A2 lands, tests of the new API/behaviour fail with AssertionError
("contract: …" for a missing API, otherwise the violated rule). Tests marked «Green guard» pass on HEAD and must stay green.
Offline (lessons 006/011): temp HOME/XDG before imports (`_rl_env`), synthetic login files in the test's temp HOME,
`common.http` replaced by a recording trap (or the real `common.http` over an in-memory urllib server for A2-08),
sockets refused, wall clock frozen (`FakeClock`), sleeps virtual. «Untouched» = bytes, mtime_ns and inode before == after.

API contract assumed by these tests (synth v2 §E/§C, docs/plans.md §A2; names v2 does not fix were set by the tester —
see the A2 note in the test-plan):
  settings.json "credential_write" ∈ {"never", "guarded"}; absent/unknown → "never" on every machine (П3-д).
  ccl.common.credential_write() -> "never" | "guarded" — the EFFECTIVE policy, re-read from settings.json on every call;
      `publisher: true` + "guarded" → "never" and the O1 event `policy_forced_never` (П3-в).
  ccl.common.set_credential_write(value) — under file_lock("quota") with a bounded wait (≤ 60 s); raises
      ccl.common.CredentialPolicyRefused (Exception) when the lock stays busy, when limits._PENDING is non-empty or a
      rotation marker names a live pid (message mentions the rotation: «ротац…» / «rotation»); a dead-pid marker is removed.
  rotation marker: <STATE_DIR>/rotation-pending-<product>, written when limits._PENDING[product] is set, removed on pop
      (content pid + boot-id is the implementation's; tests create markers only through the real rotation path).
  limits — every attempt (fetch_claude, codex_access_token/codex_usage_live, fetch_codex(live=True)) reads the policy
      from settings.json at its start while file_lock("quota") is held (taken by the attempt itself unless this thread
      already holds it — never a nested blocking flock); every provider request and /oauth/token POST runs under it.
  never: 0 POST /oauth/token; no replay of _PENDING; no _PENDING/marker created; deadRefresh/deadCodexRefresh untouched.
      _save_claude_tokens/_save_codex_tokens → "refused"; _rewrite_json writes nothing (may raise); both log O1
      `policy_violation`; `_rotation_failure(data, "refused")` → failure_kind "credentials".
  LimitData.expired_reason ∈ {None, "cli_refresh_pending", "signin_required"} (contract key `expiredReason`, synth §E table).
  LimitData.account — normalized local id (`oauthAccount.accountUuid` / `tokens.account_id`) captured with the token,
      before the provider request (П2-в); None when unknown.
  limits.flush_pending() — graceful exit of a guarded process: one replay of each non-empty _PENDING under the old
      policy, otherwise O1 `pending_rotation_lost` (П3-б.2).
  O1: <STATE_DIR>/publisher.jsonl, one JSON object per line, event name under "ev" (plan-claude O1; "event" accepted).
  HTTP: provider and token requests pass follow_redirects=False and max_body (int, ≤ 16 MiB) to common.http;
      update.fetch_deb/apply pass max_body ≤ MAX_DEB / MAX_TARBALL (T2-r2 R1).
  CLI: `ccl-sync credentials --write never|guarded` → 0 and settings.json updated; refused → non-zero + rotation text.
      `ccl-sync status` prints a line «Политика токенов: never|guarded …» / «Token policy: …»; forced never names the publisher.
Run: python3 -m unittest linux/tests/test_rl_tokens.py -v   (from PROJECT_ROOT)
"""

if __package__:
    from . import _rl_env as rl
    from . import test_rl_contract_fixes as f1
    from . import test_rl_contract_fixes2 as f2
else:
    import _rl_env as rl
    import test_rl_contract_fixes as f1
    import test_rl_contract_fixes2 as f2

import base64
import builtins
import contextlib
import errno
import fcntl
import io
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
import unittest
from types import SimpleNamespace
from unittest import mock

from ccl import cli, common, limits, update

MiB = 1024 * 1024
CAP = 16 * MiB
NOW = rl.NOW
TESTS_DIR = os.path.dirname(os.path.abspath(__file__))

CLAUDE_USAGE = "https://api.anthropic.com/api/oauth/usage"
CLAUDE_TOKEN = "https://api.anthropic.com/v1/oauth/token"
CODEX_USAGE = "https://chatgpt.com/backend-api/wham/usage"
CODEX_TOKEN = "https://auth.openai.com/oauth/token"
USAGE = {"claude": CLAUDE_USAGE, "codex": CODEX_USAGE}
TOKEN = {"claude": CLAUDE_TOKEN, "codex": CODEX_TOKEN}
DEAD_KEY = {"claude": "deadRefresh", "codex": "deadCodexRefresh"}
ROTATION = re.compile(r"(?i)ротац|rotation")
POLICY_LINE = re.compile(r"(?im)^.*(политика токенов|token policy).*$")
U_A = "3b9d6c1e-8f42-4a7b-9c05-2e6f1d8a4b70"
U_B = "7e1f2a3b-4c5d-4e6f-8a9b-0c1d2e3f4a5b"
CODEX_ACCT = "acct-fixture-0001-aaaa"
MISSING = object()


def tearDownModule():
    rl.assert_real_files_untouched()


def read_bytes(path):
    with open(path, "rb") as f:
        return f.read()


def load(path):
    with open(path, "rb") as f:
        return json.loads(f.read().decode("utf-8"))


def iso(t):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))


def jwt(exp, salt="a"):
    """Unsigned JWT-shaped access token (only `exp` matters to the code); assembled at run time."""
    def enc(obj):
        return base64.urlsafe_b64encode(json.dumps(obj).encode()).decode().rstrip("=")
    return enc({"alg": "none", "typ": "JWT"}) + "." + enc({"exp": exp, "n": salt}) + ".fixture-signature"


def claude_usage_body():
    return {"five_hour": {"utilization": 42.0, "resets_at": iso(NOW + 3600)},
            "seven_day": {"utilization": 17.0, "resets_at": iso(NOW + 3 * 86400)}}


def codex_usage_body():
    return {"plan_type": "pro", "rate_limit": {
        "primary_window": {"used_percent": 31, "limit_window_seconds": 18000, "reset_at": NOW + 7200},
        "secondary_window": {"used_percent": 47, "limit_window_seconds": 604800, "reset_at": NOW + 86400}}}


def rotated(product):
    if product == "claude":
        return {"access_token": "fixture-rotated-access", "refresh_token": "fixture-rotated-refresh", "expires_in": 28800}
    return {"access_token": jwt(NOW + 7200, "rotated"), "refresh_token": "fixture-codex-rotated-refresh",
            "id_token": jwt(NOW + 7200, "id")}


def quota_lock_path():
    return os.path.join(common.STATE_DIR, "quota.lock")


def quota_locked():
    """Is file_lock("quota") held by anyone? flock is per open file description: a fresh fd conflicts even in-process."""
    path = quota_lock_path()
    if not os.path.exists(path):
        return False
    fd = os.open(path, os.O_RDWR)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as e:
        if e.errno in (errno.EAGAIN, errno.EACCES):
            return True
        raise
    else:
        fcntl.flock(fd, fcntl.LOCK_UN)
        return False
    finally:
        os.close(fd)


def marker_path(product):
    return os.path.join(common.STATE_DIR, "rotation-pending-" + product)


class Trap(object):
    """Recording stand-in for common.http: every call is logged with its kwargs and whether quota was held."""

    def __init__(self, events):
        self.calls, self.events, self.on_call, self.default = [], events, None, None
        self.overrides = {}  # url → Resp

    def __call__(self, url, method="GET", headers=None, body=None, timeout=15, follow_redirects=True, max_body=None, **kw):
        call = SimpleNamespace(url=url, method=method, headers=dict(headers or {}), body=body,
                               follow_redirects=follow_redirects, max_body=max_body, extra=kw, quota=quota_locked())
        self.calls.append(call)
        self.events.append(("http", url, call.quota))
        if self.on_call:
            self.on_call(call)
        if url in self.overrides:
            return self.overrides[url]
        if url == CLAUDE_USAGE:
            return common.Resp(200, json.dumps(claude_usage_body()).encode(), {})
        if url == CODEX_USAGE:
            return common.Resp(200, json.dumps(codex_usage_body()).encode(), {})
        if url == CLAUDE_TOKEN:
            return common.Resp(200, json.dumps(rotated("claude")).encode(), {})
        if url == CODEX_TOKEN:
            return common.Resp(200, json.dumps(rotated("codex")).encode(), {})
        if self.default is not None:
            return self.default
        raise AssertionError("незаказанный запрос: %s %s" % (method, url))

    def posts(self):
        return [c for c in self.calls if c.url in (CLAUDE_TOKEN, CODEX_TOKEN)]

    def usage(self):
        return [c for c in self.calls if c.url in (CLAUDE_USAGE, CODEX_USAGE)]


class Base(rl.RLEnv):
    def setUp(self):
        super().setUp()
        self.events = []        # unified ledger: ("http", url, quota) / ("write", path, quota) / ("open", path, quota)
        self.trap = Trap(self.events)
        common.http = self.trap  # restored by RLEnv.tearDown
        self.patch(limits, "_PENDING", {})
        self.patch(time, "time", self.clock)
        self.sleeps = []
        self.patch(time, "sleep", self._sleep)
        real_write = common.write_atomic

        def write_atomic(path, data, mode=0o600):
            self.events.append(("write", os.path.abspath(path), quota_locked()))
            return real_write(path, data, mode)
        self.patch(common, "write_atomic", write_atomic)
        real_lock = common.file_lock
        self.forbid_unbounded_quota_wait = False

        def file_lock(name, blocking=True, timeout=None):
            if name == "quota" and blocking and common.lock_held_by_thread("quota"):
                raise AssertionError("вложенный блокирующий file_lock('quota') в одном потоке = deadlock (flock на новый fd)")
            if name == "quota" and blocking and timeout is None and self.forbid_unbounded_quota_wait:
                raise AssertionError("file_lock('quota') без предела ожидания (план: ≤ 60 с)")
            self.events.append(("lock", name, blocking, timeout))
            return real_lock(name, blocking, timeout)
        self.patch(common, "file_lock", file_lock)
        common.ensure_dirs()

    def patch(self, owner, name, value):
        p = mock.patch.object(owner, name, value)
        p.start()
        self.addCleanup(p.stop)

    def _sleep(self, seconds):
        self.sleeps.append(seconds)
        if len(self.sleeps) > 5000:
            raise AssertionError("ожидание без предела (5000 виртуальных sleep)")
        self.clock.advance(max(0.0, float(seconds)))

    # ---- contract helpers ----------------------------------------------------------------------------------------
    def need_common(self, *names):
        for n in names:
            if not hasattr(common, n):
                self.fail("contract: ccl.common.%s отсутствует (A2 не реализован)" % n)

    def need_limits(self, *names):
        for n in names:
            if not hasattr(limits, n):
                self.fail("contract: ccl.limits.%s отсутствует (A2 не реализован)" % n)

    def reason(self, d):
        v = getattr(d, "expired_reason", MISSING)
        if v is MISSING:
            self.fail("contract: LimitData.expired_reason отсутствует (synth §E: expired + cli_refresh_pending/signin_required)")
        return v

    def refused_error(self):
        self.need_common("set_credential_write", "CredentialPolicyRefused")
        return common.CredentialPolicyRefused

    # ---- settings (written as another process would: straight to the file) ----------------------------------------
    def set_policy(self, value=MISSING, publisher=MISSING, reset=True):
        obj = common.read_json(common.SETTINGS_PATH, {}) or {}
        for key, v in (("credential_write", value), ("publisher", publisher)):
            if v is MISSING:
                continue
            if v is None:
                obj.pop(key, None)
            else:
                obj[key] = v
        os.makedirs(os.path.dirname(common.SETTINGS_PATH), exist_ok=True)
        with open(common.SETTINGS_PATH, "w", encoding="utf-8") as f:
            json.dump(obj, f)
        if reset:
            common._settings = None

    def settings_on_disk(self):
        return common.read_json(common.SETTINGS_PATH, {}) or {}

    # ---- synthetic login files ----------------------------------------------------------------------------------
    def claude_creds(self, state, access="fixture-access-1", refresh="fixture-refresh-1"):
        path = common.CLAUDE_CREDENTIALS
        if state == "absent":
            with contextlib.suppress(FileNotFoundError):
                os.unlink(path)
            return None
        exp = {"live": NOW + 3600, "expiring": NOW - 1, "expiring_soon": NOW + 60}.get(state, NOW - 1)
        oauth = {"accessToken": access, "refreshToken": refresh, "expiresAt": int(exp * 1000),
                 "refreshTokenExpiresAt": int((NOW - 1 if state == "dead_rt_expired" else NOW + 30 * 86400) * 1000),
                 "scopes": ["user:inference"], "subscriptionType": "max", "rateLimitTier": "default_claude_max_20x"}
        if state == "dead_no_rt":
            del oauth["refreshToken"]
            del oauth["refreshTokenExpiresAt"]
        text = json.dumps({"claudeAiOauth": oauth, "otherCliField": {"keep": True}}, indent=2)
        if state == "partial":
            text = text[:len(text) // 2]
        if state == "empty":
            text = ""
        return self.write_file(path, text)

    def codex_auth(self, state, account=CODEX_ACCT, refresh="fixture-codex-refresh-1", exp=None):
        path = common.CODEX_AUTH
        if state == "absent":
            with contextlib.suppress(FileNotFoundError):
                os.unlink(path)
            return None
        if exp is None:
            exp = NOW + 3600 if state == "live" else NOW - 60
        tokens = {"id_token": jwt(exp, "id"), "access_token": jwt(exp), "refresh_token": refresh, "account_id": account}
        if state == "dead_no_rt":
            del tokens["refresh_token"]
        text = json.dumps({"auth_mode": "chatgpt", "tokens": tokens, "last_refresh": "2026-10-12T09:00:00Z"}, indent=2)
        if state == "partial":
            text = text[:len(text) // 2]
        if state == "empty":
            text = ""
        return self.write_file(path, text)

    def creds(self, product, state, **kw):
        return self.claude_creds(state, **kw) if product == "claude" else self.codex_auth(state, **kw)

    def cred_path(self, product):
        return common.CLAUDE_CREDENTIALS if product == "claude" else common.CODEX_AUTH

    def attempt(self, product):
        """One live attempt as the publisher/tray/CLI would run it."""
        return limits.fetch_claude() if product == "claude" else limits.fetch_codex(live=True)

    def reset_round(self):
        self.trap.calls.clear()
        self.trap.on_call = None
        self.trap.overrides.clear()
        del self.events[:]
        del self.sleeps[:]
        limits._PENDING.clear()
        for p in ("claude", "codex"):
            with contextlib.suppress(FileNotFoundError):
                os.unlink(marker_path(p))
        common.state().remove("deadRefresh", "deadCodexRefresh")
        with contextlib.suppress(FileNotFoundError):
            os.unlink(common.CACHE_PATH)

    def o1_events(self):
        path = os.path.join(common.STATE_DIR, "publisher.jsonl")
        try:
            with open(path, encoding="utf-8") as f:
                lines = [ln for ln in f.read().splitlines() if ln.strip()]
        except FileNotFoundError:
            return []
        out = []
        for ln in lines:
            try:
                obj = json.loads(ln)
            except ValueError:
                self.fail("O1: строка журнала не JSON")
            out.append(obj.get("ev", obj.get("event")) if isinstance(obj, dict) else None)
        return out

    def cred_writes(self):
        paths = {os.path.abspath(common.CLAUDE_CREDENTIALS), os.path.abspath(common.CODEX_AUTH),
                 os.path.abspath(common.CLAUDE_JSON)}
        return [e for e in self.events if e[0] == "write" and e[1] in paths]

    def assert_untouched(self, before, where):
        self.assertEqual(self.snap_cred(), before, "%s: файл входа изменён (байты/mtime_ns/ino)" % where)
        self.assertEqual(self.cred_writes(), [], "%s: запись в файл входа в журнале записей" % where)

    def make_pending(self, product):
        """Real guarded rotation whose write-back cannot land: POST succeeds, the file is mid-write when re-read."""
        self.set_policy("guarded")
        self.creds(product, "expiring")
        original = read_bytes(self.cred_path(product))

        def truncate(call):
            if call.url == TOKEN[product]:
                with open(self.cred_path(product), "wb") as f:
                    f.write(original[:len(original) // 2])
        self.trap.on_call = truncate
        if product == "claude":
            limits.fetch_claude()
        else:
            limits.codex_usage_live()
        self.trap.on_call = None
        if product not in limits._PENDING:
            self.fail("предусловие: guarded-ротация с недочитанным файлом не оставила _PENDING[%s]" % product)
        return original

    def run_cli(self, argv):
        out, err = io.StringIO(), io.StringIO()
        try:
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err), \
                    mock.patch.object(cli, "_timer_status", return_value="test timer"):
                code = cli.main(argv)
        except SystemExit as e:
            code = e.code
        return code, out.getvalue() + err.getvalue()

    def status_text(self):
        code, text = self.run_cli(["status"])
        self.assertEqual(code, 0, "ccl-sync status упал: %s" % text[-400:])
        return text

    def watchdog(self, seconds=30):
        """Real-time alarm: a blocking flock without a deadline must fail the test, not hang the suite."""
        def boom(signum, frame):
            raise AssertionError("тест завис > %d с (блокирующее ожидание без предела)" % seconds)
        old = signal.signal(signal.SIGALRM, boom)
        signal.alarm(seconds)

        def restore():
            signal.alarm(0)
            signal.signal(signal.SIGALRM, old)
        self.addCleanup(restore)

    def sandbox_paths(self):
        return {k: v for k, v in vars(common).items()
                if k.isupper() and isinstance(v, str) and v.startswith(self.tmp)}


# ---- A2-01 (Т7) never × Claude/Codex × login-file states ----------------------------------------------------------
class TestA201NeverStates(Base):
    """Red now: no policy — expiring/dead files trigger POST /oauth/token and a rewrite; LimitData.expired_reason absent."""

    CLAUDE = (("live", "ok"), ("expiring", "cli_refresh_pending"), ("expiring_soon", "cli_refresh_pending"),
              ("dead_rt_expired", "signin_required"), ("dead_no_rt", "signin_required"),
              ("absent", "signed_out"), ("partial", "error"), ("empty", "error"))
    CODEX = (("live", "ok"), ("expiring", "cli_refresh_pending"), ("dead_no_rt", "signin_required"),
             ("absent", "signed_out"), ("partial", "error"), ("empty", "error"))

    def check_state(self, product, state, expected):
        self.reset_round()
        self.set_policy(None)  # default: never
        self.creds(product, state)
        before = self.snap_cred()
        d = self.attempt(product)
        self.assert_untouched(before, "%s/%s" % (product, state))
        self.assertEqual(self.trap.posts(), [], "never: POST /oauth/token запрещён")
        usage = self.trap.usage()
        if expected == "ok":
            self.assertEqual([c.url for c in usage], [USAGE[product]], "live: ровно один usage-запрос")
            self.assertEqual(d.auth, limits.OK)
            self.assertTrue(d.api_fresh)
            self.assertIsNone(d.error)
            self.assertIsNone(self.reason(d))
        else:
            self.assertEqual(usage, [], "usage — только в live")
            self.assertFalse(d.api_fresh)
            self.assertIsNone(d.as_of, "новый asOf без запроса не появляется")
            if expected in ("cli_refresh_pending", "signin_required"):
                self.assertEqual(d.auth, limits.EXPIRED)
                self.assertEqual(self.reason(d), expected)
            elif expected == "signed_out":
                self.assertEqual(d.auth, limits.LOGGED_OUT)
                self.assertEqual((d.session, d.weekly), (None, None), "signed_out без значений")
            else:
                self.assertEqual(d.auth, limits.READ_ERROR)
                self.assertEqual(d.failure_kind, "credentials")
        st = common.state()
        st.reload()
        self.assertFalse(st.has(DEAD_KEY[product]), "never: %s не трогается" % DEAD_KEY[product])
        self.assertEqual(limits._PENDING, {}, "never: _PENDING не создаётся")
        self.assertFalse(os.path.exists(marker_path(product)), "never: маркер ротации не создаётся")

    def test_claude_states_never(self):
        for state, expected in self.CLAUDE:
            with self.subTest(state=state):
                self.check_state("claude", state, expected)

    def test_codex_states_never(self):
        for state, expected in self.CODEX:
            with self.subTest(state=state):
                self.check_state("codex", state, expected)

    def test_expiring_keeps_previous_values_and_asof(self):
        """C3: expired + cli_refresh_pending carries the previous reading and its asOf, cache untouched."""
        for product in ("claude", "codex"):
            with self.subTest(product=product):
                self.reset_round()
                self.set_policy(None)
                prev = limits.LimitData()
                prev.session, prev.weekly, prev.as_of = 33.0, 12.0, NOW - 600
                prev.session_reset, prev.weekly_reset = NOW + 3600, NOW + 86400
                common.write_json(common.CACHE_PATH, {product: prev.to_dict()})
                cache_before = read_bytes(common.CACHE_PATH)
                self.creds(product, "expiring")
                merged = limits.apply_provider_cache(product, self.attempt(product))
                self.assertEqual(self.trap.calls, [], "0 запросов")
                self.assertEqual((merged.session, merged.as_of), (33.0, NOW - 600), "прежние значения и asOf")
                self.assertEqual(merged.auth, limits.EXPIRED)
                self.assertEqual(self.reason(merged), "cli_refresh_pending")
                self.assertEqual(read_bytes(common.CACHE_PATH), cache_before)

    def test_unreadable_login_file_is_retried_then_error(self):
        """Red now: one read only. §E: read_error = «не читается после 5×0,2 с»; a mid-write file that recovers is read."""
        real_open = builtins.open
        for product in ("claude", "codex"):
            for recovers in (False, True):
                with self.subTest(product=product, recovers=recovers):
                    self.reset_round()
                    self.set_policy(None)
                    self.creds(product, "empty")
                    path = os.path.abspath(self.cred_path(product))
                    reads = []

                    def counting_open(file, mode="r", *a, **kw):
                        if isinstance(file, str) and os.path.abspath(file) == path and "r" in mode and "+" not in mode:
                            reads.append(1)
                            if recovers and len(reads) == 3:
                                self.creds(product, "live")
                        return real_open(file, mode, *a, **kw)
                    with mock.patch("builtins.open", counting_open):
                        d = self.attempt(product)
                    if recovers:
                        self.assertEqual(d.auth, limits.OK, "файл дописан на 3-й попытке → прочитан")
                        self.assertEqual([c.url for c in self.trap.usage()], [USAGE[product]])
                    else:
                        self.assertGreaterEqual(len(reads), 5, "≥ 5 чтений до read_error")
                        self.assertEqual(d.auth, limits.READ_ERROR)
                        self.assertEqual(self.trap.calls, [])
                    self.assertLessEqual(sum(self.sleeps), 1.0, "паузы 5×0,2 с — виртуальные, ≤ 1 с")


# ---- A2-02 (Т8) guard inside _save_* / _rewrite_json ---------------------------------------------------------------
class TestA202SaveGuard(Base):
    def pending_entry(self, product):
        if product == "claude":
            return {"old": "fixture-refresh-1", "access": "fixture-access-1", "tok": rotated("claude"), "t": NOW}
        root = load(common.CODEX_AUTH)
        return {"old": "fixture-codex-refresh-1", "access": root["tokens"]["access_token"], "account": CODEX_ACCT,
                "tok": rotated("codex")}

    def save(self, product, entry):
        if product == "claude":
            first = load(common.CLAUDE_CREDENTIALS)
            return limits._save_claude_tokens(common.CLAUDE_CREDENTIALS, entry["old"], entry["tok"], NOW, first)
        return limits._save_codex_tokens(entry["old"], entry["tok"], load(common.CODEX_AUTH))

    def test_save_refused_in_never(self):
        """Red now: _save_* rewrites the CLI file (outcome "saved"); no policy_violation."""
        for product in ("claude", "codex"):
            for preset in (True, False):
                with self.subTest(product=product, pending_preset=preset):
                    self.reset_round()
                    self.set_policy(None)
                    self.creds(product, "live")
                    common.state().update(**{DEAD_KEY[product]: "fixture-dead-fp"})
                    entry = self.pending_entry(product)
                    if preset:
                        limits._PENDING[product] = dict(entry)
                    before = self.snap_cred()
                    violations = self.o1_events().count("policy_violation")
                    outcome = self.save(product, entry)
                    self.assertEqual(outcome, "refused", "never: _save_* → refused")
                    self.assert_untouched(before, "_save_%s_tokens" % product)
                    self.assertGreater(self.o1_events().count("policy_violation"), violations, "O1 policy_violation")
                    d = limits._rotation_failure(limits.LimitData(), outcome)
                    self.assertEqual(d.failure_kind, "credentials", "результат error/credentials")
                    self.assertTrue(d.poll_failed)
                    st = common.state()
                    st.reload()
                    self.assertEqual(st.get(DEAD_KEY[product]), "fixture-dead-fp", "%s не меняется" % DEAD_KEY[product])
                    self.assertFalse(os.path.exists(marker_path(product)), "never: маркер не создаётся")
                    if not preset:
                        self.assertNotIn(product, limits._PENDING, "never: _PENDING не наполняется")

    def test_rewrite_json_refused_in_never(self):
        """Red now: _rewrite_json writes the CLI file."""
        for product in ("claude", "codex"):
            with self.subTest(product=product):
                self.reset_round()
                self.set_policy(None)
                self.creds(product, "live")
                path = self.cred_path(product)
                obj = load(path)
                obj["injected"] = True
                before = self.snap_cred()
                violations = self.o1_events().count("policy_violation")
                try:
                    limits._rewrite_json(path, obj)
                except Exception:  # refusing by raising is allowed; writing is not
                    pass
                self.assert_untouched(before, "_rewrite_json(%s)" % product)
                self.assertGreater(self.o1_events().count("policy_violation"), violations, "O1 policy_violation")


# ---- A2-03 guard BEFORE the replay of _PENDING ------------------------------------------------------------------------
class TestA203NoReplayInNever(Base):
    def test_pending_is_not_replayed_in_never(self):
        """Red now: fetch_claude/codex_access_token replay _PENDING and rewrite the CLI file."""
        for product in ("claude", "codex"):
            with self.subTest(product=product):
                self.reset_round()
                self.set_policy(None)
                self.creds(product, "live")
                root = load(self.cred_path(product))
                if product == "claude":
                    entry = {"old": "fixture-refresh-1", "access": "fixture-access-1", "tok": rotated("claude"), "t": NOW}
                else:
                    entry = {"old": "fixture-codex-refresh-1", "access": root["tokens"]["access_token"],
                             "account": CODEX_ACCT, "tok": rotated("codex")}
                limits._PENDING[product] = entry
                before = self.snap_cred()
                if product == "claude":
                    limits.fetch_claude()
                else:
                    limits.codex_usage_live()
                self.assert_untouched(before, "replay %s" % product)
                self.assertEqual(self.trap.posts(), [])
                self.assertEqual(set(limits._PENDING) - {product}, set(), "_PENDING не наполняется")
                if product in limits._PENDING:
                    self.assertIs(limits._PENDING[product], entry, "запись _PENDING не подменена новой парой")
                self.assertFalse(os.path.exists(marker_path(product)))


# ---- A2-04 set_credential_write(): busy lock, live marker, dead marker -------------------------------------------------
class TestA204SetCredentialWrite(Base):
    def test_busy_quota_lock_waits_bounded_then_refuses(self):
        """Red now: contract — common.set_credential_write / CredentialPolicyRefused absent."""
        refused = self.refused_error()
        self.set_policy("guarded")
        lock = quota_lock_path()
        holder = subprocess.Popen(
            [sys.executable, "-I", "-c",
             "import fcntl, os, sys\n"
             "fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600)\n"
             "fcntl.flock(fd, fcntl.LOCK_EX)\n"
             "print('locked', flush=True)\n"
             "sys.stdin.read()\n", lock],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        self.addCleanup(holder.wait, 30)
        self.addCleanup(holder.kill)
        self.assertEqual(holder.stdout.readline().strip(), "locked")
        self.assertTrue(quota_locked())
        self.watchdog(30)
        self.forbid_unbounded_quota_wait = True
        start = self.clock.now
        with mock.patch.object(time, "monotonic", self.clock), self.assertRaises(refused):
            common.set_credential_write("never")
        waited = self.clock.now - start
        self.assertGreater(waited, 0, "отказ без ожидания замка")
        self.assertLessEqual(waited, 61, "ожидание замка quota ≤ 60 с (виртуальное время)")
        self.assertEqual(self.settings_on_disk().get("credential_write"), "guarded", "политика не сменилась")

    def test_live_rotation_marker_refuses(self):
        """Red now: contract — no marker is written when _PENDING is set; set_credential_write absent."""
        refused = self.refused_error()
        self.make_pending("claude")
        self.assertTrue(os.path.exists(marker_path("claude")),
                        "contract: маркер rotation-pending-claude не создан при установке _PENDING")
        with self.assertRaises(refused) as cm:
            common.set_credential_write("never")
        self.assertRegex(str(cm.exception), ROTATION, "текст отказа — про незавершённую ротацию")
        self.assertEqual(self.settings_on_disk().get("credential_write"), "guarded")
        self.assertTrue(os.path.exists(marker_path("claude")), "живой маркер не удаляется")

    def test_marker_from_previous_boot_is_dead_even_with_live_pid(self):
        """Red now: contract — no marker / set_credential_write. Юрка 2026-10-13: live pid + boot-id of a previous boot =
        reused pid → the marker is dead: removed, the change passes."""
        self.need_common("set_credential_write")
        self.make_pending("claude")
        path = marker_path("claude")
        self.assertTrue(os.path.exists(path), "contract: маркер rotation-pending-claude не создан при установке _PENDING")
        with open("/proc/sys/kernel/random/boot_id", encoding="ascii") as f:
            boot = f.read().strip()
        content = read_bytes(path).decode("utf-8")
        forms = [b for b in (boot, boot.replace("-", "")) if b and b in content]
        self.assertTrue(forms, "contract: маркер содержит pid + boot-id текущей загрузки")
        self.assertIn(str(os.getpid()), content, "contract: маркер содержит pid процесса")
        old_boot = "00000000-0000-4000-8000-000000000000"
        for b in forms:
            content = content.replace(b, old_boot if "-" in b else old_boot.replace("-", ""))
        self.write_file(path, content)
        limits._PENDING.clear()  # the old process is gone; our live pid only collides by number
        common.set_credential_write("never")
        self.assertFalse(os.path.exists(path), "маркер прошлой загрузки удалён")
        self.assertEqual(self.settings_on_disk().get("credential_write"), "never", "смена прошла")

    def test_dead_rotation_marker_is_removed_and_change_passes(self):
        """Red now: contract — the crashed guarded process leaves no marker; set_credential_write absent."""
        self.need_common("set_credential_write")
        self.set_policy("guarded")
        self.claude_creds("expiring")
        cfg = {"tests": TESTS_DIR, "home": self.home, "paths": self.sandbox_paths(),
               "partial": read_bytes(common.CLAUDE_CREDENTIALS).decode()[:40]}
        script = (
            "import json, os, sys\n"
            "cfg = json.loads(sys.argv[1])\n"
            "sys.path.insert(0, cfg['tests'])\n"
            "import _rl_env as rl\n"
            "from ccl import common, limits\n"
            "for k, v in cfg['paths'].items(): setattr(common, k, v)\n"
            "common.HOME = cfg['home']; common._settings = common._state = None\n"
            "import time; time.sleep = lambda s: None\n"
            "def http(url, method='GET', headers=None, body=None, timeout=15, follow_redirects=True, max_body=None, **kw):\n"
            "    if url.endswith('/oauth/token'):\n"
            "        with open(common.CLAUDE_CREDENTIALS, 'w') as f: f.write(cfg['partial'])\n"
            "        tok = {'access_token': 'fixture-rotated-access', 'refresh_token': 'fixture-rotated-refresh', 'expires_in': 28800}\n"
            "        return common.Resp(200, json.dumps(tok).encode(), {})\n"
            "    raise AssertionError('unexpected request')\n"
            "common.http = http\n"
            "limits.fetch_claude()\n"
            "print(json.dumps({'pending': 'claude' in limits._PENDING, 'pid': os.getpid(),\n"
            "                  'cleanup': [rl.SANDBOX_HOME, rl._isolate.ROOT]}), flush=True)\n"
            "os._exit(0)\n")
        env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
        child = subprocess.run([sys.executable, "-I", "-c", script, json.dumps(cfg)], stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, text=True, timeout=120, env=env)
        self.assertEqual(child.returncode, 0, "дочерний процесс: %s" % child.stderr[-800:])
        report = json.loads(child.stdout.strip().splitlines()[-1])
        for d in report["cleanup"]:
            if d.startswith("/tmp/ccl-"):
                shutil.rmtree(d, ignore_errors=True)
        self.assertTrue(report["pending"], "предусловие: guarded-ротация в дочернем процессе оставила _PENDING")
        with self.assertRaises(ProcessLookupError):
            os.kill(report["pid"], 0)
        self.assertTrue(os.path.exists(marker_path("claude")),
                        "contract: упавший guarded-процесс не оставил маркер rotation-pending-claude")
        common.set_credential_write("never")
        self.assertFalse(os.path.exists(marker_path("claude")), "маркер с мёртвым pid удалён")
        self.assertEqual(self.settings_on_disk().get("credential_write"), "never", "смена прошла")


# ---- A2-05 (Т9, П3-в) publisher: true forces never ---------------------------------------------------------------------
class TestA205PublisherForcesNever(Base):
    def test_publisher_guarded_is_forced_never(self):
        """Red now: contract — common.credential_write absent; guarded behaviour (POST) on a publisher machine."""
        self.need_common("credential_write")
        self.set_policy("guarded", publisher=True)
        self.assertEqual(common.credential_write(), "never")
        self.assertIn("policy_forced_never", self.o1_events(), "O1 policy_forced_never")
        for product in ("claude", "codex"):
            with self.subTest(product=product):
                self.reset_round()
                self.creds(product, "expiring")
                before = self.snap_cred()
                d = self.attempt(product)
                self.assertEqual(self.trap.calls, [], "издатель: 0 запросов при истёкшем access")
                self.assert_untouched(before, "publisher/%s" % product)
                self.assertEqual(self.reason(d), "cli_refresh_pending")

    def test_status_shows_forced_never(self):
        """Red now: `ccl-sync status` has no token-policy line."""
        self.set_policy("guarded", publisher=True)
        line = POLICY_LINE.search(self.status_text())
        self.assertIsNotNone(line, "status: строка политики токенов")
        self.assertRegex(line.group(0), r"\bnever\b")
        self.assertRegex(line.group(0), r"(?i)издател|publisher|принудит|forced")


# ---- A2-06 (Т10, Т33, П3-д) never by default, guarded only as explicit opt-in --------------------------------------
class TestA206DefaultAndGuardedOptIn(Base):
    def test_default_policy_is_never(self):
        """Red now: contract — common.credential_write absent."""
        self.need_common("credential_write")
        for raw in (MISSING, "yes", 1, "GUARDED ", "legacy"):
            with self.subTest(settings=raw):
                self.set_policy(None)
                if raw is not MISSING:
                    self.set_policy(raw)
                self.assertEqual(common.credential_write(), "never")
        self.set_policy("guarded", publisher=False)
        self.assertEqual(common.credential_write(), "guarded", "явный opt-in без издателя")

    def test_guarded_opt_in_refreshes_and_writes_pair(self):
        """Green guard: today's guarded behaviour (refresh + atomic write-back keeping other fields) survives as opt-in."""
        for product in ("claude", "codex"):
            with self.subTest(product=product):
                self.reset_round()
                self.set_policy("guarded")
                self.creds(product, "expiring")
                d = self.attempt(product)
                self.assertEqual([c.url for c in self.trap.posts()], [TOKEN[product]], "guarded: ровно один POST")
                usage = self.trap.usage()
                self.assertEqual(len(usage), 1)
                self.assertEqual(usage[0].headers.get("Authorization"), "Bearer " + rotated(product)["access_token"])
                self.assertTrue(d.api_fresh)
                written = load(self.cred_path(product))
                if product == "claude":
                    self.assertEqual(written["claudeAiOauth"]["accessToken"], "fixture-rotated-access")
                    self.assertEqual(written["claudeAiOauth"]["refreshToken"], "fixture-rotated-refresh")
                    self.assertEqual(written["claudeAiOauth"]["subscriptionType"], "max")
                    self.assertEqual(written["otherCliField"], {"keep": True})
                else:
                    self.assertEqual(written["tokens"]["refresh_token"], "fixture-codex-rotated-refresh")
                    self.assertEqual(written["tokens"]["account_id"], CODEX_ACCT)
                    self.assertEqual(written["auth_mode"], "chatgpt")
                self.assertEqual(limits._PENDING, {})

    def test_status_names_the_policy(self):
        """Red now: `ccl-sync status` has no token-policy line (П3-д: opt-in visible in status)."""
        for value, word in ((None, "never"), ("guarded", "guarded")):
            with self.subTest(policy=word):
                self.set_policy(value, publisher=None)
                line = POLICY_LINE.search(self.status_text())
                self.assertIsNotNone(line, "status: строка политики токенов")
                self.assertRegex(line.group(0), r"\b%s\b" % word)


# ---- A2-07 (Т33, П3-б.2) guarded worker exits with a pending pair --------------------------------------------------
class TestA207PendingOnExit(Base):
    def test_exit_replays_pair_or_logs_lost(self):
        """Red now: contract — limits.flush_pending absent."""
        self.need_limits("flush_pending")
        for product in ("claude", "codex"):
            with self.subTest(product=product):
                self.reset_round()
                original = self.make_pending(product)
                self.write_file(self.cred_path(product), original)   # the CLI file is readable again, still the old pair
                self.set_policy("never", reset=False)                 # settings changed by hand meanwhile
                limits.flush_pending()
                now = read_bytes(self.cred_path(product))
                obj = json.loads(now.decode("utf-8"))                 # never a corrupt file
                block = obj["claudeAiOauth"] if product == "claude" else obj["tokens"]
                key_rt = "refreshToken" if product == "claude" else "refresh_token"
                if now == original:
                    self.assertIn("pending_rotation_lost", self.o1_events(), "пара не дописана → pending_rotation_lost")
                else:
                    self.assertEqual(block[key_rt], rotated(product)["refresh_token"], "дописана именно ротированная пара")
                self.assertNotIn(product, limits._PENDING)
                self.assertFalse(os.path.exists(marker_path(product)), "маркер снят на выходе")

    def test_exit_with_unreadable_file_logs_lost_and_leaves_file(self):
        """Red now: contract — limits.flush_pending absent."""
        self.need_limits("flush_pending")
        for product in ("claude", "codex"):
            with self.subTest(product=product):
                self.reset_round()
                self.make_pending(product)
                before = self.snap_cred()
                del self.events[:]
                limits.flush_pending()
                self.assert_untouched(before, "flush_pending/%s" % product)
                self.assertIn("pending_rotation_lost", self.o1_events())
                self.assertFalse(os.path.exists(marker_path(product)))


# ---- A2-08 (Т35, T2-r2 R1) no redirects with a Bearer token, bounded bodies ----------------------------------------------
class TestA208NoRedirects(Base):
    def site(self, product, kind):
        """Prepare one call site; returns (url, run)."""
        self.reset_round()
        if kind == "usage":
            self.set_policy(None)
            self.creds(product, "live")
            run = limits.fetch_claude if product == "claude" else limits.codex_usage_live
            return USAGE[product], run
        self.set_policy("guarded")
        self.creds(product, "expiring")
        return TOKEN[product], (limits.fetch_claude if product == "claude" else limits.codex_usage_live)

    SITES = (("claude", "usage"), ("claude", "token"), ("codex", "usage"), ("codex", "token"))

    def test_provider_calls_pass_no_redirects_and_body_cap(self):
        """Red now: limits.py:243/:550 and both token POSTs call common.http with redirects on and no max_body."""
        for product, kind in self.SITES:
            with self.subTest(product=product, kind=kind):
                url, run = self.site(product, kind)
                run()
                calls = [c for c in self.trap.calls if c.url == url]
                self.assertEqual(len(calls), 1, "предусловие: вызов %s состоялся" % url)
                c = calls[0]
                self.assertIs(c.follow_redirects, False, "follow_redirects=False")
                self.assertIsInstance(c.max_body, int)
                self.assertTrue(0 < c.max_body <= CAP, "max_body ≤ 16 МиБ")

    def test_update_downloads_pass_body_cap(self):
        """Red now: update.py:215/:238 read the whole download into memory (no max_body)."""
        self.trap.default = common.Resp(500, b"", {})
        common.state().update(updateAvailable="99.0.0",
                              updateDebUrl="https://github.com/o/r/releases/download/v99/claude-codex-limits_99.0.0_all.deb")
        with self.assertRaises(RuntimeError):
            update.fetch_deb()
        with mock.patch.object(update, "is_packaged", return_value=False), \
                mock.patch.object(update, "is_checkout", return_value=False), self.assertRaises(RuntimeError):
            update.apply()
        deb = [c for c in self.trap.calls if c.url.endswith("_all.deb")]
        tar = [c for c in self.trap.calls if c.url == update.TARBALL_URL]
        self.assertEqual((len(deb), len(tar)), (1, 1))
        self.assertTrue(isinstance(deb[0].max_body, int) and 0 < deb[0].max_body <= update.MAX_DEB, "deb: max_body")
        self.assertTrue(isinstance(tar[0].max_body, int) and 0 < tar[0].max_body <= update.MAX_TARBALL, "tarball: max_body")

    def wire(self):
        probe = f1.load_common_probe()
        common.http = probe.http
        return f2.RecordingServer()

    def test_302_is_not_followed_and_authorization_stays(self):
        """Red now: stock urlopen follows the 302 (to a foreign host too) with Authorization and drains the 3xx body."""
        for product, kind in self.SITES:
            for target in ("https://evil.example/collect", "same-host"):
                with self.subTest(product=product, kind=kind, target=target):
                    url, run = self.site(product, kind)
                    server = self.wire()
                    dst = url.rsplit("/", 1)[0] + "/elsewhere" if target == "same-host" else target
                    server.redirect(url, dst, size=None)   # endless 3xx body
                    server.ok(dst, b"{}")
                    before = self.snap_cred()
                    with server.installed():
                        d = run()
                    self.assertEqual(server.opened, [url], "переход не выполнен")
                    for req_url, all_headers, _h in server.requests[1:]:
                        self.assertNotIn("authorization", f2.lower_keys(all_headers), "Authorization ушёл на %s" % req_url)
                    self.assertEqual(server.unbounded, [], "тело 3xx читается без предела")
                    self.assertLessEqual(server.bytes_by_url.get(url, 0), CAP + 1, "тело 3xx ≤ cap+1")
                    self.assertEqual(d.failure_kind, "http", "попытка = error/http")
                    self.assertEqual(d.http_status, 302)
                    self.assertFalse(d.api_fresh)
                    self.assertTrue(d.poll_failed)
                    self.assert_untouched(before, "302 %s/%s" % (product, kind))
                    st = common.state()
                    st.reload()
                    self.assertFalse(st.has(DEAD_KEY[product]), "302 — не доказательство отзыва refresh")

    def test_endless_bodies_are_capped(self):
        """Red now: usage responses are read without max_body (unbounded read of an endless 200/500 body)."""
        for product in ("claude", "codex"):
            for code in (200, 500):
                with self.subTest(product=product, status=code):
                    url, run = self.site(product, "usage")
                    server = self.wire()
                    server.status(url, code, size=None)
                    with server.installed():
                        d = run()
                    self.assertEqual(server.unbounded, [], "чтение без предела")
                    self.assertLessEqual(server.bytes_by_url.get(url, 0), CAP + 1, "тело ≤ 16 МиБ + 1")
                    self.assertFalse(d.api_fresh)
                    self.assertTrue(d.poll_failed)


# ---- A2-09 (Т9, единое правило) policy read at the start of EVERY attempt under file_lock("quota") ----------------------
class TestA209SingleRule(Base):
    def watch_settings_reads(self):
        real_open = builtins.open
        settings = os.path.abspath(common.SETTINGS_PATH)

        def spy(file, mode="r", *a, **kw):
            if isinstance(file, str) and os.path.abspath(file) == settings and "r" in mode and "+" not in mode:
                self.events.append(("open", settings, quota_locked()))
            return real_open(file, mode, *a, **kw)
        p = mock.patch("builtins.open", spy)
        p.start()
        self.addCleanup(p.stop)

    def test_policy_read_under_quota_before_request(self):
        """Red now: no quota lock in limits; settings.json is not re-read at the start of an attempt."""
        for product in ("claude", "codex"):
            for state, policy in (("live", None), ("expiring", "guarded")):
                with self.subTest(product=product, state=state):
                    self.reset_round()
                    self.set_policy(policy)
                    self.creds(product, state)
                    self.watch_settings_reads()
                    del self.events[:]
                    self.attempt(product)
                    http = [i for i, e in enumerate(self.events) if e[0] == "http"]
                    self.assertTrue(http, "предусловие: запрос состоялся")
                    reads = [i for i, e in enumerate(self.events[:http[0]]) if e[0] == "open" and e[2]]
                    self.assertTrue(reads, "политика (settings.json) прочитана под quota до первого запроса")
                    self.assertTrue(all(e[2] for e in self.events if e[0] == "http"), "каждый запрос — под quota")
                    self.assertFalse(quota_locked(), "замок отпущен после попытки")

    def test_change_between_attempts_applies_next_attempt(self):
        """Red now: guarded→never between attempts still POSTs (no policy at all)."""
        for product in ("claude", "codex"):
            for first, second in (("guarded", "never"), ("never", "guarded")):
                with self.subTest(product=product, change="%s→%s" % (first, second)):
                    self.reset_round()
                    self.set_policy(first)
                    self.creds(product, "expiring")
                    self.attempt(product)
                    self.assertEqual(len(self.trap.posts()), 1 if first == "guarded" else 0, "попытка 1 по %s" % first)
                    self.set_policy(second, reset=False)   # another process edits settings.json; no restart
                    self.creds(product, "expiring", refresh="fixture-refresh-2") if product == "claude" else \
                        self.codex_auth("expiring", refresh="fixture-codex-refresh-2")
                    self.trap.calls.clear()
                    self.attempt(product)
                    self.assertEqual(len(self.trap.posts()), 1 if second == "guarded" else 0, "попытка 2 по %s" % second)

    def test_change_inside_attempt_does_not_apply_midway(self):
        """Green guard: settings flipped to never after the POST — the attempt finishes under guarded, pair written."""
        for product in ("claude", "codex"):
            with self.subTest(product=product):
                self.reset_round()
                self.set_policy("guarded")
                self.creds(product, "expiring")

                def flip(call):
                    if call.url == TOKEN[product]:
                        self.set_policy("never", reset=False)
                self.trap.on_call = flip
                self.attempt(product)
                obj = load(self.cred_path(product))
                rt = obj["claudeAiOauth"]["refreshToken"] if product == "claude" else obj["tokens"]["refresh_token"]
                self.assertEqual(rt, rotated(product)["refresh_token"], "пара после POST не потеряна")
                self.assertNotIn("policy_violation", self.o1_events())

    def test_cli_credentials_write_switches_policy(self):
        """Red now: contract — no `ccl-sync credentials` subcommand."""
        for value in ("guarded", "never"):
            with self.subTest(value=value):
                code, text = self.run_cli(["credentials", "--write", value])
                if code == 2 and "invalid choice" in text:
                    self.fail("contract: нет подкоманды `ccl-sync credentials --write never|guarded`")
                self.assertEqual(code, 0, text[-400:])
                self.assertEqual(self.settings_on_disk().get("credential_write"), value)

    def test_cli_and_api_refuse_while_rotation_pending(self):
        """Red now: contract — set_credential_write / `credentials` subcommand absent."""
        refused = self.refused_error()
        for how in ("marker", "in-memory only"):
            with self.subTest(pending=how):
                self.reset_round()
                if how == "marker":
                    self.make_pending("claude")
                else:
                    self.set_policy("guarded")
                    limits._PENDING["claude"] = {"old": "fixture-refresh-1", "access": "fixture-access-1",
                                                 "tok": rotated("claude"), "t": NOW}
                code, text = self.run_cli(["credentials", "--write", "never"])
                self.assertNotEqual(code, 0, "отказ при непустом _PENDING")
                self.assertRegex(text, ROTATION)
                with self.assertRaises(refused):
                    common.set_credential_write("never")
                self.assertEqual(self.settings_on_disk().get("credential_write"), "guarded")

    def test_set_credential_write_writes_under_quota(self):
        """Red now: contract — set_credential_write absent."""
        self.need_common("set_credential_write")
        self.set_policy(None)
        del self.events[:]
        common.set_credential_write("guarded")
        writes = [e for e in self.events if e[0] == "write" and e[1] == os.path.abspath(common.SETTINGS_PATH)]
        self.assertTrue(writes, "settings.json записан")
        self.assertTrue(all(e[2] for e in writes), "запись политики — под file_lock('quota')")
        self.assertEqual(self.settings_on_disk().get("credential_write"), "guarded")


# ---- A2-10 (П3-г) Codex: JWT exp == now, no grace --------------------------------------------------------------------
class TestA210CodexExpNow(Base):
    def test_exp_equal_now_is_expiring(self):
        """Red now: exp ≤ now + 60 triggers POST /oauth/token; LimitData.expired_reason absent."""
        for exp in (NOW, NOW - 1):
            with self.subTest(exp=exp - NOW):
                self.reset_round()
                self.set_policy(None)
                self.codex_auth("expiring", exp=exp)
                before = self.snap_cred()
                d = limits.fetch_codex(live=True)
                self.assertEqual(self.trap.calls, [], "0 запросов")
                self.assert_untouched(before, "codex exp=now")
                self.assertEqual(d.auth, limits.EXPIRED)
                self.assertEqual(self.reason(d), "cli_refresh_pending")

    def test_exp_within_60s_is_live_and_401_is_cli_refresh_pending(self):
        """Red now: exp ≤ now + 60 triggers POST /oauth/token (today's 60 s grace). Юрка 2026-10-13: (now, now+60] in never
        = live — usage is asked, no refresh; usage 401 → expired + cli_refresh_pending."""
        for exp in (NOW + 1, NOW + 30, NOW + 60):
            for status in (200, 401):
                with self.subTest(exp=exp - NOW, usage=status):
                    self.reset_round()
                    self.set_policy(None)
                    self.codex_auth("expiring", exp=exp)
                    if status == 401:
                        self.trap.overrides[CODEX_USAGE] = common.Resp(401, b"{}", {})
                    before = self.snap_cred()
                    d = limits.fetch_codex(live=True)
                    self.assertEqual(self.trap.posts(), [], "never: refresh нет")
                    self.assertEqual([c.url for c in self.trap.usage()], [CODEX_USAGE], "токен ещё валиден → usage")
                    self.assert_untouched(before, "codex exp=now+%d" % (exp - NOW))
                    if status == 200:
                        self.assertEqual(d.auth, limits.OK)
                        self.assertTrue(d.api_fresh)
                        self.assertIsNone(self.reason(d))
                    else:
                        self.assertEqual(d.auth, limits.EXPIRED)
                        self.assertEqual(self.reason(d), "cli_refresh_pending")
                        st = common.state()
                        st.reload()
                        self.assertFalse(st.has("deadCodexRefresh"))


# ---- A2-11 (П2-в) identity travels in LimitData.account, captured with the token -------------------------------------
class TestA211AccountInLimitData(Base):
    def account(self, d):
        v = getattr(d, "account", MISSING)
        if v is MISSING:
            self.fail("contract: LimitData.account отсутствует (П2-в)")
        return v

    def test_codex_account_from_the_token_read(self):
        """Red now: contract — LimitData.account absent."""
        self.set_policy(None)
        self.codex_auth("live", account=CODEX_ACCT)
        real_open = builtins.open
        auth = os.path.abspath(common.CODEX_AUTH)
        reads = []

        def spy(file, mode="r", *a, **kw):
            if isinstance(file, str) and os.path.abspath(file) == auth and "r" in mode:
                reads.append(len(self.trap.calls))
            return real_open(file, mode, *a, **kw)

        def swap(call):  # another login lands while the request is in flight
            if call.url == CODEX_USAGE:
                self.codex_auth("live", account="acct-fixture-0002-bbbb")
        self.trap.on_call = swap
        with mock.patch("builtins.open", spy):
            d = limits.fetch_codex(live=True)
        self.assertEqual(self.account(d), CODEX_ACCT, "идентичность того же чтения, что и токен")
        self.assertEqual(self.trap.usage()[0].headers.get("chatgpt-account-id"), CODEX_ACCT)
        self.assertEqual([r for r in reads if r == 0], [0], "auth.json прочитан ровно один раз до запроса")

    def test_claude_account_captured_before_request(self):
        """Red now: contract — LimitData.account absent."""
        self.set_policy(None)
        self.claude_creds("live")
        for raw, expected in ((" " + U_A.upper() + " ", U_A), (None, None)):
            with self.subTest(account=expected):
                self.reset_round()
                if raw is None:
                    with contextlib.suppress(FileNotFoundError):
                        os.unlink(common.CLAUDE_JSON)
                else:
                    self.write_claude_json(raw)

                def swap(call):
                    if call.url == CLAUDE_USAGE:
                        self.write_claude_json(U_B)
                self.trap.on_call = swap
                d = limits.fetch_claude()
                self.assertTrue(d.api_fresh)
                self.assertEqual(self.account(d), expected, "accountUuid снят до запроса, нормализован")


if __name__ == "__main__":
    unittest.main()
