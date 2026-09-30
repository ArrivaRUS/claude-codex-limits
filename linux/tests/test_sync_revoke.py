"""Variant «a» of docs/sync-protocol.md → Errors: a 401 on the gist revokes the sign-in only after
two more 401s from GET /user with the same captured token and generation. Offline, fake keyring."""

if __package__:
    from . import _sync_env as env
else:
    import _sync_env as env

import time
import unittest

from ccl import sync, vault

T = env.resp


def tearDownModule():
    env.assert_real_files_untouched()


class TestRevokeConfirmation(env.SyncEnv):
    def setUp(self):
        super().setUp()
        self.active = self.sign_in()

    # Scenario 1
    def test_gist_401_then_user_200_keeps_token(self):
        self.gh.on("GET", "/gists/g1", T(401)).on("GET", "/user", T(200, {"login": "me"}))
        res = self.cycle()
        self.assertFalse(res.ok)
        self.assertEqual(self.gh.urls(), [("GET", "/gists/g1"), ("GET", "/user")])
        st = self.st()
        self.assertFalse(st.get("revoked"))
        self.assertEqual(vault.read(), (self.token, "secret-service"))
        self.assertIn("вход подтверждён", st.get("lastError"))
        self.assertEqual(self.sleeps, [])

    # Scenario 2
    def test_three_401_revoke_only_the_captured_generation(self):
        other = env.make_token()
        self.ss.items["orphan-gen"] = other          # an unrelated generation must survive
        self.ss.items["legacy"] = other
        flag_at_delete = []
        self.ss.on_delete = lambda g: flag_at_delete.append(sync.sync_state().get("revoked"))
        self.gh.on("GET", "/gists/g1", T(401)).on("GET", "/user", T(401), T(401))
        res = self.cycle()
        self.assertFalse(res.ok)
        self.assertEqual(self.gh.urls(), [("GET", "/gists/g1"), ("GET", "/user"), ("GET", "/user")])
        self.assertTrue(all(c.auth == "Bearer " + self.token for c in self.gh.calls))
        self.assertEqual(self.sleeps, [0], "exactly one recheck pause")
        st = self.st()
        self.assertIs(st.get("revoked"), True)
        self.assertIsNone(st.get("gistId"))
        self.assertEqual(self.ss.deleted, [self.active[0]])
        self.assertEqual(flag_at_delete, [True], "revoked flag is persisted before the delete")
        self.assertNotIn(self.active[0], self.ss.items)
        self.assertEqual(self.ss.items["orphan-gen"], other)
        self.assertEqual(self.ss.items["legacy"], other)
        self.assertIn("отозван", st.get("lastError"))
        # the next cycle makes no request at all
        self.gh.calls.clear()
        res = self.cycle()
        self.assertEqual(res.skipped, "revoked")
        self.assertEqual(self.gh.calls, [])

    # Scenario 3
    def test_third_answer_not_401_keeps_token(self):
        now = time.time()
        cases = [
            ("403 plain", T(403), False),
            ("403 rate limit", T(403, headers={"x-ratelimit-remaining": "0", "x-ratelimit-reset": str(int(now + 600))}), True),
            ("403 retry-after", T(403, headers={"retry-after": "60"}), True),
            ("429", T(429, headers={"retry-after": "120"}), True),
            ("500", T(500), False),
            ("502", T(502), False),
            ("0 network", common_resp0(), False),
        ]
        for label, third, backoff in cases:
            with self.subTest(label):
                self.st().update(revoked=False, backoffUntil=None, lastError=None, lastErrorAt=None)
                self.gh.calls.clear()
                self.gh.on("GET", "/gists/g1", T(401)).on("GET", "/user", T(401), third)
                res = self.cycle()
                self.assertFalse(res.ok)
                self.assertEqual(len(self.gh.calls), 3)
                st = self.st()
                self.assertFalse(st.get("revoked"))
                self.assertEqual(vault.read(), (self.token, "secret-service"))
                self.assertIn("проверка входа не прошла", st.get("lastError"))
                self.assertIsNotNone(st.get("lastErrorAt"))
                if backoff:
                    until = float(st.get("backoffUntil"))
                    self.assertGreater(until, time.time() + 30)
                    self.assertLessEqual(until, time.time() + 3600 + 1)
                    self.gh.calls.clear()
                    self.assertEqual(self.cycle().skipped, "backoff")
                    self.assertEqual(self.gh.calls, [])
                else:
                    self.assertIsNone(st.get("backoffUntil"))
                if label == "403 plain":
                    self.assertIn("доступ запрещён (403)", st.get("lastError"))

    def test_first_user_answer_not_401_stops_confirmation(self):
        for status in (500, 0, 429):
            with self.subTest(status=status):
                self.st().update(backoffUntil=None)
                self.gh.calls.clear()
                self.gh.on("GET", "/gists/g1", T(401)).on("GET", "/user", T(status))
                self.cycle()
                self.assertEqual(self.gh.urls(), [("GET", "/gists/g1"), ("GET", "/user")])
                self.assertEqual(self.sleeps, [])
                self.assertFalse(self.st().get("revoked"))
                self.assertEqual(vault.read()[0], self.token)

    def test_retry_after_is_capped_at_one_hour(self):
        self.gh.on("GET", "/gists/g1", T(429, headers={"retry-after": "999999"}))
        self.cycle()
        until = float(self.st().get("backoffUntil"))
        self.assertLessEqual(until, time.time() + 3600 + 1)
        self.assertGreater(until, time.time() + 3500)

    def test_non_401_gist_error_never_starts_confirmation(self):
        self.gh.on("GET", "/gists/g1", T(403))
        self.cycle()
        self.assertEqual(self.gh.urls(), [("GET", "/gists/g1")])
        self.assertIsNone(self.st().get("backoffUntil"), "403 without rate-limit signals: no pause")

    # Scenario 4
    def test_generation_changes_during_pause_no_revoke(self):
        new = env.make_token()

        def relogin(_delay):
            vault.write(new)                 # a new sign-in lands while the cycle sleeps
        sync._sleep = relogin
        self.gh.on("GET", "/gists/g1", T(401)).on("GET", "/user", T(401))
        res = self.cycle()
        self.assertFalse(res.ok)
        self.assertEqual(self.gh.urls(), [("GET", "/gists/g1"), ("GET", "/user")], "no second /user")
        st = self.st()
        self.assertFalse(st.get("revoked"))
        self.assertEqual(self.ss.deleted, [])
        self.assertEqual(vault.read(), (new, "secret-service"))
        self.assertIn("изменился", st.get("lastError"))

    def test_generation_changes_before_marking_revoked(self):
        new = env.make_token()

        def second_user(url, method, headers, body):
            vault.write(new)                 # changed between the recheck and _revoked
            return T(401)
        self.gh.on("GET", "/gists/g1", T(401)).on("GET", "/user", T(401), second_user)
        self.cycle()
        st = self.st()
        self.assertFalse(st.get("revoked"))
        self.assertEqual(self.ss.deleted, [])
        self.assertEqual(vault.read(), (new, "secret-service"))


def common_resp0():
    return T(0)


if __name__ == "__main__":
    unittest.main()
