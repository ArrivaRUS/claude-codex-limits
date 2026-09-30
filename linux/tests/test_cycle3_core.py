"""Final core review regressions; isolated files and the shared fake services only."""

if __package__:
    from . import _isolate  # noqa: F401
    from . import _sync_env as env
else:
    import _isolate  # noqa: F401
    import _sync_env as env

import contextlib
import os
import threading
import time
from unittest.mock import patch

from ccl import common, sync, vault


class TestVaultCopies(env.SyncEnv):
    # 1: publication leaves exactly one live copy, across both backend transitions.
    def test_repeated_writes_and_backend_transitions(self):
        self.st().update(tokenGeneration="")
        for backends in ((True, True), (False, False), (True, False), (False, True)):
            with self.subTest(backends=backends), common.file_lock("sync"):
                for use_ss in backends:
                    token = env.make_token()
                    failure = (contextlib.nullcontext() if use_ss else
                               patch.object(self.ss, "set", side_effect=RuntimeError("write unavailable")))
                    with failure:
                        backend = vault.write(token)
                    self.assertEqual(backend, "secret-service" if use_ss else "file")
                    self.assertEqual(len(self.ss.items) + int(os.path.exists(common.TOKEN_FILE_PATH)), 1)
                    self.assertEqual(vault.read()[0], token)
                self.assertTrue(vault.delete())
                self.assertEqual(self.ss.items, {})
                self.assertFalse(os.path.exists(common.TOKEN_FILE_PATH))
                self.assertFalse(sync.delete_pending())
        self.assertNotIn("", self.ss.deleted)

    def test_ss_to_file_retires_previous_ss_item(self):
        old = self.sign_in()
        with patch.object(self.ss, "set", side_effect=RuntimeError("write failed")):
            with common.file_lock("sync"):
                self.assertEqual(vault.write(env.make_token()), "file")
        self.assertIn(old[0], self.ss.deleted)
        self.assertEqual(self.ss.items, {})
        self.assertTrue(os.path.exists(common.TOKEN_FILE_PATH))
        self.assertTrue(sync.logout())
        self.assertFalse(os.path.exists(common.TOKEN_FILE_PATH))

    def test_failed_previous_delete_is_deduplicated_and_retried(self):
        old = self.sign_in()
        observed = []
        def fail_delete(g):
            observed.append(vault.active(self.st()))
            return False
        with common.file_lock("sync"):
            with patch.object(self.ss, "delete", side_effect=fail_delete):
                vault.write(env.make_token())
                current = vault.active(self.st())
                self.assertNotEqual(old, current)
                self.assertEqual(observed, [current], "delete happens after publication")
                self.assertFalse(vault.delete_ref(old))
                self.assertEqual(self.st().get("tokenDeletePending"), [list(old)])
            vault.write(env.make_token())
        self.assertFalse(sync.delete_pending())
        self.assertEqual(len(self.ss.items), 1)

    def test_publication_excludes_current_reference_from_pending_cleanup(self):
        self.st().update(tokenGeneration="")
        with common.file_lock("sync"):
            ref = vault.store(self.token)
            self.st().update(tokenDeletePending=[list(ref), list(ref), ["", None]])
            vault.publish(ref)
        self.assertEqual(self.ss.deleted, [])
        self.assertEqual(vault.read(), (self.token, "secret-service"))
        self.assertFalse(sync.delete_pending())

    def test_failed_ss_store_remembers_attempt_before_fallback_publication(self):
        for failure in ("exception", "mismatch"):
            with self.subTest(failure=failure), common.file_lock("sync"):
                def failed_set(token, generation):
                    self.ss.items[generation] = token if failure == "exception" else "wrong"
                    if failure == "exception":
                        raise RuntimeError("reply lost")
                with patch.object(self.ss, "set", side_effect=failed_set):
                    ref = vault.store(self.token)
                self.assertEqual(ref[1], "file")
                pending = self.st().get("tokenDeletePending")
                self.assertEqual(pending, [[next(iter(self.ss.items)), "secret-service"], list(ref)])
                vault.publish(ref)
                self.assertEqual(self.ss.items, {})
                self.assertFalse(sync.delete_pending())
                self.assertTrue(vault.delete())

    def test_late_create_deletes_on_original_connection_and_spares_new_login(self):
        self.ss.hang_set = self.ss.event()
        cleaned = threading.Event()
        original_delete = self.ss.delete
        def deleted(generation):
            result = original_delete(generation)
            cleaned.set()
            return result
        with common.file_lock("sync"):
            ref = vault.store(self.token)
            orphan = self.st().get("tokenDeletePending")[0][0]
            self.assertEqual(ref[1], "file")
            vault.publish(ref)
        self.ss.hang_set = None
        new = env.make_token()
        self.sign_in(new)
        new_ref = vault.active(self.st())
        cleaned.clear()
        self.ss.delete = deleted
        with patch.object(vault, "_ss", side_effect=AssertionError("late cleanup must reuse its connection")):
            self.ss._events[0].set()
            self.assertTrue(cleaned.wait(3))
        self.assertNotIn(orphan, self.ss.items)
        self.assertEqual(self.ss.items, {new_ref[0]: new})
        self.assertFalse(os.path.exists(common.TOKEN_FILE_PATH))
        self.assertTrue(sync.logout())
        self.assertEqual(self.ss.items, {})

    def test_timeout_during_verification_also_cleans_late_write(self):
        release = self.ss.event()
        cleaned = threading.Event()
        original_get, original_delete = self.ss.get, self.ss.delete
        def blocked_get(generation):
            release.wait(3)
            return original_get(generation)
        def deleted(generation):
            result = original_delete(generation)
            cleaned.set()
            return result
        with patch.object(self.ss, "get", side_effect=blocked_get):
            with common.file_lock("sync"):
                ref = vault.store(self.token)
            self.assertEqual(ref[1], "file")
            self.ss.delete = deleted
            release.set()
            self.assertTrue(cleaned.wait(3))
        self.assertEqual(self.ss.items, {})
        with common.file_lock("sync"):
            vault.delete_ref(ref)
            self.assertTrue(vault.delete())

    # 12: public APIs accept both forms and never address a newer generation.
    def test_public_reference_api_and_tombstone(self):
        old = self.sign_in()
        new = env.make_token()
        self.sign_in(new)
        current = vault.active(self.st())
        with common.file_lock("sync"):
            self.assertTrue(vault.delete_ref(old))
            self.assertTrue(vault.delete_ref(*old))
            self.assertTrue(vault.delete_ref("", None))
        self.assertEqual(vault.active(self.st()), current)
        self.assertEqual(vault.read(), (new, "secret-service"))
        self.assertFalse(sync.delete_pending())
        self.assertFalse(hasattr(vault, "delete_if"))
        self.assertFalse(hasattr(vault, "_active"))


class TestLoginAttempts(env.SyncEnv):
    # 4: A may finish its keyring operation after B has superseded it.
    def test_cancel_a_begin_b_late_a_cannot_publish(self):
        self.sign_in()
        before = self.state_text()
        old_items = dict(self.ss.items)
        a = sync.begin_login()
        sync.cancel_login(a)
        b = sync.begin_login()
        self.assertGreater(b, a)
        sync.cancel_login(a)
        self.assertFalse(sync.is_current(a))
        self.assertTrue(sync.is_current(b))
        self.gh.on("GET", "/user", env.resp(200, {"login": "a"}), env.resp(200, {"login": "b"}))
        with self.assertRaisesRegex(sync.LoginError, "^cancelled$"):
            sync.login_finish(env.make_token(), attempt=a)
        self.assertEqual(self.state_text(), before)
        self.assertEqual(self.ss.items, old_items)
        self.assertEqual(len(self.ss.deleted), 2)  # initial legacy retirement and cancelled A
        token_b = env.make_token()
        self.assertEqual(sync.login_finish(token_b, attempt=b), "b")
        self.assertEqual(vault.read(), (token_b, "secret-service"))
        self.assertEqual(len(self.ss.items), 1)

    def test_cancel_during_store_cleans_token(self):
        attempt = sync.begin_login()
        original_set = self.ss.set
        def cancel_in_set(token, generation):
            original_set(token, generation)
            sync.cancel_login(attempt)
        self.gh.on("GET", "/user", env.resp(200, {"login": "me"}))
        with patch.object(self.ss, "set", side_effect=cancel_in_set):
            with self.assertRaisesRegex(sync.LoginError, "^cancelled$"):
                sync.login_finish(self.token, attempt=attempt)
        self.assertEqual(self.ss.items, {})
        self.assertFalse(self.st().has("tokenGeneration"))

    def test_cancel_callback_after_file_store_preserves_active_file(self):
        vault._ss = lambda: None
        with common.file_lock("sync"):
            vault.write(self.token)
        before = self.state_text()
        original_store = vault.store
        cancelled = []
        def cancel_after_store(token):
            ref = original_store(token)
            cancelled.append(True)
            return ref
        self.gh.on("GET", "/user", env.resp(200, {"login": "new"}))
        with patch.object(vault, "store", side_effect=cancel_after_store):
            with self.assertRaisesRegex(sync.LoginError, "^cancelled$"):
                sync.login_finish(env.make_token(), cancelled=lambda: bool(cancelled))
        self.assertEqual(self.state_text(), before)
        self.assertEqual(vault.read(), (self.token, "file"))
        self.assertEqual(os.listdir(common.CONFIG_DIR), [os.path.basename(common.TOKEN_FILE_PATH)])

    def test_cancel_cleanup_failure_stays_pending(self):
        attempt = sync.begin_login()
        sync.cancel_login(attempt)
        self.gh.on("GET", "/user", env.resp(200, {"login": "me"}))
        with patch.object(self.ss, "delete", return_value=False):
            with self.assertRaisesRegex(sync.LoginError, "^cancelled$"):
                sync.login_finish(self.token, attempt=attempt)
        self.assertEqual(self.st().get("tokenDeletePending"),
                         [[next(iter(self.ss.items)), "secret-service"]])
        self.assertFalse(self.st().has("tokenGeneration"))
        self.assertTrue(sync.logout())
        self.assertEqual(self.ss.items, {})


class TestRevocationAndErrors(env.SyncEnv):
    # 5: failure remains retryable; revoked and pending are visible during DeleteItem.
    def test_revoked_persists_pending_before_delete_then_logout_retries(self):
        ref = self.sign_in()
        observed = []
        def refuse(generation):
            st = self.st()
            observed.append((st.get("revoked"), st.get("tokenDeletePending")))
            return False
        self.gh.on("GET", "/gists/g1", env.resp(401)).on("GET", "/user", env.resp(401), env.resp(401))
        with patch.object(self.ss, "delete", side_effect=refuse):
            result = self.cycle()
        self.assertEqual(observed, [(True, [list(ref)])])
        self.assertTrue(sync.delete_pending())
        self.assertIn("Выход не завершён", result.error)
        self.assertTrue(sync.logout())
        self.assertFalse(sync.delete_pending())
        self.assertEqual(self.ss.items, {})

    def test_successful_revoke_removes_pending(self):
        self.sign_in()
        self.gh.on("GET", "/gists/g1", env.resp(401)).on("GET", "/user", env.resp(401), env.resp(401))
        self.cycle()
        self.assertTrue(self.st().get("revoked"))
        self.assertFalse(sync.delete_pending())
        self.assertEqual(self.ss.items, {})

    # 6: an operational read failure is never a missing token, even if reconnect works.
    def test_unreachable_read_with_reachable_service_is_not_signed_out(self):
        self.sign_in()
        with patch.object(self.ss, "get", side_effect=RuntimeError("read failed")):
            result = self.cycle()
        self.assertEqual(result.skipped, "unreachable")
        self.assertIn("недоступно", result.error)
        self.assertNotIn("не найден", self.st().get("lastError"))
        self.assertEqual(self.gh.calls, [])
        self.assertEqual(self.st().get("login"), "me")

    def test_timeout_and_locked_never_report_missing_token(self):
        self.sign_in()
        for backend in ("timeout", "locked", "unreachable"):
            with self.subTest(backend=backend), patch.object(vault, "read", return_value=(None, backend)):
                result = self.cycle()
                self.assertNotEqual(result.skipped, "signed-out")
                self.assertNotIn("не найден", self.st().get("lastError"))

    # 7: the public flag and both translations describe incomplete sign-out.
    def test_logout_pending_text_ru_en_and_retry(self):
        messages = {
            "ru": "Выход не завершён: хранилище не ответило, токен мог остаться — повторите выход",
            "en": "Sign-out isn't complete: the keyring didn't answer, the token may still be stored — sign out again",
        }
        for lang, expected in messages.items():
            with self.subTest(lang=lang):
                common.settings().set("lang", lang)
                self.sign_in()
                with patch.object(self.ss, "delete", return_value=False):
                    self.assertFalse(sync.logout())
                self.assertTrue(sync.delete_pending())
                self.assertEqual(self.st().get("lastError"), expected)
                self.assertTrue(sync.logout())
                self.assertFalse(sync.delete_pending())
                self.assertIsNone(self.st().get("lastError"))


class TestWarningThreshold(env.SyncEnv):
    # 2: warning needs an error after the threshold, not merely after last success.
    def test_sleep_and_threshold_boundary(self):
        self.st().update(login="me", lastOkAt=1000, lastError="error")
        for error_at, warns in ((1001, False), (1000 + sync.STALE_AFTER, False),
                                (1001 + sync.STALE_AFTER, True)):
            with self.subTest(error_at=error_at):
                self.st().update(lastErrorAt=error_at)
                self.assertEqual(bool(sync.warning(now=10000, require_attempt=False)), warns)
        self.assertIsNone(sync.warning(now=10000))

    def test_gui_error_must_belong_to_this_process(self):
        self.st().update(login="me", pushedAt=1000, lastError="error", lastErrorAt=8000)
        sync._first_attempt_at = 9000
        self.assertIsNone(sync.warning(now=10000))
        self.assertIsNotNone(sync.warning(now=10000, require_attempt=False))
        self.st().update(lastErrorAt=9000)
        self.assertIsNotNone(sync.warning(now=10000))

    def test_never_succeeded_cli_does_not_require_process_attempt(self):
        self.st().update(login="me", lastError="error")
        self.assertIsNone(sync.warning())
        self.assertIn("не работает", sync.warning(require_attempt=False))
        sync._first_attempt_at = time.time()
        self.assertIn("не работает", sync.warning())

    def test_first_attempt_timestamp_is_start_and_is_not_reset(self):
        self.sign_in()
        self.gh.on("GET", "/gists/g1", env.resp(500), env.resp(500))
        before = time.time()
        self.cycle()
        first = sync._first_attempt_at
        self.assertGreaterEqual(first, before)
        self.assertLessEqual(first, self.st().get("lastErrorAt"))
        self.cycle()
        self.assertEqual(sync._first_attempt_at, first)


class TestHostileJSON(env.SyncEnv):
    # 8: pathological depth is dropped at all three JSON entry points.
    def test_depth_100000_is_skipped_but_neighbor_is_merged(self):
        deep = "[" * 100000 + "0" + "]" * 100000
        result = sync.merge({"machine-deep.json": deep, "machine-good.json": env.machine_json("good", input_=17)}, "me")
        self.assertEqual([m["id"] for m in result["machines"]], ["good"])
        self.assertEqual(result["days"]["claude"][common.today_key()]["claude-opus-5-5"]["input"], 17)
        self.assertIsNone(common.Resp(200, deep.encode()).json())
        path = os.path.join(self.tmp, "deep.json")
        common.write_atomic(path, deep)
        default = {"default": True}
        self.assertIs(common.read_json(path, default), default)

    def test_nested_counts_are_skipped_without_recursive_walk(self):
        deep = "[" * 100 + "0" + "]" * 100
        content = ('{"schema":1,"machine":{"id":"deep"},"days":{"claude":{"today":'
                   '{"bad":{"input":' + deep + '},"good":{"input":9}}}}}')
        result = sync.merge({"machine-deep.json": content}, "me")
        self.assertEqual(list(result["days"]["claude"]["today"]), ["good"])

    # 11: boolean, float and string schemas cannot sneak through Python equality.
    def test_only_integer_schema_is_accepted(self):
        for schema in (True, False, 1.0, "1", None, 2):
            with self.subTest(schema=schema):
                result = sync.merge({"machine-bad.json": env.machine_json("bad", schema=schema),
                                     "machine-good.json": env.machine_json("good")}, "me")
                self.assertEqual([m["id"] for m in result["machines"]], ["good"])
