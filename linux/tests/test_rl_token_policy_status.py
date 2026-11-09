"""Expired Claude preflight publishes the existing v1.1 auth status, without a poll.

Uses PubEnv: temporary CLI/state files, fake GitHub/providers, no real keyring or network.
"""

if __package__:
    from . import _rl_env as rl
else:
    import _rl_env as rl

import copy
import json
import unittest
from unittest import mock

from ccl import common, limits


class TestTokenPolicyStatus(rl.PubEnv):
    def credentials(self, **overrides):
        oauth = dict(accessToken="fixture-access", refreshToken="fixture-refresh",
                     expiresAt=int((self.clock() - 3600) * 1000))
        oauth.update(overrides)
        self.write_file(common.CLAUDE_CREDENTIALS, json.dumps({"claudeAiOauth": oauth}))

    def checked_tick(self):
        with mock.patch.object(common, "http") as http:
            result = self.tick()
        http.assert_not_called()
        self.assertIsNone(result["error"], result)
        return result

    def assert_expired(self):
        record = self.published()
        self.assertIsNotNone(record)
        self.assertEqual(record["status"], "expired")
        self.assertEqual(record["expiredReason"], "signin_required")
        return record

    def test_expired_token_publishes_without_provider_or_poll_budget(self):
        self.credentials()
        result = self.checked_tick()
        self.assertEqual(result["skipped"]["claude"], "token_policy")
        self.assertEqual(result["polled"], [])
        self.assertEqual(self.providers.calls(), [])
        record = self.assert_expired()
        for key in ("attemptAt", "asOf", "windows"):
            self.assertNotIn(key, record)
        poll = self.state()["autoPollState"]["claude"]
        self.assertFalse(poll["last_attempt"])
        self.assertFalse(poll["failed"])

    def test_missing_access_or_expiry_publishes_same_status(self):
        for overrides in ({"accessToken": ""}, {"accessToken": None}, {"expiresAt": None}):
            with self.subTest(overrides=overrides):
                self.credentials(**overrides)
                self.checked_tick()
                self.assert_expired()
                self.assertEqual(self.providers.calls(), [])
                self.clock.advance(600)

    def test_previous_snapshot_and_poll_budget_survive_without_token_write(self):
        self.checked_tick()
        previous = copy.deepcopy(self.published())
        poll = copy.deepcopy(self.state()["autoPollState"]["claude"])
        self.credentials()
        with open(common.CLAUDE_CREDENTIALS, "rb") as stream:
            credentials = stream.read()
        calls = len(self.providers.calls())
        # Not due yet: the auth status must still be published immediately.
        self.clock.advance(60)
        self.checked_tick()
        record = self.assert_expired()
        for key in ("asOf", "windows", "plan", "attemptAt", "schedule"):
            self.assertEqual(record.get(key), previous.get(key), key)
        self.assertEqual(self.state()["autoPollState"]["claude"], poll)
        self.assertEqual(len(self.providers.calls()), calls)
        with open(common.CLAUDE_CREDENTIALS, "rb") as stream:
            self.assertEqual(stream.read(), credentials)

    def test_unchanged_status_deduplicates_across_restart_and_keeps_heartbeat(self):
        self.credentials()
        self.checked_tick()
        revisions = len(self.gist.revs[self.my_file()])
        record = copy.deepcopy(self.published())
        self.restart()
        self.clock.advance(300)
        self.checked_tick()
        self.assertEqual(len(self.gist.revs[self.my_file()]), revisions)
        self.clock.advance(300)
        self.checked_tick()
        self.assertEqual(len(self.gist.revs[self.my_file()]), revisions + 1)
        self.assertEqual(self.published(), record)
        self.assertEqual(self.providers.calls(), [])

    def test_success_after_unblock_clears_auth_status(self):
        self.checked_tick()
        self.credentials()
        self.clock.advance(60)
        self.checked_tick()
        self.assert_expired()
        self.credentials(expiresAt=int((self.clock() + 86400) * 1000))
        self.providers.default = lambda product, now: rl.reading(now, session=55)
        self.clock.advance(3600)
        result = self.checked_tick()
        self.assertIn("claude", result["polled"])
        record = self.published()
        self.assertEqual(record["status"], "ok")
        self.assertNotIn("expiredReason", record)
        self.assertEqual(record["asOf"], rl.iso(self.clock()))
        self.assertEqual(record["windows"]["session"]["pct"], 55)

    def test_guarded_policy_keeps_normal_provider_path(self):
        self.write_settings(publisher=False, credential_write="guarded")
        self.assertEqual(common.credential_write(), "guarded")
        self.credentials()
        result = self.checked_tick()
        self.assertIn("claude", result["polled"])
        self.assertNotEqual(result["skipped"].get("claude"), "token_policy")
        self.assertEqual(len(self.providers.calls("claude")), 1)
        self.assertEqual(self.published()["status"], "ok")
        self.assertNotIn("expiredReason", self.published())


if __name__ == "__main__":
    unittest.main()
