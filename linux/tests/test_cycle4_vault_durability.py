"""Crash-window regressions: temporary XDG paths, fake SS and scripted transport only."""

if __package__:
    from . import _sync_env as env
else:
    import _sync_env as env

import contextlib
import io
import os
import tempfile
import threading
from types import SimpleNamespace
from unittest.mock import patch

from ccl import cli, common, sync, vault


class TestVaultDurability(env.SyncEnv):
    def token_names(self):
        base = os.path.basename(common.TOKEN_FILE_PATH)
        return sorted(n for n in os.listdir(common.CONFIG_DIR)
                      if n.startswith(base) or n.startswith("." + base + "."))

    def test_ctrl_c_inside_start_abandons_worker_and_cleans_late_write(self):
        for stage in ("factory", "set"):
            with self.subTest(stage=stage):
                entered, release = threading.Event(), threading.Event()
                workers, refs = [], []
                original_start = threading.Thread.start
                original = self.ss.factory if stage == "factory" else self.ss.set

                def blocked(*args):
                    entered.set()
                    if not release.wait(3):
                        raise AssertionError("worker was not released")
                    return original(*args)

                def start_then_interrupt(t):
                    workers.append(t)
                    original_start(t)
                    self.assertTrue(entered.wait(2), "worker never reached " + stage)
                    refs.extend(self.st().get("tokenDeletePending"))
                    raise KeyboardInterrupt

                target, name = (vault, "_ss") if stage == "factory" else (self.ss, "set")
                with patch.object(target, name, side_effect=blocked), \
                        patch.object(self.ss, "get", wraps=self.ss.get) as get:
                    try:
                        with patch.object(threading.Thread, "start", start_then_interrupt), \
                                common.file_lock("sync"):
                            with self.assertRaises(KeyboardInterrupt):
                                vault.store(self.token)
                        self.assertEqual(len(refs), 1)
                        self.assertEqual(refs[0][1], "secret-service")
                        # Before intent is published, abandonment suppresses set;
                        # after intent, the reference must survive for retry.
                        expected = refs if stage == "set" else []
                        self.assertEqual(self.st().get("tokenDeletePending") or [], expected)
                    finally:
                        release.set()
                        for t in workers:
                            t.join(3)
                            self.assertFalse(t.is_alive())
                    get.assert_not_called()
                self.assertEqual(self.st().get("tokenDeletePending") or [], expected)
                self.assertEqual(self.ss.items, {})
                self.assertTrue(sync.logout())
                self.assertEqual(self.ss.items, {})
                self.assertFalse(sync.delete_pending())

    def test_ctrl_c_before_start_creates_no_token_or_pending_reference(self):
        with patch.object(threading.Thread, "start", side_effect=KeyboardInterrupt), \
                common.file_lock("sync"):
            with self.assertRaises(KeyboardInterrupt):
                vault.store(self.token)
        self.assertFalse(sync.delete_pending())
        self.assertEqual(self.ss.items, {})

    def test_retire_removes_only_own_atomic_temps_without_following_symlinks(self):
        generation = "deadbeef"
        ref = [generation, "file"]
        self.st().update(tokenDeletePending=[ref])
        common.ensure_dirs()
        prefix = "." + os.path.basename(vault._staged_path(generation)) + "."
        fd, temp = tempfile.mkstemp(prefix=prefix, dir=common.CONFIG_DIR)
        with os.fdopen(fd, "w") as f:
            f.write(self.token + "\n" + generation + "\n")
        target = os.path.join(self.tmp, "outside-token")
        common.write_atomic(target, "untouched")
        link = os.path.join(common.CONFIG_DIR, prefix + "link")
        os.symlink(target, link)
        unrelated = ["." + os.path.basename(vault._staged_path(generation + "0")) + ".tmp",
                     prefix[:-1] + "x.tmp", "unrelated.txt"]
        for name in unrelated:
            common.write_atomic(os.path.join(common.CONFIG_DIR, name), "untouched")
        with common.file_lock("sync"):
            vault.retire([ref])
        self.assertFalse(sync.delete_pending())
        self.assertFalse(os.path.lexists(temp))
        self.assertFalse(os.path.lexists(link))
        self.assertEqual(sorted(os.listdir(common.CONFIG_DIR)), sorted(unrelated))
        for path in [target] + [os.path.join(common.CONFIG_DIR, n) for n in unrelated]:
            with open(path) as f:
                self.assertEqual(f.read(), "untouched")

    def test_atomic_temp_deletion_errors_keep_reference_for_retry(self):
        generation = "deadbeef"
        ref = [generation, "file"]
        path = os.path.join(common.CONFIG_DIR,
                            "." + os.path.basename(vault._staged_path(generation)) + ".tmp")
        original_unlink, original_listdir = os.unlink, os.listdir
        for operation in ("listdir", "unlink"):
            with self.subTest(operation=operation):
                self.st().update(tokenDeletePending=[ref])
                common.write_atomic(path, self.token)
                original = original_listdir if operation == "listdir" else original_unlink
                denied_path = common.CONFIG_DIR if operation == "listdir" else path

                def denied(name, *args, **kwargs):
                    if name == denied_path:
                        raise PermissionError("denied")
                    return original(name, *args, **kwargs)

                with patch.object(vault.os, operation, side_effect=denied), common.file_lock("sync"):
                    vault.retire([ref])
                self.assertEqual(self.st().get("tokenDeletePending"), [ref])
                self.assertTrue(os.path.exists(path))
                with common.file_lock("sync"):
                    vault.retire([ref])
                self.assertFalse(sync.delete_pending())
                self.assertFalse(os.path.exists(path))

    def test_ctrl_c_then_process_loss_leaves_late_item_for_next_logout(self):
        entered, release = threading.Event(), threading.Event()
        workers, generations = [], []
        original_set = self.ss.set

        def blocked_set(token, generation):
            generations.append(generation)
            entered.set()
            release.wait(3)
            original_set(token, generation)

        class InterruptingEvent(threading.Event):
            def wait(event, timeout=None):
                if timeout is not None and threading.current_thread() is threading.main_thread():
                    if not entered.wait(2):
                        raise AssertionError("SS write never started")
                    raise KeyboardInterrupt
                return super().wait(timeout)

        def worker(*args, **kwargs):
            t = threading.Thread(*args, **kwargs)
            workers.append(t)
            return t

        proxy = SimpleNamespace(Event=InterruptingEvent, Lock=threading.Lock, Thread=worker)
        # No successful worker cleanup: model a remote CreateItem completing after
        # the client process was lost, without sending signals or using real services.
        with patch.object(self.ss, "set", side_effect=blocked_set), \
                patch.object(self.ss, "delete", return_value=False):
            try:
                with patch.object(vault, "threading", proxy), common.file_lock("sync"):
                    with self.assertRaises(KeyboardInterrupt):
                        vault.store(self.token)
                self.assertEqual(self.st().get("tokenDeletePending"),
                                 [[generations[0], "secret-service"]])
            finally:
                release.set()
                for t in workers:
                    t.join(3)
                    self.assertFalse(t.is_alive())
        self.assertEqual(self.ss.items, {generations[0]: self.token})
        self.assertTrue(sync.logout())
        self.assertEqual(self.ss.items, {})
        self.assertFalse(sync.delete_pending())

    def test_pending_is_durable_while_timed_waits_for_set(self):
        entered, release = threading.Event(), threading.Event()
        result, errors, generations = [], [], []
        original_set = self.ss.set

        def blocked_set(token, generation):
            generations.append(generation)
            entered.set()
            release.wait(3)
            original_set(token, generation)

        def store():
            try:
                with common.file_lock("sync"):
                    result.append(vault.store(self.token))
            except BaseException as e:
                errors.append(e)

        with patch.object(self.ss, "set", side_effect=blocked_set), patch.object(vault, "TIMEOUT", 3):
            caller = threading.Thread(target=store)
            caller.start()
            try:
                self.assertTrue(entered.wait(2))
                self.assertTrue(caller.is_alive())
                self.assertEqual(self.st().get("tokenDeletePending"),
                                 [[generations[0], "secret-service"]])
            finally:
                release.set()
                caller.join(4)
            self.assertFalse(caller.is_alive())
        self.assertEqual(errors, [])
        self.assertEqual(result, [(generations[0], "secret-service")])
        self.assertTrue(sync.logout())

    def test_kill_after_store_before_publish(self):
        vault._ss = lambda: None
        original_set = vault._file_set

        def checked_set(token, generation):
            self.assertEqual(self.st().get("tokenDeletePending"), [[generation, "file"]])
            original_set(token, generation)

        with patch.object(vault, "_file_set", side_effect=checked_set), common.file_lock("sync"):
            ref = vault.store(self.token)
        self.assertEqual(self.st().get("tokenDeletePending"), [list(ref)])
        self.assertTrue(os.path.exists(vault._staged_path(ref[0])))
        self.assertTrue(sync.logout())
        self.assertEqual(self.token_names(), [])

    def test_kill_after_publication_replace_before_state_update(self):
        vault._ss = lambda: None
        replace = os.replace

        def replace_then_die(src, dst):
            replace(src, dst)
            if dst == common.TOKEN_FILE_PATH:
                raise KeyboardInterrupt

        with common.file_lock("sync"):
            ref = vault.store(self.token)
            with patch.object(vault.os, "replace", side_effect=replace_then_die):
                with self.assertRaises(KeyboardInterrupt):
                    vault.publish(ref)
        self.assertFalse(self.st().has("tokenGeneration"))
        self.assertTrue(os.path.exists(common.TOKEN_FILE_PATH))
        self.assertEqual(self.st().get("tokenDeletePending"), [list(ref)])
        self.assertTrue(sync.logout())
        self.assertEqual(self.token_names(), [])

    def test_no_secret_service_login_and_cli_logout_succeed(self):
        vault._ss = lambda: None
        self.gh.on("GET", "/user", env.resp(200, {"login": "me"}))
        self.assertEqual(sync.login_finish(self.token), "me")
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(cli.main(["logout"]), 0)
        self.assertFalse(sync.delete_pending())
        self.assertEqual(self.token_names(), [])

    def test_sweep_untracked_files_and_atomic_temps_without_following_symlinks(self):
        self.st().update(tokenGeneration="")
        base = os.path.basename(common.TOKEN_FILE_PATH)
        names = [base, base + ".pending-orphan", "." + base + ".abc",
                 "." + base + ".pending-orphan.xyz"]
        for name in names:
            common.write_atomic(os.path.join(common.CONFIG_DIR, name), self.token)
        target = os.path.join(self.tmp, "outside-token")
        common.write_atomic(target, "untouched")
        os.symlink(target, os.path.join(common.CONFIG_DIR, base + ".pending-link"))
        outside_dir = os.path.join(self.tmp, "outside-dir")
        os.mkdir(outside_dir)
        common.write_atomic(os.path.join(outside_dir, base), "untouched")
        os.symlink(outside_dir, os.path.join(common.CONFIG_DIR, "." + base + ".dir"))
        unrelated = ["github-token-backup", "github-tokenizer", ".github-token-backup.tmp", "settings.json"]
        for name in unrelated:
            common.write_atomic(os.path.join(common.CONFIG_DIR, name), "untouched")
        self.assertTrue(sync.logout())
        self.assertEqual(sorted(os.listdir(common.CONFIG_DIR)), sorted(unrelated))
        for path in (target, os.path.join(outside_dir, base)):
            with open(path) as f:
                self.assertEqual(f.read(), "untouched")

    def test_unlink_failure_prevents_success_and_is_retryable(self):
        self.st().update(tokenGeneration="")
        path = os.path.join(common.CONFIG_DIR, ".github-token.pending-orphan.tmp")
        common.write_atomic(path, self.token)
        unlink = os.unlink

        def denied(name, *args, **kwargs):
            if name == path:
                raise PermissionError("denied")
            return unlink(name, *args, **kwargs)

        with patch.object(vault.os, "unlink", side_effect=denied):
            self.assertFalse(sync.logout())
        self.assertTrue(sync.sign_out_incomplete())
        self.assertTrue(os.path.exists(path))
        self.assertTrue(sync.logout())
        self.assertEqual(self.token_names(), [])
        self.assertFalse(sync.delete_pending())

    def test_sweep_runs_even_when_addressed_ss_delete_fails(self):
        ref = self.sign_in()
        common.write_atomic(os.path.join(common.CONFIG_DIR, ".github-token.orphan"), self.token)
        with patch.object(self.ss, "delete", return_value=False):
            self.assertFalse(sync.logout())
        self.assertEqual(self.token_names(), [])
        self.assertEqual(self.st().get("tokenDeletePending"), [list(ref)])
        self.assertTrue(sync.logout())

    def test_no_ss_write_started_removes_provisional_reference_and_reraises(self):
        with patch.object(vault, "_ss", side_effect=KeyboardInterrupt), common.file_lock("sync"):
            with self.assertRaises(KeyboardInterrupt):
                vault.store(self.token)
        self.assertFalse(sync.delete_pending())
        self.assertEqual(self.ss.items, {})

    def test_temporary_ss_failure_does_not_count_as_legacy_deletion(self):
        self.ss.items["legacy"] = self.token
        self.st().update(login="me")
        with patch.object(vault, "_ss", side_effect=RuntimeError("temporarily unavailable")):
            self.assertFalse(sync.logout())
        self.assertEqual(self.st().get("tokenDeletePending"), [["legacy", None]])
        self.assertTrue(sync.logout())
        self.assertEqual(self.ss.items, {})

    def test_live_login_with_pending_cleanup_has_no_incomplete_signout(self):
        self.gh.on("GET", "/user", env.resp(200, {"login": "me"}))
        with patch.object(self.ss, "delete", return_value=False):
            self.assertEqual(sync.login_finish(self.token), "me")
        self.assertTrue(sync.delete_pending())
        self.assertFalse(sync.sign_out_incomplete())
        self.assertTrue(sync.logout())
