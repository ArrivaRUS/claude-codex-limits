"""Authorized synthetic reads, not cached login flags, prove auth lifetime."""
if __package__:
    from . import _isolate
    from ._auth_env import DAY, Fault, Reply, IsolatedAuthCase, OwnerHarness, assert_nonsecret
else:
    import _isolate
    from _auth_env import DAY, Fault, Reply, IsolatedAuthCase, OwnerHarness, assert_nonsecret

from ccl import auth


class TestAuthLifecycle(IsolatedAuthCase):
    def test_healthy_30_and_180_days_rotating_reads_and_restarts(self):
        # 10-min cadence + issuer 8h TTL + contractual 15-min lead gives a
        # renewal every 47 ticks: 91 / 551, independently specified here.
        for days, renewals in ((30, 91), (180, 551)):
            with self.subTest(days=days):
                h = self.harness(auth)
                owner, result = h.login()
                h.protected_read(result)
                ticks = days * 144
                for tick in range(1, ticks + 1):
                    h.world.clock.advance(600)
                    if tick % 144 == 0:
                        owner = h.owner()
                    h.protected_read(owner.ensure_access("maintenance"))
                counters = h.world.ledger.counts
                self.assertEqual(counters["device_flow"], 1)
                self.assertEqual(counters["issuer.refresh_request"], renewals)
                self.assertEqual(counters["issuer.refresh_consumed"], renewals)
                self.assertEqual(counters["issuer.refresh_rejected"], 0)
                self.assertEqual(counters["protected.gist_authorized"], ticks + 1)
                self.assertEqual(counters["protected.user_authorized"], renewals + 1)
                self.assertIsNone(h.world.manifest.read()["transition"])
                assert_nonsecret(owner.snapshot())
                assert_nonsecret(h.world.public_snapshot())

    def test_legacy_readonly_180_days_no_migration_or_refresh(self):
        h = self.harness(auth)
        issued = h.world.issuer.issue(legacy=True)
        legacy = auth.AuthRead("ready", {"accessToken": issued.access, "epoch": "legacy",
                                        "generation": "legacy", "login": issued.login})
        h.legacy = legacy
        owner = h.owner()
        for day in range(181):
            if day:
                h.world.clock.advance(DAY)
                owner = h.owner()
            h.protected_read(owner.ensure_access())
        counts = h.world.ledger.counts
        for name in ("refresh.attempt", "device_flow", "store.write_attempt", "manifest.replace_attempt"):
            self.assertEqual(counts[name], 0)
        self.assertEqual(counts["protected.gist_authorized"], 181)

    def test_two_and_six_week_sleep_recovers_on_first_wake_attempt(self):
        for weeks in (2, 6):
            h = self.harness(auth)
            owner, _ = h.login()
            before = h.world.ledger.mark()
            h.world.clock.advance(weeks * 7 * DAY)
            self.assertEqual(h.world.ledger.since(before), {})
            h.protected_read(h.owner().ensure_access("wake"))
            self.assertEqual(h.world.ledger.counts["issuer.refresh_consumed"], 1)
            self.assertEqual(h.world.ledger.counts["device_flow"], 1)

    def test_storage_temporarily_unavailable_preserves_pair_then_recovers(self):
        for status in ("unreachable", "locked", "timeout", "corrupt"):
            h = self.harness(auth)
            owner, _ = h.login()
            h.due()
            before = h.world.store.snapshot()
            h.world.store.backend_status["secret-service"] = status
            result = owner.ensure_access("wake")
            self.assertEqual(result.kind, "temporary")
            self.assertTrue(h.world.store.snapshot() == before)
            self.assertEqual(h.world.ledger.counts["issuer.refresh_request"], 0)
            h.world.store.backend_status.clear()
            h.world.clock.advance(600)
            h.protected_read(h.owner().ensure_access("maintenance"))
            self.assertEqual(h.world.ledger.counts["device_flow"], 1)

    def test_retry_after_and_transient_issuer_errors_do_not_delete_session(self):
        for status in (403, 429, 500, 503):
            h = self.harness(auth)
            owner, _ = h.login()
            h.due()
            h.world.issuer.faults.queue("refresh", Fault("reply", Reply(status, {}, {"Retry-After": "1200"})))
            before = h.world.store.snapshot()
            self.assertEqual(owner.ensure_access().kind, "temporary")
            retry_at = h.world.manifest.read()["retryAt"]
            self.assertEqual(retry_at, h.world.clock() + 1200)
            self.assertTrue(all(h.world.store.items.get(ref) == value for ref, value in before.items()))
            h.world.clock.advance(1199)
            self.assertEqual(h.owner().ensure_access().kind, "temporary")
            self.assertEqual(h.world.ledger.counts["issuer.refresh_request"], 1)
            h.world.clock.advance(1)
            h.protected_read(h.owner().ensure_access())

    def test_access401_renews_before_protected_retry(self):
        h = self.harness(auth)
        owner, before = h.login()
        result = owner.ensure_access("access401")
        self.assertEqual(result.kind, "ready")
        self.assertNotEqual(result.generation, before.generation)
        self.assertIsNone(h.world.issuer.authorize(before.access))
        h.protected_read(result)
        self.assertEqual(h.world.ledger.counts["issuer.refresh_consumed"], 1)

    def test_terminal_refresh_keeps_still_usable_access(self):
        h = self.harness(auth)
        owner, initial = h.login()
        h.world.issuer.issuances[0].refresh_valid = False
        h.world.clock.advance(8 * 3600 - 900)
        result = owner.ensure_access()
        self.assertEqual(result.kind, "ready")
        self.assertTrue(result.access == initial.access)
        h.protected_read(result)
        h.world.clock.advance(900)
        self.assertEqual(h.owner().ensure_access().kind, "actionRequired")
        self.assertEqual(h.world.ledger.counts["device_flow"], 1)

    def test_clock_rollback_no_refresh_busy_loop(self):
        h = self.harness(auth)
        owner, _ = h.login()
        h.world.clock.advance(-DAY)
        for _ in range(20):
            h.protected_read(owner.ensure_access())
        self.assertEqual(h.world.ledger.counts["issuer.refresh_request"], 0)

    def test_typed_read_statuses_never_call_network(self):
        h = self.harness(auth)
        owner, _ = h.login()
        mark = h.world.ledger.mark()
        for kind in ("missing", "locked", "unreachable", "timeout", "corrupt", "changed", "signedOut"):
            h.world.store.faults.queue("read", Fault(kind))
            self.assertEqual(owner.read_credential().kind, kind)
        self.assertEqual(h.world.ledger.since(mark).get("issuer.refresh_request", 0), 0)
        self.assertEqual(h.world.ledger.since(mark).get("protected.user_request", 0), 0)

    def test_short_ttl_lead_is_fraction_limited(self):
        h = self.harness(auth, access_ttl=1200)
        owner, _ = h.login()
        h.world.clock.advance(899)
        h.protected_read(owner.ensure_access())
        self.assertEqual(h.world.ledger.counts["issuer.refresh_request"], 0)
        h.world.clock.advance(1)
        h.protected_read(owner.ensure_access())
        self.assertEqual(h.world.ledger.counts["issuer.refresh_consumed"], 1)
