"""SIGINT deferral and direct-raise regressions: fake SS, temporary XDG paths only."""

if __package__:
    from . import _sync_env as env
else:
    import _sync_env as env

import contextlib
import os
import signal
import threading
from unittest.mock import patch

from ccl import common, sync, vault


class ThreadingProxy(object):
    def __init__(self, workers):
        self.workers = workers

    def Thread(self, *args, **kwargs):
        worker = threading.Thread(*args, **kwargs)
        self.workers.append(worker)
        return worker

    def __getattr__(self, name):
        return getattr(threading, name)


class TestSigintDeferral(env.SyncEnv):
    @contextlib.contextmanager
    def signal_case(self, handler=signal.default_int_handler):
        """Every case restores SIGINT and releases/joins all its workers, even on failure."""
        orig = signal.getsignal(signal.SIGINT)
        self.events, self.workers = [], []
        proxy = ThreadingProxy(self.workers)
        try:
            signal.signal(signal.SIGINT, handler)
            with patch.object(vault, "threading", proxy):
                yield proxy
        finally:
            try:
                self.finish_workers()
            finally:
                signal.signal(signal.SIGINT, orig)

    def event(self):
        event = threading.Event()
        self.events.append(event)
        return event

    def finish_workers(self):
        for event in self.events:
            event.set()
        for worker in self.workers:
            if worker.ident is not None:
                worker.join(3)
                self.assertFalse(worker.is_alive(), "vault worker did not finish")

    def assert_logged_out(self):
        self.finish_workers()
        self.assertTrue(sync.logout())
        self.assertEqual(self.ss.items, {})
        self.assertFalse(sync.delete_pending())

    def exploding_guard(self, interrupt_in_start):
        with self.signal_case() as proxy:
            entered, release = self.event(), self.event()
            abandoned, refs = [], []

            def blocked_factory():
                abandoned.append(vault._worker.abandoned)
                refs.extend(self.st().get("tokenDeletePending"))
                entered.set()
                if not release.wait(3):
                    raise AssertionError("factory was not released")
                return self.ss

            class ExplodingLock(object):
                armed = True

                def __init__(self):
                    self.real = threading.Lock()

                def __enter__(self):
                    if (ExplodingLock.armed and
                            threading.current_thread() is threading.main_thread()):
                        ExplodingLock.armed = False
                        raise KeyboardInterrupt
                    return self.real.__enter__()

                def __exit__(self, *args):
                    return self.real.__exit__(*args)

            original_start = threading.Thread.start

            def start_then_interrupt(worker):
                original_start(worker)
                self.assertTrue(entered.wait(2), "factory never entered")
                raise KeyboardInterrupt

            start = (patch.object(threading.Thread, "start", start_then_interrupt)
                     if interrupt_in_start else contextlib.nullcontext())
            with patch.object(proxy, "Lock", ExplodingLock), \
                    patch.object(vault, "_ss", side_effect=blocked_factory), \
                    patch.object(self.ss, "set", wraps=self.ss.set) as set_token:
                with start, common.file_lock("sync"):
                    with self.assertRaises(KeyboardInterrupt):
                        vault.store(self.token)
                self.assertTrue(entered.is_set())
                self.assertFalse(ExplodingLock.armed)
                self.assertTrue(refs)
                pending = self.st().get("tokenDeletePending") or []
                self.assertTrue(refs[0] in pending or abandoned[0].is_set())
                self.finish_workers()
                set_token.assert_not_called()
            self.assertIs(signal.getsignal(signal.SIGINT), signal.default_int_handler)
            self.assert_logged_out()

    def test_repro_t_interrupt_acquiring_timeout_guard(self):
        self.exploding_guard(interrupt_in_start=False)

    def test_repro_h_second_interrupt_acquiring_exception_guard(self):
        self.exploding_guard(interrupt_in_start=True)

    def real_signal_store(self, stage, count, complete=False):
        replayed = []

        def previous(signum, frame):
            replayed.append((signum, frame))
            signal.default_int_handler(signum, frame)

        with self.signal_case(previous):
            entered, release, acknowledged, sent, finished = [self.event() for _ in range(5)]
            received, refs = [], []
            real_signal = signal.signal
            original = self.ss.set if stage == "set" else self.ss.factory

            def observe_install(signum, handler):
                if getattr(handler, "_ccl_sigint_deferred", False):
                    def observed(sig, frame):
                        handler(sig, frame)
                        received.append(sig)
                        acknowledged.set()
                    observed._ccl_sigint_deferred = True
                    return real_signal(signum, observed)
                return real_signal(signum, handler)

            def blocked(*args):
                refs.extend(self.st().get("tokenDeletePending"))
                entered.set()
                # This worker is already inside store's section. Acknowledge each
                # delivery so two real signals cannot coalesce in CPython/the OS.
                for _ in range(count):
                    acknowledged.clear()
                    os.kill(os.getpid(), signal.SIGINT)
                    if not acknowledged.wait(2):
                        raise AssertionError("SIGINT was not deferred")
                sent.set()
                if not complete and not release.wait(3):
                    raise AssertionError("worker was not released")
                result = original(*args)
                finished.set()
                return result

            target, name = (self.ss, "set") if stage == "set" else (vault, "_ss")
            file_set = vault._file_set
            with patch.object(target, name, side_effect=blocked), \
                    patch.object(signal, "signal", side_effect=observe_install), \
                    patch.object(vault, "_file_set", wraps=file_set) as fallback:
                with common.file_lock("sync"):
                    with self.assertRaises(KeyboardInterrupt):
                        vault.store(self.token)
                self.assertTrue(entered.is_set())
                self.assertTrue(sent.is_set())
                self.assertEqual(received, [signal.SIGINT] * count)
                self.assertEqual(len(replayed), 1)
                self.assertIsNotNone(replayed[0][1])
                self.assertIs(signal.getsignal(signal.SIGINT), previous)
                pending = self.st().get("tokenDeletePending") or []
                if stage == "set":
                    self.assertIn(refs[0], pending)
                else:
                    self.assertNotIn(refs[0], pending)
                if complete:
                    self.assertTrue(finished.is_set())
                    fallback.assert_not_called()
                    self.assertEqual(self.ss.items, {refs[0][0]: self.token})
                else:
                    self.assertFalse(finished.is_set())
                    fallback.assert_called_once()
                    file_refs = [ref for ref in pending if ref[1] == "file"]
                    self.assertEqual(len(file_refs), 1)
                    self.assertEqual(vault._file_get(file_refs[0][0], staged=True), self.token)
                self.finish_workers()
            self.assert_logged_out()
            self.assertEqual(len(replayed), 1)

    def test_real_sigint_waits_for_completed_ss_write(self):
        self.real_signal_store("set", count=1, complete=True)

    def test_real_sigint_waits_for_timeout_and_file_fallback(self):
        self.real_signal_store("set", count=1)

    def test_real_sigint_before_ss_write_removes_provisional_reference(self):
        self.real_signal_store("factory", count=1)

    def test_two_real_sigints_replay_one_keyboard_interrupt(self):
        self.real_signal_store("set", count=2)

    def test_default_handler_restored_after_success(self):
        with self.signal_case():
            with common.file_lock("sync"):
                vault.store(self.token)
            self.assertIs(signal.getsignal(signal.SIGINT), signal.default_int_handler)
            self.assert_logged_out()

    def test_handler_restored_after_file_error(self):
        with self.signal_case(), patch.object(vault, "_ss", return_value=None), \
                patch.object(vault, "_file_set", side_effect=OSError("disk failed")), \
                common.file_lock("sync"):
            with self.assertRaisesRegex(OSError, "disk failed"):
                vault.store(self.token)
            self.assertIs(signal.getsignal(signal.SIGINT), signal.default_int_handler)
            self.assertEqual([ref[1] for ref in self.st().get("tokenDeletePending")], ["file"])
        with self.signal_case():
            self.assert_logged_out()

    def test_sigint_wins_over_body_error_and_keeps_context(self):
        with self.signal_case():
            error = OSError("disk failed")

            def fail(*args):
                os.kill(os.getpid(), signal.SIGINT)
                raise error

            with patch.object(vault, "_ss", return_value=None), \
                    patch.object(vault, "_file_set", side_effect=fail), common.file_lock("sync"):
                with self.assertRaises(KeyboardInterrupt) as raised:
                    vault.store(self.token)
            self.assertIs(raised.exception.__context__, error)
            self.assertIs(signal.getsignal(signal.SIGINT), signal.default_int_handler)
            self.assertEqual([ref[1] for ref in self.st().get("tokenDeletePending")], ["file"])
            self.assert_logged_out()

    def test_store_on_non_main_thread_does_not_touch_handler(self):
        with self.signal_case() as proxy:
            result, errors = [], []

            def store():
                try:
                    with common.file_lock("sync"):
                        result.append(vault.store(self.token))
                except BaseException as error:
                    errors.append(error)

            with patch.object(signal, "signal", wraps=signal.signal) as install:
                caller = proxy.Thread(target=store)
                caller.start()
                caller.join(3)
                self.assertFalse(caller.is_alive())
                install.assert_not_called()
            self.assertEqual(errors, [])
            self.assertEqual(result[0][1], "secret-service")
            self.assertIs(signal.getsignal(signal.SIGINT), signal.default_int_handler)
            self.assert_logged_out()

    def test_sig_ign_store_does_not_touch_handler(self):
        with self.signal_case(signal.SIG_IGN):
            original_set = self.ss.set

            def set_token(*args):
                os.kill(os.getpid(), signal.SIGINT)
                return original_set(*args)

            with patch.object(self.ss, "set", side_effect=set_token), \
                    patch.object(signal, "signal", wraps=signal.signal) as install, \
                    common.file_lock("sync"):
                ref = vault.store(self.token)
                install.assert_not_called()
            self.assertEqual(ref[1], "secret-service")
            self.assertEqual(signal.getsignal(signal.SIGINT), signal.SIG_IGN)
            self.assert_logged_out()

    def test_non_python_handlers_are_noops(self):
        with self.signal_case():
            for handler in (signal.SIG_DFL, None):
                with self.subTest(handler=handler), \
                        patch.object(signal, "getsignal", return_value=handler), \
                        patch.object(signal, "signal") as install:
                    with vault._sigint_deferred():
                        pass
                    install.assert_not_called()

    def test_install_value_error_is_noop(self):
        with self.signal_case(), patch.object(signal, "signal", side_effect=ValueError) as install:
            with vault._sigint_deferred():
                self.assertIs(signal.getsignal(signal.SIGINT), signal.default_int_handler)
            install.assert_called_once()

    def test_custom_handler_replays_once_after_store(self):
        called, stages = [], []

        def previous(signum, frame):
            self.assertIs(signal.getsignal(signum), previous)
            self.assertEqual(stages, ["written", "verified"])
            called.append((signum, frame))

        with self.signal_case(previous):
            original_set, original_get = vault._file_set, vault._file_get

            def set_token(*args):
                os.kill(os.getpid(), signal.SIGINT)
                os.kill(os.getpid(), signal.SIGINT)
                self.assertEqual(called, [])
                original_set(*args)
                stages.append("written")

            def get_token(*args, **kwargs):
                self.assertEqual(called, [])
                stages.append("verified")
                return original_get(*args, **kwargs)

            with patch.object(vault, "_ss", return_value=None), \
                    patch.object(vault, "_file_set", side_effect=set_token), \
                    patch.object(vault, "_file_get", side_effect=get_token), common.file_lock("sync"):
                ref = vault.store(self.token)
            self.assertEqual(ref[1], "file")
            self.assertEqual(len(called), 1)
            self.assertEqual(called[0][0], signal.SIGINT)
            self.assertIsNotNone(called[0][1])
            self.assertIs(signal.getsignal(signal.SIGINT), previous)
            self.assert_logged_out()

    def test_nested_store_delete_ref_defers_until_outer_error(self):
        with self.signal_case():
            original_delete = vault._file_delete
            deleted = []

            def delete(generation):
                os.kill(os.getpid(), signal.SIGINT)
                result = original_delete(generation)
                deleted.append(generation)
                return result

            with patch.object(vault, "_ss", return_value=None), \
                    patch.object(vault, "_file_get", return_value=None), \
                    patch.object(vault, "_file_delete", side_effect=delete), common.file_lock("sync"):
                with self.assertRaises(KeyboardInterrupt) as raised:
                    vault.store(self.token)
            self.assertIsInstance(raised.exception.__context__, OSError)
            self.assertEqual(str(raised.exception.__context__), "could not save the token")
            self.assertEqual(len(deleted), 1)
            self.assertFalse(sync.delete_pending())
            self.assertIs(signal.getsignal(signal.SIGINT), signal.default_int_handler)
            self.assert_logged_out()

    def test_publish_signal_after_replace_waits_for_state(self):
        with self.signal_case(), patch.object(vault, "_ss", return_value=None):
            original_replace = os.replace

            def replace(src, dst):
                original_replace(src, dst)
                if dst == common.TOKEN_FILE_PATH:
                    os.kill(os.getpid(), signal.SIGINT)

            with common.file_lock("sync"):
                ref = vault.store(self.token)
                with patch.object(vault.os, "replace", side_effect=replace):
                    with self.assertRaises(KeyboardInterrupt):
                        vault.publish(ref)
            self.assertEqual(vault.active(self.st()), ref)
            self.assertEqual(vault.read(), (self.token, "file"))
            self.assertNotIn(list(ref), self.st().get("tokenDeletePending") or [])
            self.assertIs(signal.getsignal(signal.SIGINT), signal.default_int_handler)
            self.assert_logged_out()

    def test_delete_ref_signal_records_failed_deletion(self):
        with self.signal_case():
            ref = ["unpublished", "secret-service"]
            self.ss.items[ref[0]] = self.token

            def fail(generation):
                os.kill(os.getpid(), signal.SIGINT)
                return False

            with patch.object(self.ss, "delete", side_effect=fail), common.file_lock("sync"):
                with self.assertRaises(KeyboardInterrupt):
                    vault.delete_ref(ref)
            self.assertEqual(self.st().get("tokenDeletePending"), [ref])
            self.assertIs(signal.getsignal(signal.SIGINT), signal.default_int_handler)
            self.assert_logged_out()

    def test_retire_replays_between_references_without_losing_pending(self):
        with self.signal_case():
            with common.file_lock("sync"):
                refs = [list(vault.store(self.token)) for _ in range(2)]
            original_delete = self.ss.delete

            def delete(generation):
                os.kill(os.getpid(), signal.SIGINT)
                return original_delete(generation)

            with patch.object(self.ss, "delete", side_effect=delete), common.file_lock("sync"):
                with self.assertRaises(KeyboardInterrupt):
                    vault.retire(refs)
            self.assertEqual(self.st().get("tokenDeletePending"), [refs[1]])
            self.assertEqual(self.ss.items, {refs[1][0]: self.token})
            self.assertIs(signal.getsignal(signal.SIGINT), signal.default_int_handler)
            self.assert_logged_out()

    def test_delete_signal_during_invalidation_keeps_reference(self):
        with self.signal_case():
            ref = self.sign_in()
            original_update = common.Store.update

            def update(st, **kwargs):
                if kwargs.get("tokenGeneration") == "":
                    os.kill(os.getpid(), signal.SIGINT)
                return original_update(st, **kwargs)

            with patch.object(common.Store, "update", update), common.file_lock("sync"):
                with self.assertRaises(KeyboardInterrupt):
                    vault.delete()
            self.assertEqual(vault.active(self.st()), ("", None))
            self.assertEqual(self.st().get("tokenDeletePending"), [list(ref)])
            self.assertIs(signal.getsignal(signal.SIGINT), signal.default_int_handler)
            self.assert_logged_out()

    def test_delete_sweep_signal_records_failed_sweep(self):
        with self.signal_case():
            self.st().update(tokenGeneration="")

            def fail():
                os.kill(os.getpid(), signal.SIGINT)
                return False

            with patch.object(vault, "_delete_all_token_files", side_effect=fail), common.file_lock("sync"):
                with self.assertRaises(KeyboardInterrupt):
                    vault.delete()
            self.assertEqual(self.st().get("tokenDeletePending"), [["legacy", "file"]])
            self.assertIs(signal.getsignal(signal.SIGINT), signal.default_int_handler)
            self.assert_logged_out()
