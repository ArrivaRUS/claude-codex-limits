"""Issuance/envelope contract; never construct a real storage or HTTP adapter."""
if __package__:
    from . import _isolate
    from ._auth_env import AuthWorld, IsolatedAuthCase, assert_nonsecret
else:
    import _isolate
    from _auth_env import AuthWorld, IsolatedAuthCase, assert_nonsecret

import base64
import json
import math
from ccl import auth


class TestAuthParsing(IsolatedAuthCase):
    def setUp(self):
        super().setUp()
        self.world = AuthWorld()
        self.issued = self.world.issuer.issue()

    def parse(self, body, **kwargs):
        return auth.parse_issuance(body, "epoch-fixture", "a" * 32, self.world.clock(), **kwargs)

    def test_complete_new_pair_survives_unknown_lifetimes(self):
        for value in (None, True, False, float("nan"), float("inf"), -1, 0, "28800", 10**30):
            with self.subTest(lifetime_type=type(value).__name__):
                body = self.issued.wire()
                body.update(expires_in=value, refresh_token_expires_in=value)
                candidate = self.parse(body, require_refresh=True)
                self.assertEqual(candidate["kind"], "credential")
                self.assertIsNone(candidate["accessExpiresAt"])
                self.assertIsNone(candidate["refreshExpiresAt"])
                self.assertTrue(candidate["accessToken"] == self.issued.access)
                self.assertTrue(candidate["refreshToken"] == self.issued.refresh)

    def test_issuer_lifetimes_and_supported_boundary(self):
        candidate = self.parse(self.issued.wire(), require_refresh=True)
        self.assertEqual(candidate["accessExpiresAt"], self.issued.access_until)
        self.assertEqual(candidate["refreshExpiresAt"], self.issued.refresh_until)
        self.assertEqual(auth.lifetime(10 * 366 * 86400), 10 * 366 * 86400)
        self.assertIsNone(auth.lifetime(10 * 366 * 86400 + 1))

    def test_partial_never_inherits_old_pair(self):
        for missing in ("access_token", "refresh_token"):
            body = self.issued.wire()
            body.pop(missing)
            candidate = self.parse(body, require_refresh=True)
            self.assertEqual(candidate["kind"], "incomplete")
            self.assertIsNone(candidate["accessToken" if missing == "access_token" else "refreshToken"])
            self.assertTrue(candidate["refreshToken" if missing == "access_token" else "accessToken"] is not None)

    def test_legacy_has_no_invented_expiry_or_refresh(self):
        old = self.world.issuer.issue(legacy=True)
        candidate = self.parse(old.wire())
        self.assertEqual(candidate["kind"], "credential")
        self.assertIsNone(candidate["refreshToken"])
        self.assertIsNone(candidate["accessExpiresAt"])

    def test_malformed_tokens_and_bodies_not_active(self):
        for body in (None, [], "invalid", {"error": "bad_refresh_token"},
                     {"access_token": True}, {"access_token": "a\nb"}, {"access_token": "☃"}):
            self.assertEqual(self.parse(body, require_refresh=True)["kind"], "incomplete")

    def test_ascii_envelope_roundtrip_and_ref_binding(self):
        candidate = self.parse(self.issued.wire(), user_id="1001", login="fixture-user", require_refresh=True)
        envelope = auth.encode_credential(candidate)
        self.assertTrue(envelope.isascii())
        self.assertTrue(auth.decode_credential(envelope, {"generation": "a" * 32, "epoch": "epoch-fixture"}) == candidate)
        self.assertIsNone(auth.decode_credential(envelope, {"generation": "b" * 32}))
        self.assertIsNone(auth.decode_credential(envelope, {"generation": "a" * 32, "epoch": "other"}))

    def test_corrupt_envelope_and_nonfinite_dates_rejected(self):
        candidate = self.parse(self.issued.wire())
        for payload in ("☃", "%%%", "x" * 100001, base64.b64encode(b"[]").decode()):
            self.assertIsNone(auth.decode_credential(payload))
        for value in (True, float("nan"), float("inf")):
            obj = dict(candidate, obtainedAt=value)
            payload = base64.urlsafe_b64encode(json.dumps(obj).encode()).decode()
            self.assertIsNone(auth.decode_credential(payload))

    def test_public_state_detects_raw_and_encoded_credentials(self):
        candidate = self.parse(self.issued.wire())
        for value in (candidate, {"note": self.issued.access}, {"note": auth.encode_credential(candidate)}):
            with self.assertRaises(AssertionError):
                assert_nonsecret(value)
        assert_nonsecret({"epoch": "fixture", "kind": "ready", "retryAt": self.world.clock()})
