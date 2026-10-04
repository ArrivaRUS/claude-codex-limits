"""Transaction/restart fault model; memory persistence is not OS fsync proof."""
if __package__:
    from . import _isolate
    from ._auth_env import Fault, Reply, InjectedCrash, IsolatedAuthCase, StoreRef, assert_nonsecret
else:
    import _isolate
    from _auth_env import Fault, Reply, InjectedCrash, IsolatedAuthCase, StoreRef, assert_nonsecret

from ccl import auth


class TestAuthDurability(IsolatedAuthCase):
    def test_restart_recovers_each_recoverable_checkpoint(self):
        points = ("before_intent", "after_intent", "after_request_started", "after_stage",
                  "after_readback", "before_identity", "after_identity", "before_publish",
                  "after_publish", "before_retire", "after_retire")
        for backend in ("secret-service", "file"):
            for point in points:
                with self.subTest(backend=backend, checkpoint=point):
                    h = self.harness(auth)
                    owner, before = h.login(backend=backend)
                    h.due()
                    h.world.checkpoints.at(point, InjectedCrash())
                    with self.assertRaises(InjectedCrash):
                        owner.ensure_access()
                    consumed = h.world.ledger.counts["issuer.refresh_consumed"]
                    h.world.manifest = h.world.manifest.reopen()
                    result = h.owner().ensure_access("restart")
                    h.protected_read(result)
                    self.assertEqual(h.world.ledger.counts["issuer.refresh_consumed"], 1)
                    self.assertEqual(h.world.ledger.counts["issuer.refresh_request"], 1)
                    if consumed:
                        self.assertEqual(h.world.ledger.counts["issuer.refresh_consumed"], consumed)
                    self.assertNotEqual(result.generation, before.generation)
                    manifest = h.world.manifest.read()
                    self.assertIsNone(manifest["transition"])
                    self.assertEqual(manifest["active"]["backend"], backend)
                    assert_nonsecret(manifest)

    def test_response_loss_before_stage_is_honest_bounded_unknown(self):
        for point in ("after_response", "after_parse"):
            h = self.harness(auth)
            owner, _ = h.login()
            h.due()
            h.world.checkpoints.at(point, InjectedCrash())
            with self.assertRaises(InjectedCrash):
                owner.ensure_access()
            result = h.owner().ensure_access("restart")
            self.assertEqual(result.kind, "actionRequired")
            for _ in range(5):
                h.world.clock.advance(600)
                self.assertEqual(h.owner().ensure_access().kind, "actionRequired")
            self.assertEqual(h.world.ledger.counts["issuer.refresh_request"], 2)
            self.assertEqual(h.world.ledger.counts["issuer.refresh_consumed"], 1)
            self.assertEqual(h.world.ledger.counts["device_flow"], 1)

    def test_unknown_budget_persisted_before_additional_attempt(self):
        h = self.harness(auth)
        owner, _ = h.login()
        h.due()
        h.world.issuer.faults.queue("refresh", Fault("after_accept"))
        self.assertEqual(owner.ensure_access().kind, "temporary")
        h.world.clock.advance(600)
        h.world.checkpoints.at("after_request_started", InjectedCrash())
        with self.assertRaises(InjectedCrash):
            h.owner().ensure_access()
        manifest = h.world.manifest.read()
        self.assertEqual(manifest["transition"]["recoveryAttempts"], 1)
        self.assertEqual(h.owner().ensure_access().kind, "actionRequired")
        self.assertEqual(h.world.ledger.counts["issuer.refresh_request"], 1)
        self.assertEqual(h.world.ledger.counts["device_flow"], 1)

    def test_repeated_proven_not_sent_does_not_spend_unknown_budget(self):
        h = self.harness(auth)
        owner, _ = h.login()
        h.due()
        for _ in range(5):
            h.world.issuer.faults.queue("refresh", Fault("before_send"))
            self.assertEqual(owner.ensure_access().kind, "temporary")
            manifest = h.world.manifest.read()
            self.assertEqual(manifest["transition"]["phase"], "prepared")
            self.assertEqual(manifest["transition"]["recoveryAttempts"], 0)
            h.world.clock.advance(600)
            owner = h.owner()
        self.assertEqual(h.world.ledger.counts["issuer.refresh_request"], 0)
        h.protected_read(owner.ensure_access())
        self.assertEqual(h.world.ledger.counts["issuer.refresh_consumed"], 1)

    def test_identity_failure_keeps_durable_candidate_until_recovery(self):
        h = self.harness(auth)
        owner, _ = h.login()
        h.due()
        h.world.issuer.faults.queue("user", Fault("reply", Reply(503, {})))
        self.assertEqual(owner.ensure_access().kind, "temporary")
        transition = h.world.manifest.read()["transition"]
        candidate = StoreRef(transition["to"]["generation"], transition["to"]["backend"])
        self.assertIn(candidate, h.world.store.items)
        payload = h.world.store.items[candidate]
        h.world.clock.advance(600)
        result = h.owner().ensure_access()
        h.protected_read(result)
        self.assertEqual(result.generation, candidate.generation)
        self.assertTrue(h.world.store.items[candidate] == payload)
        self.assertEqual(h.world.ledger.counts["issuer.refresh_request"], 1)

    def test_late_stage_timeout_to_ref_recovery_no_file_fallback(self):
        h = self.harness(auth)
        owner, _ = h.login()
        h.due()
        h.world.checkpoints.at("after_parse", lambda: h.world.store.faults.queue("write", Fault("late_timeout")))
        self.assertEqual(owner.ensure_access().kind, "temporary")
        manifest = h.world.manifest.read()
        ref = StoreRef(manifest["transition"]["to"]["generation"], "secret-service")
        self.assertNotIn(ref, h.world.store.items)
        self.assertEqual(len(h.world.store.late_writes), 1)
        h.world.store.late_writes[0].release()
        self.assertIn(ref, h.world.store.items)
        h.world.clock.advance(600)
        result = h.owner().ensure_access()
        h.protected_read(result)
        self.assertEqual(result.generation, ref.generation)
        self.assertEqual(h.world.ledger.counts["issuer.refresh_request"], 1)
        self.assertTrue(all(item.backend == "secret-service" for item in h.world.store.items))

    def test_probe_is_distinct_and_failed_probe_does_not_spend_refresh(self):
        h = self.harness(auth)
        owner, before = h.login()
        h.due()
        h.world.store.faults.queue("write", Fault("late_timeout"))
        self.assertEqual(owner.ensure_access().kind, "temporary")
        manifest = h.world.manifest.read()
        transition = manifest["transition"]
        generations = {before.generation, transition["to"]["generation"], transition["probe"]["generation"]}
        self.assertEqual(len(generations), 3)
        self.assertEqual(h.world.ledger.counts["issuer.refresh_request"], 0)
        h.world.store.late_writes[0].release()
        h.world.clock.advance(600)
        h.protected_read(h.owner().ensure_access())

    def test_atomic_publish_failure_keeps_candidate_and_recovers(self):
        h = self.harness(auth)
        owner, before = h.login()
        h.due()
        h.world.checkpoints.at("before_publish", lambda: h.world.manifest.faults.queue("replace", Fault("failed")))
        self.assertEqual(owner.ensure_access().kind, "temporary")
        manifest = h.world.manifest.read()
        self.assertEqual(manifest["active"]["generation"], before.generation)
        self.assertIsNotNone(manifest["transition"])
        h.protected_read(h.owner().ensure_access())
        self.assertEqual(h.world.ledger.counts["issuer.refresh_request"], 1)

    def test_identity_rename_allowed_other_user_not_published(self):
        for user_id, expected in (("1001", "ready"), ("2002", "actionRequired")):
            h = self.harness(auth)
            owner, before = h.login()
            h.due()
            h.world.issuer.faults.queue("user", Fault("reply", Reply(200, {"id": user_id, "login": "renamed"})))
            result = owner.ensure_access()
            self.assertEqual(result.kind, expected)
            manifest = h.world.manifest.read()
            if expected == "ready":
                self.assertEqual(manifest["login"], "renamed")
                self.assertEqual(manifest["userID"], "1001")
                h.protected_read(result)
            else:
                self.assertEqual(manifest["active"]["generation"], before.generation)
                self.assertIsNotNone(manifest["transition"])

    def test_manifest_error_and_cleanup_error_do_not_remove_healthy_auth(self):
        h = self.harness(auth)
        owner, before = h.login()
        manifest = h.world.manifest.read()
        h.world.manifest.faults.queue("read", Fault("failed"))
        self.assertEqual(owner.ensure_access().kind, "temporary")
        self.assertEqual(h.world.manifest.read(), manifest)
        h.due()
        h.world.checkpoints.at("before_retire", lambda: h.world.store.faults.queue("delete", Fault("locked")))
        result = owner.ensure_access()
        h.protected_read(result)
        self.assertNotEqual(result.generation, before.generation)
        self.assertTrue(h.world.manifest.read()["cleanupRefs"])
        h.protected_read(h.owner().ensure_access())
        self.assertEqual(h.world.manifest.read()["cleanupRefs"], [])

    def test_partial_candidate_not_published_or_mixed(self):
        for missing in ("access_token", "refresh_token"):
            h = self.harness(auth)
            owner, before = h.login()
            h.due()
            def strip_response():
                # Issuer fault supplies a new issuance, independently of the client.
                new = h.world.issuer._consume(h.world.issuer.issuances[0].refresh)
                wire = new.wire()
                wire.pop(missing)
                h.world.issuer.faults.queue("refresh", Fault("reply", Reply(200, wire)))
            h.world.checkpoints.at("after_request_started", strip_response)
            self.assertEqual(owner.ensure_access().kind, "actionRequired")
            manifest = h.world.manifest.read()
            self.assertEqual(manifest["active"]["generation"], before.generation)
            ref = manifest["transition"]["to"]
            candidate = auth.decode_credential(h.world.store.items[StoreRef(ref["generation"], ref["backend"])])
            self.assertEqual(candidate["kind"], "incomplete")
            self.assertIsNone(candidate["accessToken" if missing == "access_token" else "refreshToken"])
            self.assertEqual(h.world.ledger.counts["device_flow"], 1)

    def test_ambiguous_retry_then_refusal_never_reopens_spent_budget(self):
        for status in (429, 503):
            h = self.harness(auth)
            owner, _ = h.login()
            h.due()
            h.world.issuer.faults.queue("refresh", Fault("after_accept"),
                                       Fault("reply", Reply(status, {}, {"Retry-After": "60"})))
            self.assertEqual(owner.ensure_access().kind, "temporary")
            h.world.clock.advance(600)
            self.assertEqual(h.owner().ensure_access().kind, "temporary")
            self.assertEqual(h.world.ledger.counts["issuer.refresh_request"], 2)
            self.assertEqual(h.world.manifest.read()["transition"]["recoveryAttempts"], 1)
            h.world.clock.advance(600)
            self.assertEqual(h.owner().ensure_access().kind, "actionRequired")
            self.assertEqual(h.world.ledger.counts["issuer.refresh_request"], 2)
            self.assertEqual(h.world.ledger.counts["device_flow"], 1)

    def test_inflight_candidate_writer_blocks_blind_retry_and_cleanup(self):
        h = self.harness(auth)
        owner, _ = h.login()
        h.due()
        h.world.checkpoints.at("after_parse", lambda: h.world.store.faults.queue("write", Fault("late_timeout")))
        self.assertEqual(owner.ensure_access().kind, "temporary")
        late = h.world.store.late_writes[0]
        h.world.clock.advance(600)
        self.assertEqual(h.owner().ensure_access().kind, "temporary")
        self.assertEqual(h.world.ledger.counts["issuer.refresh_request"], 1)
        manifest = h.world.manifest.read()
        self.assertEqual(manifest["transition"]["to"]["generation"], late.ref.generation)
        late.release()
        h.world.clock.advance(600)
        h.protected_read(h.owner().ensure_access())
