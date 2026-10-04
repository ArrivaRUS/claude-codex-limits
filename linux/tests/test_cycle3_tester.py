"""Cycle 3 coverage added by the tester (2026-09-30): invariants K1, late keyring operations,
hung keyring, sign-out timing, N8, K5, K4, the sign-out hint and token substrings.

Offline only (lesson 006): the fake Secret Service and scripted GitHub from `_sync_env`,
all paths inside the per-test sandbox; `vault.TIMEOUT` = 0.3 s.
"""

if __package__:
    from . import _isolate  # noqa: F401
    from . import _sync_env as env
    from .test_cycle3_cli_gui import gui_methods
else:
    import _isolate  # noqa: F401
    import _sync_env as env
    from test_cycle3_cli_gui import gui_methods

import argparse
import contextlib
import io
import json
import os
import secrets
import threading
import time
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch

from ccl import cli, common, sync, usage, vault

DEEP = "[" * 100000 + "]" * 100000          # exactly the K5 fixture from the security review


def tearDownModule():
    env.assert_real_files_untouched()


def vault_threads_idle():
    return not any(t.name == "ccl-vault" and t.is_alive() for t in threading.enumerate())


def wait_until(predicate, timeout=3.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.01)
    return predicate()


class Base(env.SyncEnv):
    def setUp(self):
        super().setUp()
        self._timer = patch.object(cli, "_timer_status", return_value="test timer")
        self._timer.start()

    def tearDown(self):
        self._timer.stop()
        super().tearDown()

    def token_files(self):
        """Every token file in the config dir: the main one and staged `.pending-<hex>` copies,
        plus any temp file write_atomic may leave behind."""
        if not os.path.isdir(common.CONFIG_DIR):
            return []
        base = os.path.basename(common.TOKEN_FILE_PATH)
        names = [n for n in os.listdir(common.CONFIG_DIR) if base in n]
        directory = os.path.join(common.CONFIG_DIR, "github-credentials")
        if os.path.isdir(directory):
            names.extend("github-credentials/" + n for n in os.listdir(directory))
        return sorted(names)

    def copies(self):
        return len(self.ss.items) + (len(self.v2ss.items) if self.v2ss else 0) + len(self.token_files())

    def assert_signed_out_clean(self):
        self.assertEqual(self.ss.items, {}, "no Secret Service item with ATTRS may remain")
        if self.v2ss is not None:
            self.assertEqual(self.v2ss.items, {}, "no V2 credential envelope may remain")
        self.assertEqual(self.token_files(), [], "no credential file, staged or main")
        self.assertFalse(sync.delete_pending())
        self.assertFalse(sync.sign_out_incomplete())

    def script_device_login(self, token, login="me", refresh=None):
        self.gh.on("POST", "https://github.com/login/device/code", env.resp(200, {
            "device_code": "dc", "user_code": "UC-T", "interval": 0.01, "expires_in": 60,
            "verification_uri": "https://github.com/login/device"}))
        issuance = dict(access_token=token)
        if refresh is not None:
            issuance["refresh_token"] = refresh
        self.gh.on("POST", "https://github.com/login/oauth/access_token", env.resp(200, issuance))
        self.gh.on("GET", "/user", env.resp(200, {"id": 7, "login": login}))

    def run_cli(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = cli.main(list(argv))
        return rc, out.getvalue() + err.getvalue()

    def cli_login(self, token, refresh=None):
        self.enable_v2_login()
        self.script_device_login(token, refresh=refresh)
        with patch.object(cli, "cmd_push", return_value=0):
            return self.run_cli("login", "--force", "--no-browser")


# ---- 1. K1: one stored copy, nothing after sign-out ------------------------------------------
class TestK1Invariant(Base):
    def setUp(self):
        super().setUp()
        self.enable_v2_login()

    def test_cli_login_force_twice_leaves_one_copy_and_logout_clears_all(self):
        # SS → SS, SS → file (keyring write fails), file → SS: after each login exactly one copy.
        plans = {"ss-ss": (True, True), "ss-file": (True, False), "file-ss": (False, True)}
        for name, backends in plans.items():
            with self.subTest(plan=name):
                self.st().update(tokenGeneration="")      # after the first subtest, no legacy retirement
                for use_ss in backends:
                    token = env.make_token()
                    refresh = env.make_token()
                    failing = (contextlib.nullcontext() if use_ss else
                               patch.object(self.v2ss, "_unlocked", return_value=[]))
                    with failing:
                        rc, out = self.cli_login(token, refresh)
                    self.assertEqual(rc, 0, out)
                    self.assertEqual(self.copies(), 1, name)
                    credential, ref = self.credential()
                    self.assertEqual(ref["backend"], "secret-service" if use_ss else "file")
                    self.assertEqual(credential["accessToken"], token)
                    self.assertEqual(credential["refreshToken"], refresh)
                    self.assertNotIn(token, out)
                    self.assertNotIn(refresh, out)
                    self.assertFalse(sync.delete_pending(), self.st().get("tokenDeletePending"))
                rc, out = self.run_cli("logout")
                self.assertEqual(rc, 0, out)
                self.assert_signed_out_clean()

    def test_file_to_secret_service_transition_deletes_the_file(self):
        self.st().update(tokenGeneration="")
        with patch.object(self.v2ss, "_unlocked", return_value=[]):
            rc, out = self.cli_login(env.make_token())
        self.assertEqual(rc, 0, out)
        old_files = self.token_files()
        self.assertEqual(len(old_files), 1)
        self.assertTrue(old_files[0].startswith("github-credentials/"))
        rc, out = self.cli_login(env.make_token())
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.token_files(), [])
        self.assertEqual(len(self.v2ss.items), 1)

    def test_cancelled_file_login_leaves_no_staged_file(self):
        self.st().update(tokenGeneration="")
        attempt = sync.begin_login()
        original_stage = self.auth_owner.store.stage_refresh

        def stage_then_cancel(ref, payload):
            result = original_stage(ref, payload)
            self.assertEqual(result, "ready")
            self.assertEqual(len(self.token_files()), 1, "whole envelope persisted before publish")
            sync.cancel_login(attempt)
            return result
        with patch.object(vault, "_ss_v2", return_value=None), \
                patch.object(self.auth_owner.store, "stage_refresh", side_effect=stage_then_cancel):
            with self.assertRaisesRegex(sync.LoginError, "^cancelled$"):
                sync.login_finish(dict(access_token=self.token), attempt=attempt)
        self.assertEqual(self.token_files(), [])
        self.assertFalse(sync.delete_pending())
        self.assertIsNone(self.st().get("authV2")["active"])
        self.assertEqual(self.gh.calls, [])

    def test_machine_without_secret_service_signs_out_completely(self):
        vault._ss = lambda: None
        with patch.object(vault, "_ss_v2", return_value=None):
            rc, out = self.cli_login(self.token)
            self.assertEqual(rc, 0, out)
            credential, ref = self.credential()
            self.assertEqual((credential["accessToken"], ref["backend"]), (self.token, "file"))
            rc, out = self.run_cli("logout")
        self.assertEqual(rc, 0, out)
        self.assert_signed_out_clean()

    def test_ctrl_c_during_hung_keyring_write_leaves_no_orphan(self):
        self.st().update(tokenGeneration="")
        entered = threading.Event()
        release = self.v2ss.hang_set = self.v2ss.event()
        original_set = self.v2ss.set
        armed = [True]

        def set_token(*args):
            entered.set()
            return original_set(*args)

        class InterruptingEvent(threading.Event):
            def wait(self, timeout=None):
                if (armed[0] and timeout is not None and threading.current_thread() is threading.main_thread()):
                    if not entered.wait(2):
                        raise AssertionError("V2 write was not transferred")
                    armed[0] = False
                    raise KeyboardInterrupt
                return super().wait(timeout)
        proxy = SimpleNamespace(Event=InterruptingEvent, Lock=threading.Lock, Thread=threading.Thread,
                                local=threading.local)
        with patch.object(self.auth_owner.store, "login_backend", return_value="secret-service"), \
                patch.object(self.v2ss, "set", side_effect=set_token), \
                patch.object(vault, "threading", proxy):
            rc, out = self.cli_login(self.token)
        self.assertEqual(rc, 130, out)
        self.assertIsNone(self.st().get("authV2")["active"])
        self.assertTrue(sync.delete_pending(), "late writer remains durably tracked")
        release.set()
        self.assertTrue(wait_until(vault_threads_idle))
        self.v2ss.hang_set = None
        rc, out = self.run_cli("logout")
        self.assertEqual(rc, 0, out)
        self.assert_signed_out_clean()


# ---- 2. late CreateItem / late Delete ----------------------------------------------------------
class TestLateOperations(Base):
    def test_late_delete_never_touches_a_newer_login(self):
        old = self.sign_in()
        self.ss.hang_delete = self.ss.event()
        self.assertFalse(sync.logout(), "the hung delete times out")
        self.assertEqual(self.st().get("tokenDeletePending"), [list(old)])
        self.assertEqual(self.st().get("tokenGeneration"), "", "invalidated before the delete")
        self.assertEqual(vault.read(), (None, None), "no token may be used after sign-out")
        # a new sign-in while the old DeleteItem is still in flight
        self.ss.hang_delete = None
        new_token = env.make_token()
        self.gh.on("GET", "/user", env.resp(200, {"login": "me"}))
        sync.login_finish(new_token)
        new = vault.active(self.st())
        self.assertNotEqual(new[0], old[0])
        # the keyring finally answers the old DeleteItem
        self.ss.release_all()
        self.assertTrue(wait_until(vault_threads_idle))
        self.assertEqual(self.ss.items, {new[0]: new_token})
        self.assertEqual(vault.read(), (new_token, "secret-service"))
        self.assertFalse(sync.delete_pending(), "publication retried the pending reference")

    def test_late_create_after_timeout_removes_itself_even_after_a_new_login(self):
        self.ss.hang_set = self.ss.event()
        self.gh.on("GET", "/user", env.resp(200, {"login": "me"}))
        sync.login_finish(self.token)                    # SS times out → file backend
        self.assertEqual(vault.active(self.st())[1], "file")
        self.ss.hang_set = None
        new_token = env.make_token()
        self.gh.on("GET", "/user", env.resp(200, {"login": "me"}))
        sync.login_finish(new_token)
        new = vault.active(self.st())
        self.assertEqual(new[1], "secret-service")
        self.ss.release_all()
        self.assertTrue(wait_until(vault_threads_idle))
        self.assertEqual(self.ss.items, {new[0]: new_token})
        self.assertEqual(self.token_files(), [])


# ---- 3. double sign-in with a hung KWallet -------------------------------------------------------
class TestHungKeyringDoubleLogin(Base):
    def _double_login(self, hang_delete):
        ev = self.ss.event()
        self.ss.hang_set = ev
        if hang_delete:
            self.ss.hang_delete = ev
        tokens = [env.make_token(), env.make_token()]
        for token in tokens:
            self.gh.on("GET", "/user", env.resp(200, {"login": "me"}))
            self.assertEqual(sync.login_finish(token), "me")
            self.assertEqual(vault.read(), (token, "file"))
            self.assertEqual(self.token_files(), ["github-token"], "one live copy while the keyring hangs")
        return ev, tokens

    def test_writes_hang_one_copy_and_late_items_clean_themselves(self):
        ev, tokens = self._double_login(hang_delete=False)
        self.assertFalse(sync.delete_pending(), self.st().get("tokenDeletePending"))
        ev.set()
        self.assertTrue(wait_until(vault_threads_idle))
        self.assertEqual(self.ss.items, {}, "both late CreateItems removed themselves")
        self.assertEqual(vault.read(), (tokens[1], "file"))
        self.assertTrue(sync.logout())
        self.assert_signed_out_clean()

    def test_writes_and_deletes_hang_pending_is_cleaned_by_next_sign_out(self):
        ev, tokens = self._double_login(hang_delete=True)
        pending = self.st().get("tokenDeletePending")
        self.assertTrue(pending)
        self.assertTrue(all(ref[1] in ("secret-service", None) for ref in pending), pending)
        self.assertFalse(sync.sign_out_incomplete(), "a live login with pending cleanup is not «incomplete»")
        self.ss.hang_set = self.ss.hang_delete = None
        ev.set()
        self.assertTrue(wait_until(vault_threads_idle))
        self.assertEqual(self.ss.items, {}, "late CreateItems removed themselves")
        self.assertEqual(vault.read(), (tokens[1], "file"))
        self.assertTrue(sync.logout())
        self.assert_signed_out_clean()

    def test_writes_and_deletes_hang_pending_is_cleaned_by_next_publication(self):
        ev, _ = self._double_login(hang_delete=True)
        self.assertTrue(sync.delete_pending())
        self.ss.hang_set = self.ss.hang_delete = None
        ev.set()
        self.assertTrue(wait_until(vault_threads_idle))
        third = env.make_token()
        self.gh.on("GET", "/user", env.resp(200, {"login": "me"}))
        sync.login_finish(third)
        self.assertFalse(sync.delete_pending())
        self.assertEqual(self.copies(), 1)
        self.assertEqual(vault.read(), (third, "secret-service"))


# ---- 4. sign-out with a hung keyring and several pending references ------------------------------
class TestHungSignOutTiming(Base):
    def setup_pending(self, n=3):
        self.sign_in()
        extra = [[secrets.token_hex(8), "secret-service"] for _ in range(n)]
        self.st().update(tokenDeletePending=extra)
        self.ss.hang_delete = self.ss.event()
        return n + 1

    def test_time_under_lock_is_bounded_by_n_times_timeout(self):
        refs = self.setup_pending()
        start = time.monotonic()
        self.assertFalse(sync.logout())
        elapsed = time.monotonic() - start
        self.assertLessEqual(elapsed, refs * vault.TIMEOUT + 0.5, "time under the sync lock")
        self.assertEqual(len(self.st().get("tokenDeletePending")), refs)
        self.assertTrue(sync.sign_out_incomplete())
        with common.file_lock("sync", blocking=False) as held:
            self.assertTrue(held, "the lock is released after the bounded sign-out")
        self.ss.hang_delete = None
        self.ss.release_all()
        self.assertTrue(sync.logout())
        self.assert_signed_out_clean()

    def test_tray_logout_returns_at_once_and_reports_incomplete(self):
        refs = self.setup_pending()
        methods = gui_methods("TrayApp", ("logout", "on_logout_done"))
        done = threading.Event()
        a = SimpleNamespace(logout_busy=False, logout_error=None, login_attempt=None, login_state=None,
                            bridge=SimpleNamespace(logout_done=Mock()), win=Mock(), load_local=Mock())
        a.bridge.logout_done.emit.side_effect = lambda *args: done.set()
        start = time.monotonic()
        methods.logout(a)
        self.assertLess(time.monotonic() - start, 0.2, "the GUI thread is not blocked")
        self.assertTrue(a.logout_busy)
        self.assertTrue(done.wait(refs * vault.TIMEOUT + 2))
        ok, error = a.bridge.logout_done.emit.call_args.args
        self.assertFalse(ok)
        self.assertEqual(error, sync._delete_pending_text())
        methods.on_logout_done(a, ok, error)
        self.assertFalse(a.logout_busy)
        self.assertEqual(a.logout_error, sync._delete_pending_text())


# ---- 5. sign_out_incomplete truth table ------------------------------------------------------------
class TestSignOutIncomplete(Base):
    def test_truth_table(self):
        ref = [["g1", "secret-service"]]
        cases = [
            (dict(login="me", revoked=False, tokenDeletePending=ref), False),
            (dict(login="me", revoked=True, tokenDeletePending=ref), True),
            (dict(login=None, revoked=None, tokenDeletePending=ref), True),
            (dict(login=None, revoked=True, tokenDeletePending=ref), True),
            (dict(login="me", revoked=True, tokenDeletePending=None), False),
            (dict(login=None, revoked=None, tokenDeletePending=None), False),
            (dict(login=None, revoked=None, tokenDeletePending=[]), False),
        ]
        for fields, expected in cases:
            with self.subTest(**fields):
                self.st().update(**fields)
                self.assertIs(sync.sign_out_incomplete(), expected)
                self.assertIs(sync.sign_out_incomplete(self.st()), expected)
                self.assertIs(sync.delete_pending(), bool(fields["tokenDeletePending"]))


# ---- 8. N8: unreachable is not «token not found» ----------------------------------------------------
class TestUnreachablePush(Base):
    def test_push_unreachable_is_nonzero_and_not_signed_out(self):
        self.sign_in()
        with patch.object(vault, "read", return_value=(None, "unreachable")), \
                patch.object(usage, "refresh", return_value=(usage.new_index(), False, True)):
            rc, out = self.run_cli("push")
        self.assertEqual(rc, 3, "exit code 3 = Secret Service unreachable (pre-cycle-3 contract)")
        self.assertIn("недоступно", out)
        self.assertNotIn("не найден", out)
        self.assertNotIn("выключена", out)
        self.assertEqual(self.st().get("login"), "me")
        self.assertIn("недоступно", self.st().get("lastError"))
        self.assertEqual(self.gh.calls, [])

    def test_push_timeout_exit_1_with_timeout_text(self):
        self.sign_in()
        with patch.object(vault, "read", return_value=(None, "timeout")), \
                patch.object(usage, "refresh", return_value=(usage.new_index(), False, True)):
            rc, out = self.run_cli("push", "--quiet")
        self.assertEqual(rc, 1)
        self.assertIn("Хранилище секретов не ответило — повторим автоматически", out)
        self.assertNotIn("не найден", out)


# ---- 9. K5: pathological depth ----------------------------------------------------------------------
class TestDeepJSON(Base):
    def test_exact_fixture_at_every_entry_point(self):
        self.assertNotIsInstance(common.Resp(200, DEEP.encode()).json(), dict)
        path = os.path.join(self.tmp, "deep.json")
        common.write_atomic(path, DEEP)
        default = {"default": True}
        parsed = common.read_json(path, default)
        self.assertTrue(parsed is default or not isinstance(parsed, dict))
        result = sync.merge({"machine-deep.json": DEEP, "machine-good.json": env.machine_json("good")}, "me")
        self.assertEqual([m["id"] for m in result["machines"]], ["good"])

    def test_deep_local_caches_do_not_crash(self):
        common.write_atomic(common.SYNC_REMOTE_PATH, DEEP)
        self.assertEqual(sync.load_remote(), {"machines": [], "days": {}})
        common.write_atomic(common.SYNC_STATE_PATH, DEEP)
        self.assertIsNone(sync.sync_state().get("login"))

    def test_full_cycle_with_deep_foreign_file_and_truncated_raw(self):
        self.sign_in()
        self.mark_pushed()
        raw_url = "https://gist.githubusercontent.com/u/g1/raw/abc/machine-raw.json"
        others = {"machine-deep.json": DEEP, "machine-good.json": env.machine_json("good", input_=5),
                  "machine-raw.json": {"truncated": True, "raw_url": raw_url, "content": ""}}
        self.gh.on("GET", "/gists/g1", self.ok_gist(others))
        self.gh.on("GET", raw_url, env.resp(200, raw=DEEP.encode()))
        res = self.cycle()
        self.assertTrue(res.ok, res.error)
        self.assertEqual([m["id"] for m in res.remote["machines"]], ["good"])


# ---- 11. K4: sign-out stays available after a revoke whose delete failed ----------------------------
class TestRevokedPendingSignOut(Base):
    def test_revoke_with_failed_delete_offers_sign_out_everywhere(self):
        ref = self.sign_in()
        self.gh.on("GET", "/gists/g1", env.resp(401)).on("GET", "/user", env.resp(401), env.resp(401))
        with patch.object(self.ss, "delete", return_value=False):
            res = self.cycle()
        self.assertFalse(res.ok)
        st = self.st()
        self.assertTrue(st.get("revoked"))
        self.assertEqual(st.get("login"), "me")
        self.assertEqual(st.get("tokenDeletePending"), [list(ref)])
        self.assertTrue(sync.sign_out_incomplete())
        # tray settings: a «Sign out» button plus the scope hint, without reading the token
        buttons, labels = [], []
        methods = gui_methods("SettingsPage", ("render_sync", "_logout_note"),
                              _clear=lambda lay: None,
                              _label=lambda text, role=None, wrap=False: labels.append(text) or Mock())
        a = SimpleNamespace(logout_busy=False, logout_error=None, login_state=None, login_error=None,
                            logout=Mock(), start_login=Mock())
        page = SimpleNamespace(app=a, sync_lay=Mock(), _logout_note=methods._logout_note,
                               _btn=lambda text, cb: buttons.append((text, cb)) or Mock())
        with patch.object(vault, "read", side_effect=AssertionError("must not read the token")):
            methods.render_sync(page)
        self.assertIn(("Выйти", a.logout), buttons)
        self.assertIn(sync._delete_pending_text(), labels)
        self.assertTrue(any("github.com/settings/applications" in t for t in labels))
        # CLI status says the same and points at logout
        rc, out = self.run_cli("status")
        self.assertEqual(rc, 0)
        self.assertIn(sync._delete_pending_text(), out)
        self.assertIn("ccl-sync logout", out)
        # retry succeeds once the keyring answers
        rc, out = self.run_cli("logout")
        self.assertEqual(rc, 0, out)
        self.assert_signed_out_clean()


# ---- 12. the hint next to «Sign out» -------------------------------------------------------------
class TestSignOutHint(Base):
    def test_note_and_cli_carry_the_applications_address_in_both_languages(self):
        methods = gui_methods("SettingsPage", ("_logout_note",))
        for lang in ("ru", "en"):
            with self.subTest(lang=lang):
                common.settings().set("lang", lang)
                self.assertIn("github.com/settings/applications", methods._logout_note())
                self.sign_in()
                rc, out = self.run_cli("logout")
                self.assertEqual(rc, 0)
                self.assertIn("github.com/settings/applications", out)
                self.assertIn(methods._logout_note(), out, "CLI and tray use the same text")


# ---- 13. no token substring anywhere (cycle-3 flows) ---------------------------------------------------
class TestNoTokenSubstring(Base):
    def assertClean(self, where, text):
        for token in self.tokens:
            for part in (token, token[4:], token[-16:]):
                self.assertNotIn(part, text, where)
        for envelope in self.envelopes:
            self.assertNotIn(envelope, text, where + " (encoded credential)")

    def sandbox_dump(self):
        """Names and nonsecret file contents; protected credential payloads are expected."""
        out = []
        for root, _dirs, files in os.walk(self.tmp):
            for name in files:
                path = os.path.join(root, name)
                out.append(path)
                if path == common.TOKEN_FILE_PATH or root == os.path.join(common.CONFIG_DIR, "github-credentials"):
                    continue
                with open(path, "rb") as f:
                    out.append(f.read().decode("utf-8", "replace"))
        return "\n".join(out)

    def test_cycle3_flows(self):
        self.enable_v2_login()
        self.tokens = [env.make_token() for _ in range(5)]
        self.envelopes = []
        original_stage = self.auth_owner.store.stage_refresh
        def capture_stage(ref, payload, stage=original_stage):
            self.envelopes.append(payload)
            return stage(ref, payload)
        capture = patch.object(self.auth_owner.store, "stage_refresh", side_effect=capture_stage)
        capture.start()
        self.addCleanup(capture.stop)
        output = []
        self.st().update(tokenGeneration="")
        # Explicit backend selection occurs before staging; a failed V2 write
        # must not silently downgrade the received pair.
        with patch.object(self.v2ss, "_unlocked", return_value=[]):
            rc, out = self.cli_login(self.tokens[0])
        output.append(out)
        self.assertEqual(rc, 0, out)
        old_credential, old_ref = self.credential()
        self.assertEqual(old_credential["accessToken"], self.tokens[0])
        self.assertEqual(old_ref["backend"], "file")
        self.assertEqual(len(self.token_files()), 1)

        # Cancel a fully staged replacement; it must preserve the active file.
        attempt = sync.begin_login()
        original_stage = self.auth_owner.store.stage_refresh
        def stage_then_cancel(ref, payload):
            result = original_stage(ref, payload)
            sync.cancel_login(attempt)
            return result
        with patch.object(vault, "_ss_v2", return_value=None), \
                patch.object(self.auth_owner.store, "stage_refresh", side_effect=stage_then_cancel):
            with self.assertRaisesRegex(sync.LoginError, "^cancelled$"):
                sync.login_finish(dict(access_token=self.tokens[1]), attempt=attempt)
        credential, ref = self.credential()
        self.assertEqual(ref["generation"], old_ref["generation"])
        self.assertEqual(credential["accessToken"], self.tokens[0])
        self.assertEqual(len(self.token_files()), 1)

        # SS login retires the old envelope. Access-only triple401 and failed
        # cleanup remain visible, then a retry and fresh explicit login clean up.
        rc, out = self.cli_login(self.tokens[2])
        self.assertEqual(rc, 0, out)
        output.append(out)
        self.assertEqual(self.token_files(), [])
        self.st().update(gistId="g1", discoveredAt=time.time())
        self.gh.on("GET", "/gists/g1", self.ok_gist())
        output.append(self.run_cli("status")[1])
        self.gh.on("GET", "/gists/g1", env.resp(401)).on("GET", "/user", env.resp(401), env.resp(401))
        with patch.object(self.v2ss, "delete", return_value=False), \
                patch.object(usage, "refresh", return_value=(usage.new_index(), False, True)):
            rc, out = self.run_cli("push")
            self.assertEqual(rc, 2)
            self.assertIn("Войдите в GitHub заново: ccl-sync login", out)
            output.append(out)
        output.append(self.run_cli("status")[1])
        self.assertClean("sandbox files (pending state)", self.sandbox_dump())
        rc, out = self.run_cli("logout")
        self.assertEqual(rc, 0, out)
        output.append(out)
        rc, out = self.cli_login(self.tokens[3], refresh=self.tokens[4])
        self.assertEqual(rc, 0, out)
        output.append(out)
        rc, out = self.run_cli("logout")
        self.assertEqual(rc, 0, out)
        output.append(out)
        self.assert_signed_out_clean()
        self.assertClean("stdout/stderr", "\n".join(output))
        self.assertClean("sandbox files + names", self.sandbox_dump())
        self.assertClean("sync state", self.state_text())
        for call in self.gh.calls:
            headers = {k: v for k, v in call.headers.items() if k.lower() != "authorization"}
            self.assertClean("request " + repr(call), call.url + json.dumps(headers) + str(call.body or ""))


if __name__ == "__main__":
    unittest.main()
