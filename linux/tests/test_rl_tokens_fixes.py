"""REMOTE-LIMITS A2 — fix cycle 1 (docs/review-remote-limits-a2.md M1, m1, m2, m4, m5, m7;
docs/security-remote-limits-a2-t2.md N1, N2, N5, N7; docs/plans.md §A2 «Ревью A2 (2026-10-13 …)»).
Test-plan IDs A2-12…A2-18 (docs/test-plan-remote-limits.md, section A2).

Written BEFORE the fix ("red first"); same harness as test_rl_tokens.py (`Base`: temp HOME/XDG, synthetic login files,
recording `common.http` trap, sockets refused, frozen clock, virtual sleeps). Tests marked «Green guard» pass on 8989735
and must stay green.

Contract fixed by the tester for this cycle (Юрка's decisions in plans.md §A2 + the choices below):
  M1/N1  guarded: the rotation marker is written BEFORE POST /oauth/token. If it cannot be written (OSError: STATE_DIR not
         writable…; OSError/ValueError: /proc/sys/kernel/random/boot_id missing or malformed) → no POST at all (the
         single-use refresh token is not spent), result failure_kind "credentials", login file untouched, no _PENDING,
         no exception out of fetch_claude / codex_access_token / codex_usage_live / fetch_codex. A POST that yields no pair
         leaves no marker behind (guard). Faults are injected at the OS boundary (directory mode, os.open/open of boot_id),
         not by patching private helpers.
  N2     one marker per process: <STATE_DIR>/rotation-pending-<product>-<pid>; a process removes only its own marker;
         set_credential_write() refuses while any marker of another live process (same boot) exists; markers of dead
         pids or another boot are removed. Other processes are real child processes that go through the real rotation
         path (no hand-written marker content).
  m1/N5  quota busy past the bounded wait → failure_kind "busy" (new value next to network/http/auth/credentials/
         invalid_response), auth == OK (not READ_ERROR: the lock is not the login), poll_failed, not api_fresh,
         expired_reason None, error text free of credential/file/sign-in wording. Same for codex_access_token(result).
  m2     opening quota.lock fails (PermissionError) → fetch_* / codex_access_token return an error (failure_kind
         "credentials" or "busy" — either is accepted), never raise; `ccl-sync credentials --write …` → exit ≠ 0,
         one human-readable line, no traceback / exception class / errno. Same when settings.json cannot be written.
  m4     corrupt marker (`{`, `{}`, symlink → ELOOP) stays fail-closed; the refusal text (exception and CLI) names the
         marker's full path and how to recover (stop the tray/publisher, delete the file) and does not send the user to
         a CLI re-login. A file name with a live pid does not make an unreadable marker "readable".
  m5/N7  Codex: `chatgpt-account-id` = tokens.account_id exactly as in auth.json (no strip/lower); LimitData.account = the
         normalized id; an id outside ^[0-9a-z-]{8,64}$ after normalization → account None, the usage request still goes,
         result is NOT LOGGED_OUT. (A2-11 in test_rl_tokens.py was changed accordingly.)
  m7     `ccl-sync credentials --write guarded` with `publisher: true` → the output names the effective policy `never` and
         that the publisher overrides guarded.
Run: python3 -m unittest linux/tests/test_rl_tokens_fixes.py -v   (from PROJECT_ROOT)
"""

if __package__:
    from . import _rl_env as rl
    from . import test_rl_tokens as t
else:
    import _rl_env as rl
    import test_rl_tokens as t

import builtins
import contextlib
import errno
import json
import os
import re
import shutil
import subprocess
import sys
import time
import unittest
from unittest import mock

from ccl import common, limits

NOW = rl.NOW
BOOT_ID = "/proc/sys/kernel/random/boot_id"
NO_TRACE = re.compile(r"Traceback|Errno|PermissionError|OSError|Exception|File \"")
CRED_WORDS = re.compile(r"(?i)credential|\.json|sign-?in|login|вход|войд")
RECOVERY = re.compile(r"(?i)удал|delete|remove|\brm\b")
RELOGIN = re.compile(r"(?i)sign-?in refresh|CLI sign-?in|sign in again|повторн\w* вход|войдите")
FORCED = re.compile(r"(?i)издател|publisher")
IGNORED = re.compile(r"(?i)игнор|ignor|принудит|forced|override")
ROOT = os.geteuid() == 0


def tearDownModule():
    rl.assert_real_files_untouched()


PENDING_CHILD = (
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
    "        tok = {'access_token': 'fixture-rotated-access', 'refresh_token': 'fixture-child-refresh', 'expires_in': 28800}\n"
    "        return common.Resp(200, json.dumps(tok).encode(), {})\n"
    "    raise AssertionError('unexpected request')\n"
    "common.http = http\n"
    "limits.fetch_claude()\n"
    "print(json.dumps({'pending': 'claude' in limits._PENDING, 'pid': os.getpid(),\n"
    "                  'cleanup': [rl.SANDBOX_HOME, rl._isolate.ROOT]}), flush=True)\n"
    "if cfg['hold']: sys.stdin.read()\n"
    "os._exit(0)\n")

QUOTA_HOLDER = (
    "import fcntl, os, sys\n"
    "fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600)\n"
    "fcntl.flock(fd, fcntl.LOCK_EX)\n"
    "print('locked', flush=True)\n"
    "sys.stdin.read()\n")


class FixBase(t.Base):
    def guard(self, fn, where):
        """Call fn(); an exception escaping a public fetch/CLI entry point is the bug under test, not a test error."""
        try:
            return fn()
        except Exception as e:  # noqa: BLE001 — any escape is a failure
            self.fail("%s: исключение вышло наружу (%s); POST /oauth/token уже сделано: %d"
                      % (where, type(e).__name__, len(self.trap.posts())))

    @contextlib.contextmanager
    def chmod(self, path, mode):
        """Temporary mode on a sandbox path, restored on exit (also when the body fails)."""
        self.assertTrue(path.startswith(self.tmp), "только пути песочницы")
        old = os.stat(path).st_mode & 0o777
        os.chmod(path, mode)
        try:
            yield
        finally:
            with contextlib.suppress(FileNotFoundError):   # a late cleanup may run after the sandbox is gone
                os.chmod(path, old)

    def pending_child(self, hold=True):
        """A real other guarded process: rotates through the real path (POST → file mid-write → _PENDING + marker) and,
        with hold=True, stays alive until its stdin is closed. Returns (popen or None, report)."""
        self.watchdog(120)
        self.set_policy("guarded")
        self.claude_creds("expiring")
        cfg = {"tests": t.TESTS_DIR, "home": self.home, "paths": self.sandbox_paths(), "hold": hold,
               "partial": t.read_bytes(common.CLAUDE_CREDENTIALS).decode()[:40]}
        env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
        proc = subprocess.Popen([sys.executable, "-I", "-c", PENDING_CHILD, json.dumps(cfg)], stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
        self.addCleanup(self._reap, proc)
        line = proc.stdout.readline()
        if not line:
            proc.wait()
            self.fail("дочерний процесс: %s" % proc.stderr.read()[-800:])
        report = json.loads(line)
        for d in report["cleanup"]:
            if d.startswith("/tmp/ccl-"):
                self.addCleanup(shutil.rmtree, d, True)
        self.assertTrue(report["pending"], "предусловие: guarded-ротация в дочернем процессе оставила _PENDING")
        if not hold:
            proc.wait()
        return proc, report

    @staticmethod
    def _reap(proc):
        # Popen.wait(timeout) polls with time.sleep, which Base makes virtual: wait without a timeout (blocking waitpid).
        with contextlib.suppress(Exception):
            proc.kill()
        proc.wait()
        for s in (proc.stdin, proc.stdout, proc.stderr):
            with contextlib.suppress(Exception):
                s.close()

    def end_child(self, proc, pid):
        """B exits on stdin EOF via os._exit — no flush_pending, its marker stays behind (a crash for the others)."""
        proc.stdin.close()
        proc.wait()
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)

    def hold_quota(self):
        holder = subprocess.Popen([sys.executable, "-I", "-c", QUOTA_HOLDER, t.quota_lock_path()],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        self.addCleanup(self._reap_holder, holder)
        self.assertEqual(holder.stdout.readline().strip(), "locked")
        self.assertTrue(t.quota_locked())
        return holder

    @staticmethod
    def _reap_holder(holder):
        holder.kill()
        holder.wait()
        for s in (holder.stdin, holder.stdout):
            with contextlib.suppress(Exception):
                s.close()

    def calls(self, product):
        """Public entry points of one live attempt. Each returns LimitData (codex_access_token: its result object)."""
        if product == "claude":
            return (("fetch_claude", limits.fetch_claude),)

        def token():
            res = limits.LimitData()
            got = limits.codex_access_token(res)
            self.assertIsNone(got, "codex_access_token: токена нет")
            return res
        return (("codex_access_token", token), ("codex_usage_live", limits.codex_usage_live),
                ("fetch_codex", lambda: limits.fetch_codex(live=True)))


# ---- A2-12 (M1/N1) guarded: marker before POST; marker failure → no POST, error/credentials -----------------------------
class TestA212MarkerBeforePost(FixBase):
    FAULTS = ("state_dir_0500", "boot_id_missing", "boot_id_malformed")

    @contextlib.contextmanager
    def fault(self, kind):
        if kind == "state_dir_0500":
            if ROOT:
                self.skipTest("root обходит права каталога")
            open(t.quota_lock_path(), "a").close()                     # the lock file exists (as on a live machine)
            common.state().set("claudeTier", "default_claude_max_20x")  # nothing else needs STATE_DIR writes pre-POST
            with self.chmod(common.STATE_DIR, 0o500):
                yield
            return
        garbage = os.path.join(self.tmp, "boot_id.garbage")
        with open(garbage, "w", encoding="ascii") as f:
            f.write("not-a-boot-id\n")
        real_os_open, real_open = os.open, builtins.open

        def target(path):
            if isinstance(path, (str, bytes, os.PathLike)) and os.fsdecode(path) == BOOT_ID:
                if kind == "boot_id_missing":
                    raise FileNotFoundError(errno.ENOENT, "No such file or directory", BOOT_ID)
                return garbage
            return path

        def os_open(path, flags, mode=0o777, *a, **kw):
            return real_os_open(target(path), flags, mode, *a, **kw)

        def b_open(file, *a, **kw):
            return real_open(target(file), *a, **kw)
        with mock.patch("os.open", os_open), mock.patch("builtins.open", b_open):
            yield

    def test_marker_failure_spends_no_refresh_token(self):
        """Red now: POST /oauth/token goes first, then write_rotation_marker raises out of fetch_* (PermissionError /
        FileNotFoundError / ValueError); the rotated pair is lost and the CLI file keeps the spent refresh token."""
        for product in ("claude", "codex"):
            for kind in self.FAULTS:
                for name, run in self.calls(product):
                    with self.subTest(product=product, fault=kind, call=name):
                        self.reset_round()
                        self.set_policy("guarded")
                        self.creds(product, "expiring")
                        before = self.snap_cred()
                        with self.fault(kind):
                            for attempt in (1, 2):   # a persistent fault must not spend a token on the retry either
                                d = self.guard(run, "%s/%s попытка %d" % (name, kind, attempt))
                                self.assertEqual(self.trap.posts(), [],
                                                 "маркер не записан → POST /oauth/token не делается (refresh не потрачен)")
                                self.assertEqual(self.trap.usage(), [], "истёкший access: usage тоже нет")
                                self.assertEqual(d.failure_kind, "credentials", "результат error/credentials")
                                self.assertTrue(d.poll_failed)
                                self.assertFalse(d.api_fresh)
                        self.assert_untouched(before, "%s/%s" % (name, kind))
                        self.assertEqual(limits._PENDING, {}, "без POST пары в памяти нет")
                        self.assertEqual(t.markers(product), [], "маркер не остался")
                        st = common.state()
                        st.reload()
                        self.assertFalse(st.has(t.DEAD_KEY[product]), "сбой маркера — не отзыв refresh")

    def test_marker_absent_after_post_without_pair(self):
        """Green guard: a token POST that yields no pair (400 / network) leaves neither a marker nor _PENDING behind;
        a successful save leaves no marker either."""
        for product in ("claude", "codex"):
            for status in (400, 0, 200):
                with self.subTest(product=product, token_status=status):
                    self.reset_round()
                    self.set_policy("guarded")
                    self.creds(product, "expiring")
                    if status != 200:
                        body = json.dumps({"error": "invalid_request"}).encode() if status else b""
                        self.trap.overrides[t.TOKEN[product]] = common.Resp(status, body, {})
                    self.attempt(product)
                    self.assertEqual(len(self.trap.posts()), 1, "предусловие: POST состоялся")
                    self.assertEqual(t.markers(product), [], "маркер снят")
                    self.assertEqual(limits._PENDING, {})


# ---- A2-13 (N2) one marker per process; only one's own marker is removed ---------------------------------------------
class TestA213MarkerPerProcess(FixBase):
    def test_marker_is_named_after_the_process(self):
        """Red now: the marker is the shared `rotation-pending-claude` (any process overwrites/removes it)."""
        self.make_pending("claude")
        own = os.path.join(common.STATE_DIR, "rotation-pending-claude-%d" % os.getpid())
        self.assertEqual(t.markers("claude"), [own], "contract N2: маркер rotation-pending-<p>-<pid> своего процесса")

    def test_own_cleanup_keeps_foreign_live_marker(self):
        """Red now: process A finishing its own rotation (CLI re-logged meanwhile) deletes the only marker — B's — and
        set_credential_write('never') passes while B still holds a rotated pair in memory."""
        refused = self.refused_error()
        proc, child = self.pending_child(hold=True)                 # B: alive, pending, marker
        self.assertTrue(t.markers("claude"), "предусловие: у B есть маркер")
        self.make_pending("claude")                                 # A: own pending + own marker
        self.claude_creds("live", access="fixture-access-relogin", refresh="fixture-refresh-relogin")
        d = limits.fetch_claude()                                   # A sees the CLI's own new pair → drops its pending
        self.assertNotIn("claude", limits._PENDING, "предусловие: A снял свою незавершённую ротацию")
        self.assertTrue(d.api_fresh, "предусловие: A прочитал лимиты новой парой")
        left = t.markers("claude")
        self.assertTrue(left, "A снял чужой маркер (B ещё держит ротированную пару)")
        self.assertNotIn(os.path.join(common.STATE_DIR, "rotation-pending-claude-%d" % os.getpid()), left,
                         "свой маркер A снят")
        with self.assertRaises(refused) as cm:
            common.set_credential_write("never")
        self.assertRegex(str(cm.exception), t.ROTATION)
        self.assertEqual(self.settings_on_disk().get("credential_write"), "guarded", "смена отклонена, пока жив B")
        code, text = self.run_cli(["credentials", "--write", "never"])
        self.assertNotEqual(code, 0, "CLI: отказ, пока жив B")
        self.end_child(proc, child["pid"])                          # B exits without flushing: its marker is dead now
        common.set_credential_write("never")
        self.assertEqual(t.markers("claude"), [], "маркер мёртвого B удалён")
        self.assertEqual(self.settings_on_disk().get("credential_write"), "never")

    def test_foreign_marker_from_previous_boot_is_removed(self):
        """Green guard: another process's marker with a boot-id of a previous boot is dead even though the pid lives."""
        self.need_common("set_credential_write")
        proc, child = self.pending_child(hold=True)
        found = t.markers("claude")
        self.assertEqual(len(found), 1, "предусловие: один маркер B")
        with open(BOOT_ID, encoding="ascii") as f:
            boot = f.read().strip()
        content = t.read_bytes(found[0]).decode("utf-8")
        forms = [b for b in (boot, boot.replace("-", "")) if b in content]
        self.assertTrue(forms, "contract: маркер содержит boot-id")
        old = "00000000-0000-4000-8000-000000000000"
        for b in forms:
            content = content.replace(b, old if "-" in b else old.replace("-", ""))
        self.write_file(found[0], content)
        os.kill(child["pid"], 0)                                     # B is alive
        common.set_credential_write("never")
        self.assertEqual(t.markers("claude"), [], "маркер прошлой загрузки удалён")
        self.assertEqual(self.settings_on_disk().get("credential_write"), "never")


# ---- A2-14 (m1/N5) busy quota → class "busy", not a login failure ---------------------------------------------------
class TestA214QuotaBusy(FixBase):
    def test_busy_quota_is_not_a_credentials_failure(self):
        """Red now: _quota_busy → auth READ_ERROR + failure_kind "credentials" (the tray says «check .credentials.json»)."""
        for product in ("claude", "codex"):
            self.set_policy(None)
            self.creds(product, "live")
        self.hold_quota()
        self.watchdog(60)
        self.forbid_unbounded_quota_wait = True
        before = self.snap_cred()
        with mock.patch.object(time, "monotonic", self.clock):
            for product in ("claude", "codex"):
                for name, run in self.calls(product):
                    with self.subTest(call=name):
                        start = self.clock.now
                        d = self.guard(run, name)
                        waited = self.clock.now - start
                        self.assertGreater(waited, 0, "ожидание замка было")
                        self.assertLessEqual(waited, 61, "ожидание quota ≤ 60 с (виртуальное время)")
                        self.assertEqual(d.failure_kind, "busy", "занятый quota — отдельный класс busy")
                        self.assertEqual(d.auth, limits.OK, "замок — не вход: auth не readError")
                        self.assertIsNone(d.expired_reason)
                        self.assertTrue(d.poll_failed)
                        self.assertFalse(d.api_fresh)
                        self.assertNotRegex(d.error or "", CRED_WORDS, "текст без упоминания входа/файла входа")
        self.assertEqual(self.trap.calls, [], "под чужим замком запросов нет")
        self.assert_untouched(before, "quota busy")


# ---- A2-15 (m2) quota.lock cannot be opened → error result / clean CLI refusal ----------------------------------------
class TestA215QuotaLockUnopenable(FixBase):
    def setUp(self):
        super().setUp()
        if ROOT:
            self.skipTest("root обходит права файла")

    def lock_unopenable(self):
        path = t.quota_lock_path()
        with open(path, "a"):
            pass
        cm = self.chmod(path, 0o000)
        cm.__enter__()
        self.addCleanup(cm.__exit__, None, None, None)   # runs before SyncEnv removes the sandbox
        with self.assertRaises(PermissionError):
            os.open(path, os.O_RDWR)

    def test_fetch_returns_error_instead_of_raising(self):
        """Red now: PermissionError from os.open(quota.lock) escapes every public fetch_* / codex_access_token."""
        for product in ("claude", "codex"):
            self.set_policy(None)
            self.creds(product, "live")
        self.lock_unopenable()
        before = self.snap_cred()
        for product in ("claude", "codex"):
            for name, run in self.calls(product):
                with self.subTest(call=name):
                    d = self.guard(run, name)
                    self.assertIn(d.failure_kind, ("credentials", "busy"), "результат-ошибка")
                    self.assertTrue(d.poll_failed)
                    self.assertFalse(d.api_fresh)
                    self.assertNotRegex(d.error or "", NO_TRACE, "текст исключения не выводится")
        self.assertEqual(self.trap.calls, [], "без замка запросов нет")
        self.assert_untouched(before, "quota.lock 000")

    def test_cli_credentials_write_fails_cleanly(self):
        """Red now: `ccl-sync credentials --write …` dies with a traceback (PermissionError from quota.lock / from the
        settings.json write)."""
        lock, config = t.quota_lock_path(), os.path.dirname(common.SETTINGS_PATH)
        with open(lock, "a"):
            pass
        for fault in ("quota_lock", "settings_write"):
            for value in ("guarded", "never"):
                with self.subTest(fault=fault, value=value):
                    self.set_policy("never" if value == "guarded" else "guarded")
                    with (self.chmod(lock, 0o000) if fault == "quota_lock" else self.chmod(config, 0o500)):
                        code, text = self.guard(lambda: self.run_cli(["credentials", "--write", value]),
                                                "ccl-sync credentials")
                    self.assertNotEqual(code, 0, "сбой → ненулевой код")
                    self.assertTrue(text.strip(), "человеко-читаемая строка")
                    self.assertNotRegex(text, NO_TRACE, "без traceback и текста исключения")
                    self.assertNotEqual(self.settings_on_disk().get("credential_write"), value, "настройка не сменилась")


# ---- A2-16 (m4) corrupt marker: fail-closed, message names the file and the way out ---------------------------------
class TestA216CorruptMarkerMessage(FixBase):
    def test_corrupt_marker_refusal_names_file_and_recovery(self):
        """Red now: the refusal says «retry after CLI sign-in refresh» and names no file (a re-login never clears it)."""
        refused = self.refused_error()
        proc, child = self.pending_child(hold=True)    # a live owner: an unreadable marker must not be guessed dead
        found = t.markers("claude")
        self.assertEqual(len(found), 1, "предусловие: один маркер")
        path = found[0]
        for kind in ("{", "{}", "symlink"):
            with self.subTest(marker=kind):
                with contextlib.suppress(FileNotFoundError):
                    os.unlink(path)
                if kind == "symlink":
                    os.symlink(os.path.join(self.tmp, "marker-target"), path)
                else:
                    self.write_file(path, kind)
                with self.assertRaises(refused) as cm:
                    common.set_credential_write("never")
                msg = str(cm.exception)
                self.assertIn(path, msg, "в тексте — путь к файлу маркера")
                self.assertRegex(msg, RECOVERY, "в тексте — как восстановиться (удалить файл)")
                self.assertNotRegex(msg, RELOGIN, "повторный вход CLI маркер не снимает — не советовать")
                code, text = self.run_cli(["credentials", "--write", "never"])
                self.assertNotEqual(code, 0)
                self.assertIn(path, text, "CLI: путь к файлу маркера")
                self.assertRegex(text, RECOVERY)
                self.assertNotRegex(text, RELOGIN)
                self.assertNotRegex(text, NO_TRACE)
                self.assertTrue(os.path.lexists(path), "fail-closed: повреждённый маркер не удаляется сам")
                self.assertEqual(self.settings_on_disk().get("credential_write"), "guarded")
        self.end_child(proc, child["pid"])


# ---- A2-17 (m5/N7) raw account_id in the header; out-of-form id → account None, not signed out -------------------------
class TestA217CodexAccountHeader(FixBase):
    VALID = (("ACCT-Fixture-0001-AAAA", "acct-fixture-0001-aaaa"),
             ("  acct-fixture-0001-aaaa ", "acct-fixture-0001-aaaa"),
             ("3B9D6C1E-8F42-4A7B-9C05-2E6F1D8A4B70", "3b9d6c1e-8f42-4a7b-9c05-2e6f1d8a4b70"))
    INVALID = ("acct-07", "a" * 65, "acct_fixture_0001", "acct.fixture.0001", "acct+fixture/0001=")

    def run_live(self, raw, policy):
        self.reset_round()
        self.set_policy(policy)
        self.codex_auth("live", account=raw)
        before = self.snap_cred()
        d = limits.fetch_codex(live=True)
        self.assert_untouched(before, "codex live")
        self.assertEqual(self.trap.posts(), [])
        usage = self.trap.usage()
        return d, usage

    def account(self, d):
        v = getattr(d, "account", t.MISSING)
        if v is t.MISSING:
            self.fail("contract: LimitData.account отсутствует (П2-в)")
        return v

    def test_header_carries_raw_id_account_is_normalized(self):
        """Red now: the header carries the normalized id (strip/lower)."""
        for policy in (None, "guarded"):
            for raw, norm in self.VALID:
                with self.subTest(policy=policy or "never", raw=raw):
                    d, usage = self.run_live(raw, policy)
                    self.assertEqual(len(usage), 1, "usage-запрос состоялся")
                    self.assertEqual(usage[0].headers.get("chatgpt-account-id"), raw, "заголовок = значение из файла")
                    self.assertEqual(self.account(d), norm, "LimitData.account — нормализованный id")
                    self.assertEqual(d.auth, limits.OK)
                    self.assertTrue(d.api_fresh)

    def test_out_of_form_id_is_unlabelled_not_signed_out(self):
        """Red now: an id outside [0-9a-z-]{8,64} → LOGGED_OUT «CLI sign-in required», no request (and in never: no values)."""
        for policy in (None, "guarded"):
            for raw in self.INVALID:
                with self.subTest(policy=policy or "never", raw=raw):
                    d, usage = self.run_live(raw, policy)
                    self.assertNotEqual(d.auth, limits.LOGGED_OUT, "человек вошёл: формат метки — не условие входа")
                    self.assertEqual(len(usage), 1, "usage-запрос идёт")
                    self.assertEqual(usage[0].headers.get("chatgpt-account-id"), raw, "заголовок = значение из файла")
                    self.assertIsNone(self.account(d), "id вне формы → account=None (без метки)")
                    self.assertEqual(d.auth, limits.OK)
                    self.assertTrue(d.api_fresh)
                    self.assertFalse(d._signed_out_no_values)


# ---- A2-18 (m7) publisher: credentials --write guarded reports the effective never -------------------------------------
class TestA218PublisherWriteGuardedOutput(FixBase):
    def test_output_names_effective_never(self):
        """Red now: prints «Настройка записи токенов сохранена: guarded» although never is in force."""
        self.set_policy(None, publisher=True)
        code, text = self.guard(lambda: self.run_cli(["credentials", "--write", "guarded"]), "ccl-sync credentials")
        self.assertEqual(code, 0, text[-400:])
        self.assertNotRegex(text, NO_TRACE)
        self.assertRegex(text, r"\bnever\b", "вывод называет действующую политику never")
        self.assertRegex(text, FORCED, "и причину — издатель")
        self.assertRegex(text, IGNORED, "guarded проигнорирован/переопределён издателем")
        self.assertEqual(common.credential_write(), "never", "действует never")

    def test_without_publisher_no_forced_note(self):
        """Green guard: on a non-publisher machine guarded is reported as is, no publisher note."""
        self.set_policy(None, publisher=None)
        code, text = self.run_cli(["credentials", "--write", "guarded"])
        self.assertEqual(code, 0, text[-400:])
        self.assertRegex(text, r"\bguarded\b")
        self.assertNotRegex(text, FORCED)
        self.assertEqual(common.credential_write(), "guarded")


if __name__ == "__main__":
    unittest.main()
