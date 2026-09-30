"""Sign-in / sign-out serialization and identity check (docs/sync-protocol.md → Device Flow 4–5).
Offline, fake keyring."""

if __package__:
    from . import _sync_env as env
else:
    import _sync_env as env

import os
import unittest

from ccl import common, sync, vault

T = env.resp


def tearDownModule():
    env.assert_real_files_untouched()


class TestBusyLock(env.SyncEnv):
    # Scenario 9
    def test_login_with_busy_lock(self):
        self.gh.on("GET", "/user", T(200, {"login": "me"}))
        before = self.state_text()
        with common.file_lock("sync") as held:           # another process is syncing
            self.assertTrue(held)
            with self.assertRaises(sync.LoginError) as cm:
                sync.login_finish(self.token)
        self.assertIn("Синхронизация занята", str(cm.exception))
        self.assertEqual(self.state_text(), before)
        self.assertEqual(self.ss.items, {})
        self.assertFalse(os.path.exists(common.TOKEN_FILE_PATH))

    def test_logout_with_busy_lock(self):
        generation, _ = self.sign_in()
        before = self.state_text()
        with common.file_lock("sync") as held:
            self.assertTrue(held)
            with self.assertRaises(sync.LoginError) as cm:
                sync.logout()
        self.assertIn("Синхронизация занята", str(cm.exception))
        self.assertEqual(self.state_text(), before)
        self.assertIn(generation, self.ss.items)
        self.assertEqual(vault.read(), (self.token, "secret-service"))


class TestLoginFinish(env.SyncEnv):
    # Scenario 10
    def assertNothingStored(self):
        self.assertEqual(self.ss.items, {})
        self.assertFalse(os.path.exists(common.TOKEN_FILE_PATH))
        self.assertIsNone(self.st().get("login"))
        self.assertFalse(self.st().has("tokenGeneration"))

    def test_user_not_200_or_no_login(self):
        cases = [("500", T(500)), ("0", T(0)), ("401", T(401)), ("403", T(403)),
                 ("200 empty login", T(200, {"login": ""})), ("200 blank login", T(200, {"login": "   "})),
                 ("200 no login", T(200, {"id": 1})), ("200 login not str", T(200, {"login": 5})),
                 ("200 not json", T(200, raw=b"<html>")), ("200 list", T(200, ["me"]))]
        for label, r in cases:
            with self.subTest(label):
                self.gh.on("GET", "/user", r)
                with self.assertRaises(sync.LoginError):
                    sync.login_finish(self.token)
                self.assertNothingStored()

    def test_cancel_while_user_in_flight(self):
        cancelled = []

        def user(url, method, headers, body):
            cancelled.append(True)                       # user pressed «Отмена» meanwhile
            return T(200, {"login": "me"})
        self.gh.on("GET", "/user", user)
        with self.assertRaises(sync.LoginError) as cm:
            sync.login_finish(self.token, cancelled=lambda: bool(cancelled))
        self.assertEqual(str(cm.exception), "cancelled")
        self.assertNothingStored()

    def test_cancel_after_access_token(self):
        cancelled = []

        def access_token(url, method, headers, body):
            cancelled.append(True)
            return T(200, {"access_token": self.token})
        self.gh.on("POST", "https://github.com/login/oauth/access_token", access_token)
        dev = {"device_code": "dc", "interval": 0.001, "expires_in": 30}
        with self.assertRaises(sync.LoginError) as cm:
            sync.device_poll(dev, cancelled=lambda: bool(cancelled), sleep=lambda s: None)
        self.assertEqual(str(cm.exception), "cancelled")
        self.assertNothingStored()
        self.assertTrue(all(c.auth is None for c in self.gh.calls))

    def test_success_stores_and_clears_revoked(self):
        self.st().update(revoked=True, lastError="old")
        self.gh.on("GET", "/user", T(200, {"login": " me "}))
        self.assertEqual(sync.login_finish(self.token), "me")
        st = self.st()
        self.assertEqual(st.get("login"), "me")
        self.assertFalse(st.get("revoked"))
        self.assertIsNone(st.get("lastError"))
        self.assertEqual(vault.read(), (self.token, "secret-service"))


if __name__ == "__main__":
    unittest.main()
