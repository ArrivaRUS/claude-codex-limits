"""Final CLI/GUI regressions. All state, secrets and transport use the offline sandbox."""

if __package__:
    from . import _isolate  # noqa: F401
    from . import _sync_env as env
else:
    import _isolate  # noqa: F401
    import _sync_env as env

import argparse
import ast
import contextlib
import io
import json
from pathlib import Path
import threading
import time
from types import SimpleNamespace
from unittest.mock import Mock, patch

from ccl import cli, common, sync, usage, vault


class TestPublicationResponsiveness(env.SyncEnv):
    def test_hung_retirement_does_not_hold_login_lock(self):
        old = self.sign_in()
        attempt = sync.begin_login()
        self.gh.on("GET", "/user", env.resp(200, {"login": "new"}))
        entered = threading.Event()
        release = self.ss.hang_delete = self.ss.event()
        original_delete = self.ss.delete
        errors, elapsed = [], []

        def delete(generation):
            self.assertEqual(generation, old[0])
            entered.set()
            return original_delete(generation)

        def finish():
            try:
                sync.login_finish(env.make_token(), attempt=attempt)
            except Exception as e:
                errors.append(e)

        def controls():
            start = time.monotonic()
            sync.cancel_login(attempt + 100)
            elapsed.append(time.monotonic() - start)
            start = time.monotonic()
            sync.begin_login()
            elapsed.append(time.monotonic() - start)

        with patch.object(vault, "TIMEOUT", 5), patch.object(self.ss, "delete", side_effect=delete):
            worker = threading.Thread(target=finish, daemon=True)
            worker.start()
            controller = None
            try:
                self.assertTrue(entered.wait(2))
                self.assertEqual(self.st().get("login"), "new")
                with common.file_lock("sync", blocking=False) as held:
                    self.assertFalse(held, "retirement must retain the process lock")
                controller = threading.Thread(target=controls, daemon=True)
                controller.start()
                controller.join(0.9)
                self.assertFalse(controller.is_alive())
                self.assertEqual(len(elapsed), 2)
                self.assertTrue(all(t < 1 for t in elapsed))
            finally:
                release.set()
                worker.join(3)
                if controller:
                    controller.join(3)
        self.assertFalse(worker.is_alive())
        self.assertEqual(errors, [])
        self.assertFalse(sync.delete_pending())
        self.assertEqual(len(self.ss.items), 1)


class TestCLI(env.SyncEnv):
    def capture(self, command, args=None):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), patch.object(cli, "_timer_status", return_value="test timer"):
            code = command(args)
        return code, out.getvalue()

    def test_status_stall_does_not_require_attempt_in_cli_process(self):
        self.sign_in(gist=None)
        now = time.time()
        self.st().update(lastOkAt=now - 4000, lastError="offline", lastErrorAt=now - 10)
        self.assertIsNone(sync._first_attempt_at)
        code, out = self.capture(cli.cmd_status)
        self.assertEqual(code, 0)
        self.assertIn("Синхронизация стоит с", out)

    def test_status_live_login_with_pending_deletions(self):
        self.sign_in(gist=None)
        now = time.time()
        self.st().update(tokenDeletePending=[["old", "secret-service"]],
                         lastOkAt=now - 4000, lastError="offline", lastErrorAt=now - 10)
        with patch.object(vault, "read", wraps=vault.read) as read:
            code, out = self.capture(cli.cmd_status)
        self.assertEqual(code, 0)
        read.assert_called_once_with()
        self.assertIn("GitHub: me", out)
        self.assertNotIn("Выход не завершён", out)
        self.assertIn("Синхронизация стоит с", out)
        self.assertTrue(sync.delete_pending())

    def test_login_passes_current_attempt_and_cancellation_to_finish(self):
        observed = []
        def poll(dev, cancelled):
            self.assertFalse(cancelled())
            observed.append(cancelled)
            return self.token
        def finish(token, cancelled, attempt):
            self.assertEqual(token, self.token)
            self.assertTrue(sync.is_current(attempt))
            self.assertIs(cancelled, observed[0])
            sync.cancel_login(attempt)
            self.assertTrue(cancelled())
            return "me"
        with patch.object(sync, "device_start", return_value={"verification_uri": "test", "user_code": "CODE"}), \
                patch.object(sync, "device_poll", side_effect=poll), \
                patch.object(sync, "login_finish", side_effect=finish) as finished, \
                patch.object(cli, "cmd_push", return_value=0):
            code, _ = self.capture(cli.cmd_login, argparse.Namespace(force=True, no_browser=True))
        self.assertEqual(code, 0)
        finished.assert_called_once()

    def test_ctrl_c_cancels_attempt_at_each_stage(self):
        for stage in ("device_start", "device_poll", "login_finish"):
            with self.subTest(stage=stage), \
                    patch.object(sync, "device_start", return_value={"verification_uri": "test", "user_code": "CODE"}), \
                    patch.object(sync, "device_poll", return_value=self.token), \
                    patch.object(sync, "login_finish", return_value="me"), \
                    patch.object(sync, stage, side_effect=KeyboardInterrupt), \
                    patch.object(sync, "cancel_login", wraps=sync.cancel_login) as cancel:
                code, _ = self.capture(cli.cmd_login, argparse.Namespace(force=True, no_browser=True))
                self.assertEqual(code, 130)
                cancel.assert_called_once()
                self.assertFalse(sync.is_current(cancel.call_args.args[0]))

    def test_logout_revoked_pending_text_and_retry_hint_in_both_languages(self):
        for lang in ("ru", "en"):
            with self.subTest(lang=lang):
                common.settings().set("lang", lang)
                self.sign_in()
                self.st().update(revoked=True)
                with patch.object(self.ss, "delete", return_value=False):
                    code, out = self.capture(cli.cmd_logout)
                self.assertEqual(code, 1)
                self.assertIn(sync._delete_pending_text(), out)
                for revoked in (True, False):
                    self.st().update(revoked=revoked)
                    code, out = self.capture(cli.cmd_status)
                    self.assertIn(sync._delete_pending_text(), out)
                    self.assertIn("ccl-sync logout", out)
                    self.assertNotIn("ccl-sync login", out)
                    self.assertNotIn("Sign in to GitHub again", out)
                    self.assertNotIn("Войдите в GitHub заново", out)
                code, _ = self.capture(cli.cmd_logout)
                self.assertEqual(code, 0)
                self.assertFalse(sync.delete_pending())

    def test_logout_busy_with_pending_uses_pending_text(self):
        self.st().update(tokenDeletePending=[["old", "secret-service"]])
        with common.file_lock("sync"):
            code, out = self.capture(cli.cmd_logout)
        self.assertEqual(code, 1)
        self.assertIn(sync._delete_pending_text(), out)

    def test_status_unreachable_is_retryable_in_both_languages(self):
        self.sign_in()
        for lang, expected in (("ru", "Хранилище секретов недоступно — синхронизация повторит попытку сама"),
                               ("en", "The Secret Service is unreachable — sync will try again by itself")):
            common.settings().set("lang", lang)
            with patch.object(vault, "read", return_value=(None, "unreachable")):
                code, out = self.capture(cli.cmd_status)
            self.assertEqual(code, 0)
            self.assertIn(expected, out)
            self.assertNotIn("ccl-sync login", out)
        self.assertEqual(self.gh.calls, [])

    def test_push_timeout_is_error(self):
        self.sign_in()
        with patch.object(vault, "read", return_value=(None, "timeout")), \
                patch.object(usage, "refresh", return_value=(usage.new_index(), False, True)):
            code, out = self.capture(cli.cmd_push, argparse.Namespace(quiet=False, force=False, auto=False))
        self.assertEqual(code, 1)
        self.assertIn("Ошибка синхронизации", out)
        self.assertNotIn("выключена", out)

    def test_status_busy_uses_cache_without_token_or_transport(self):
        self.sign_in()
        common.write_json(common.SYNC_REMOTE_PATH, {"machines": [{"name": "cached-pc", "os": "Test"}]})
        with common.file_lock("sync"), \
                patch.object(vault, "read", side_effect=AssertionError("must not read")) as read, \
                patch.object(sync, "transport", side_effect=AssertionError("must not request")) as transport:
            code, out = self.capture(cli.cmd_status)
        self.assertEqual(code, 0)
        self.assertIn("cached-pc", out)
        self.assertIn("Синхронизация идёт в другом процессе — показан кэш", out)
        self.assertNotIn("вход не выполнен", out)
        read.assert_not_called()
        transport.assert_not_called()

    def test_status_reads_token_and_gist_only_while_locked(self):
        self.sign_in()
        original_read = vault.read
        def check_lock():
            with common.file_lock("sync", blocking=False) as held:
                self.assertFalse(held)
        def read():
            check_lock()
            return original_read()
        def response(*args):
            check_lock()
            return self.ok_gist({"machine-good.json": env.machine_json("good")})
        self.gh.on("GET", "/gists/g1", response)
        with patch.object(vault, "read", side_effect=read):
            code, out = self.capture(cli.cmd_status)
        self.assertEqual(code, 0)
        self.assertIn("pc-good", out)

    def test_status_skips_hostile_machine_records(self):
        self.sign_in()
        bad = [[], None, 1, {"machine": []}, {"machine": "bad"}]
        bad.extend({"machine": {key: value}} for key in ("name", "os", "app") for value in ([], {}, 9, None))
        files = {"machine-bad%d.json" % i: json.dumps(obj) for i, obj in enumerate(bad)}
        files.update({"machine-deep.json": "[" * 100000 + "0" + "]" * 100000,
                      "machine-good.json": env.machine_json("good"), "machine-notext.json": {"content": []},
                      "machine-badfile.json": {"content": {"bad": 1}}})
        self.gh.on("GET", "/gists/g1", self.ok_gist(files))
        code, out = self.capture(cli.cmd_status)
        self.assertEqual(code, 0)
        self.assertIn("pc-good", out)
        self.assertEqual(out.count("  • "), 1)

    def test_logout_success_prints_scope_hint_on_second_line(self):
        messages = {
            "ru": "Вход удаляется только на этом компьютере. Отозвать доступ приложения полностью — github.com/settings/applications",
            "en": "This signs out only this computer. To revoke the app's access entirely, visit github.com/settings/applications",
        }
        for lang, expected in messages.items():
            common.settings().set("lang", lang)
            self.sign_in()
            code, out = self.capture(cli.cmd_logout)
            self.assertEqual(code, 0)
            self.assertEqual(out.splitlines()[1], expected)


# Execute the actual controller methods with plain fake receivers, without importing Qt
# or constructing a tray. No replacement implementation of these methods lives here.
def gui_methods(class_name, names, **globals_):
    path = Path(__file__).parents[1] / "ccl" / "gui" / "app.py"
    tree = ast.parse(path.read_text())
    cls = next(n for n in tree.body if isinstance(n, ast.ClassDef) and n.name == class_name)
    methods = [n for n in cls.body if isinstance(n, ast.FunctionDef) and n.name in names]
    assert len(methods) == len(names)
    for method in methods:
        method.decorator_list = []
    scope = dict(sync=sync, threading=threading, common=common, vault=vault, tr=common.tr, **globals_)
    exec(compile(ast.Module(body=methods, type_ignores=[]), str(path), "exec"), scope)
    return SimpleNamespace(**{n: scope[n] for n in names})


class TestGUIControllers(env.SyncEnv):
    def receiver(self):
        return SimpleNamespace(logout_busy=False, logout_error=None, login_attempt=None,
                               login_state=None, login_error=None, login_code=None,
                               bridge=SimpleNamespace(login_code=Mock(), login_done=Mock(), logout_done=Mock()),
                               win=Mock(), load_local=Mock(), refresh_logs=Mock())

    def test_logout_worker_busy_errors_and_completion(self):
        methods = gui_methods("TrayApp", ("logout", "on_logout_done"))
        for error in (sync.LoginError("busy"), RuntimeError("failure"), None):
            with self.subTest(error=error):
                a = self.receiver()
                entered, release, done = threading.Event(), threading.Event(), threading.Event()
                def logout():
                    entered.set()
                    release.wait(3)
                    if error:
                        raise error
                    return False
                a.bridge.logout_done.emit.side_effect = lambda *args: done.set()
                with patch.object(sync, "logout", side_effect=logout) as signout:
                    try:
                        start = time.monotonic()
                        methods.logout(a)
                        self.assertLess(time.monotonic() - start, 1)
                        self.assertTrue(entered.wait(1))
                        self.assertTrue(a.logout_busy)
                        methods.logout(a)
                        signout.assert_called_once()
                    finally:
                        release.set()
                        self.assertTrue(done.wait(2))
                ok, message = a.bridge.logout_done.emit.call_args.args
                self.assertFalse(ok)
                self.assertEqual(message, str(error) if error else sync._delete_pending_text())
                methods.on_logout_done(a, ok, message)
                self.assertFalse(a.logout_busy)
                self.assertEqual(a.logout_error, message)
                a.load_local.assert_called_once()
                a.win.page0_changed.assert_called_once()
                methods.on_logout_done(a, True, None)
                self.assertIsNone(a.logout_error)

    def test_cancel_a_start_b_ignores_late_a_signals(self):
        methods = gui_methods("TrayApp", ("start_login", "cancel_login", "on_login_done", "on_login_code"))
        a = self.receiver()
        workers = []
        def thread(*, target, daemon):
            self.assertTrue(daemon)
            workers.append(target)
            return SimpleNamespace(start=lambda: None)
        callbacks = []
        def poll(dev, cancelled):
            callbacks.append(cancelled)
            return self.token
        def finish(token, cancelled, attempt):
            self.assertEqual(cancelled(), not sync.is_current(attempt))
            if cancelled():
                raise sync.LoginError("cancelled")
            return "new"
        with patch.object(threading, "Thread", side_effect=thread), \
                patch.object(sync, "device_start", return_value={"user_code": "CODE"}), \
                patch.object(sync, "device_poll", side_effect=poll), \
                patch.object(sync, "login_finish", side_effect=finish):
            methods.start_login(a)
            old = a.login_attempt
            methods.cancel_login(a)
            methods.start_login(a)
            new = a.login_attempt
            workers[0]()
            self.assertTrue(callbacks[0]())
            methods.on_login_code(a, old, {"user_code": "OLD"})
            methods.on_login_done(a, old, "old", "old error")
            self.assertIsNone(a.login_code)
            self.assertEqual(a.login_state, "awaiting")
            self.assertIsNone(a.login_error)
            a.refresh_logs.assert_not_called()
            workers[1]()
            self.assertFalse(callbacks[1]())
            self.assertEqual(a.bridge.login_done.emit.call_args.args, (new, "new", None))
            methods.on_login_done(a, new, "new", None)
            a.refresh_logs.assert_called_once_with(force_push=True)

    def test_render_live_login_with_pending_deletions_without_qt(self):
        self.sign_in(gist=None)
        self.st().update(tokenDeletePending=[["old", "secret-service"]])
        label, row, button = Mock(), Mock(), Mock()
        methods = gui_methods("SettingsPage", ("render_sync", "_logout_note"),
                              _clear=lambda lay: None, _label=label, _row=row, QLineEdit=Mock())
        a = self.receiver()
        a.logout = Mock()
        a.start_login = Mock()
        page = SimpleNamespace(app=a, sync_lay=Mock(), _btn=button, _logout_note=methods._logout_note)
        with patch.object(vault, "read", wraps=vault.read) as read, \
                patch.object(sync, "machine_list", return_value=[{"name": "other-pc"}]) as machines:
            methods.render_sync(page)
        read.assert_called_once_with()
        button.assert_called_once_with("Выйти", a.logout)
        row.assert_any_call("GitHub: me", button.return_value)
        page.sync_lay.addWidget.assert_any_call(row.return_value)
        label.assert_any_call(methods._logout_note(), "note", True)
        machines.assert_called_once_with()
        texts = [call.args[0] for call in label.call_args_list]
        self.assertTrue(any("other-pc" in text for text in texts))
        self.assertFalse(any("Выход не завершён" in text for text in texts))
        self.assertTrue(sync.delete_pending())

    def test_render_pending_busy_and_unreachable_without_qt(self):
        labels, buttons = [], []
        def label(text, role=None, wrap=False):
            labels.append((text, role, wrap))
            return Mock()
        methods = gui_methods("SettingsPage", ("render_sync", "_logout_note"),
                              _clear=lambda lay: None, _label=label)
        a = self.receiver()
        a.logout = Mock()
        a.start_login = Mock()
        def button(text, callback):
            b = Mock()
            buttons.append(b)
            return b
        page = SimpleNamespace(app=a, sync_lay=Mock(), _btn=button, _logout_note=methods._logout_note)
        for revoked in (True, False):
            labels.clear()
            self.st().update(login=None, revoked=revoked, tokenDeletePending=[["old", "secret-service"]])
            with patch.object(vault, "read", side_effect=AssertionError("pending must not read token")):
                methods.render_sync(page)
            self.assertEqual(labels[0][0], sync._delete_pending_text())
            self.assertIn((methods._logout_note(), "note", True), labels)
            buttons[-2].setEnabled.assert_called_once_with(True)
        a.logout_busy = True
        methods.render_sync(page)
        buttons[-1].setEnabled.assert_called_once_with(False)
        a.logout_busy = False
        self.st().update(login="me", revoked=False, tokenDeletePending=None)
        labels.clear()
        with patch.object(vault, "read", return_value=(None, "unreachable")):
            methods.render_sync(page)
        self.assertIn("Хранилище секретов недоступно — синхронизация повторит попытку сама", labels[0][0])
