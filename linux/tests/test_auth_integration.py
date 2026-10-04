"""A1/A2/A4/A7/A10: real sync/cache/CLI with independent issuer/store fixtures."""
if __package__:
    from . import _isolate
    from ._auth_integration_env import PipelineCase, Fault, Reply, assert_nonsecret
else:
    import _isolate
    from _auth_integration_env import PipelineCase, Fault, Reply, assert_nonsecret

from copy import deepcopy
import os
from types import SimpleNamespace
from unittest.mock import patch

from ccl import auth, cli, common, sync, usage

DAY = 86400


class TestActualSyncPipeline(PipelineCase):
    def test_short_issuance_30_and_180_days_authorized_cache(self):
        for horizon in (30, 180):
            with self.subTest(horizon=horizon):
                self.login()
                mark = self.world.ledger.mark()
                _, first = self.cycle()
                epoch = first["authEpoch"]
                for day in range(1, horizon + 1):
                    self.world.clock.advance(DAY)
                    self.owner = self.make_owner()  # fresh owner, durable OS manifest/store
                    _, remote = self.cycle()
                    self.assertEqual(remote["authEpoch"], epoch)
                    self.assertEqual(remote["authUserID"], "1001")
                counts = self.world.ledger.since(mark)
                self.assertEqual(counts.get("issuer.refresh_consumed", 0), horizon)
                self.assertEqual(counts.get("issuer.refresh_request", 0), horizon)
                self.assertEqual(counts.get("issuer.refresh_rejected", 0), 0)
                self.assertGreaterEqual(counts["pipeline.gist_authorized"], horizon + 1)
                self.assertEqual(counts.get("device_flow", 0), 0)
                self.assertEqual(self.http.patch_count, 0)

    def test_access_only_30_and_180_days_actual_pipeline_without_new_grant(self):
        for horizon in (30, 180):
            with self.subTest(horizon=horizon):
                self.login(legacy=True)
                mark = self.world.ledger.mark()
                for day in range(horizon + 1):
                    if day:
                        self.world.clock.advance(DAY)
                    self.cycle()
                counts = self.world.ledger.since(mark)
                self.assertEqual(counts.get("issuer.refresh_request", 0), 0)
                self.assertEqual(counts.get("device_flow", 0), 0)
                self.assertGreaterEqual(counts["pipeline.gist_authorized"], horizon + 1)
                self.assertNotIn("authV2", common.read_json(common.SYNC_STATE_PATH))

    def test_sleep_two_and_six_weeks_restarts_and_refreshes_before_read(self):
        for weeks in (2, 6):
            with self.subTest(weeks=weeks):
                self.login()
                self.cycle()
                self.world.clock.advance(weeks * 7 * DAY)
                self.owner = self.make_owner()
                mark = self.world.ledger.mark()
                self.cycle()
                counts = self.world.ledger.since(mark)
                self.assertEqual(counts["issuer.refresh_consumed"], 1)
                self.assertGreaterEqual(counts["pipeline.gist_authorized"], 1)
                self.assertEqual(counts.get("device_flow", 0), 0)

    def test_storage_recovers_within_next_ten_minute_pipeline_attempt(self):
        self.login()
        self.cycle()
        self.world.clock.advance(42 * DAY)
        for status in ("unreachable", "locked", "timeout"):
            with self.subTest(status=status):
                self.world.store.backend_status["secret-service"] = status
                before = self.world.store.snapshot()
                mark = self.world.ledger.mark()
                res = sync.sync_cycle({}, auto=True, allow_push=False)
                self.assertFalse(res.ok)
                view = sync.auth_snapshot()
                self.assertEqual(view["kind"], "temporary")
                self.assertEqual(view["reason"], status)
                self.assertLessEqual(view["retryAt"] - self.world.clock(), 600)
                self.assertTrue(self.world.store.snapshot() == before)
                self.assertEqual(self.world.ledger.since(mark).get("issuer.refresh_request", 0), 0)
                self.world.store.backend_status.clear()
                self.world.clock.advance(600)
                self.cycle()
                self.world.clock.advance(8 * 3600)
        self.assertEqual(self.world.ledger.counts["device_flow"], 1)

    def test_proven_unsent_refresh_recovers_in_pipeline_without_manual_login(self):
        self.login()
        self.world.clock.advance(14 * DAY)
        self.http.fail_before_send = True
        res = sync.sync_cycle({}, auto=True, allow_push=False)
        self.assertFalse(res.ok)
        view = sync.auth_snapshot()
        self.assertEqual(view["kind"], "temporary")
        self.assertLessEqual(view["retryAt"] - self.world.clock(), 600)
        self.assertEqual(self.world.ledger.counts["issuer.refresh_consumed"], 0)
        self.http.fail_before_send = False
        self.world.clock.advance(600)
        self.owner = self.make_owner()
        self.cycle()
        self.assertEqual(self.world.ledger.counts["device_flow"], 1)

    def test_account_switch_failed_first_sync_cannot_show_old_remote_usage(self):
        self.login(user_id="1001", login="account-a")
        _, old_remote = self.cycle()
        self.assertTrue(old_remote["days"])
        self.login(user_id="2002", login="account-b")
        self.http.fail_read = True
        res = sync.sync_cycle({}, auto=True, allow_push=False)
        self.assertFalse(res.ok)
        self.assertEqual(sync.load_remote()["days"], {})
        self.assertFalse(sync.remote_matches_session(old_remote))
        self.assertFalse(os.path.exists(common.SYNC_REMOTE_PATH))
        self.http.fail_read = False
        _, current = self.cycle()
        self.assertEqual(current["authUserID"], "2002")
        self.assertNotEqual(current["authEpoch"], old_remote["authEpoch"])

    def test_cli_terminal_reason_permits_one_explicit_new_login(self):
        self.login()
        self.world.clock.advance(8 * 3600)
        self.world.issuer.faults.queue("refresh", Fault("reply", Reply(400, {"error": "bad_refresh_token"})))
        self.assertFalse(sync.sync_cycle({}, allow_push=False).ok)
        self.assertEqual(sync.auth_snapshot()["kind"], "actionRequired")
        output = []
        def device_start(attempt=None):
            self.assertTrue(sync.is_current(attempt))
            self.world.ledger.record("cli.device_start")
            return dict(verification_uri="https://github.com/login/device", user_code="FIXTURE", device_code="fixture")
        def device_poll(dev, cancelled):
            self.assertFalse(cancelled())
            return self.world.issuer.explicit_login().payload
        scanned = []
        def synthetic_index(*, blocking, progress):
            scanned.append(blocking)
            return {"days": {}, "files": {}}, False, True
        # cmd_login continues through cmd_push: enable only this synthetic index
        # and the issuer-authorized gist PATCH already enforced by our transport.
        with patch.object(sync, "device_start", device_start), patch.object(sync, "device_poll", device_poll), \
                patch.object(usage, "refresh", synthetic_index), patch.object(cli, "_progress_printer", lambda: None), \
                patch.object(cli, "_say", lambda *items: output.append(" ".join(map(str, items)))):
            code = cli.cmd_login(SimpleNamespace(force=False, no_browser=True))
        self.assertEqual(scanned, [True])
        self.assertEqual(self.http.patch_count, 1)
        self.assertEqual(code, 0)
        self.assertEqual(self.world.ledger.counts["cli.device_start"], 1)
        self.assertEqual(self.world.ledger.counts["device_flow"], 2)
        assert_nonsecret(output)
        self.cycle()

    def test_atomic_manifest_file_and_directory_fsync_preserve_other_sync_fields(self):
        self.login()
        sync.sync_state().update(fixtureUnrelated={"keep": 17})
        original = auth.LinuxManifest().read()
        changed = deepcopy(original)
        changed["retryAt"] = self.world.clock() + 600
        fsync_calls = []
        actual_fsync = os.fsync
        def observe(fd):
            fsync_calls.append(fd)
            return actual_fsync(fd)
        with patch.object(common.os, "fsync", observe):
            auth.LinuxManifest().write(changed)
        self.assertGreaterEqual(len(fsync_calls), 2)
        self.assertEqual(common.read_json(common.SYNC_STATE_PATH)["fixtureUnrelated"], {"keep": 17})
        self.assertEqual(auth.LinuxManifest().read()["retryAt"], changed["retryAt"])
        self.assertEqual(os.stat(common.SYNC_STATE_PATH).st_mode & 0o777, 0o600)

    def test_failed_atomic_replace_keeps_previous_whole_manifest(self):
        self.login()
        sync.sync_state().update(fixtureUnrelated={"keep": 17})
        previous = common.read_json(common.SYNC_STATE_PATH)
        changed = deepcopy(previous["authV2"])
        changed["retryAt"] = self.world.clock() + 600
        with patch.object(common.os, "replace", side_effect=OSError("synthetic atomic replace failure")):
            with self.assertRaises(OSError):
                auth.LinuxManifest().write(changed)
        self.assertEqual(common.read_json(common.SYNC_STATE_PATH), previous)
        self.owner = self.make_owner()
        self.cycle()

    def test_stage_uncertain_cancel_and_interrupt_fence_fresh_owner(self):
        # Independent late-writer oracle, actual OS manifest/owner transitions.
        # Explicit attempt has no prior active credential, so cancellation must
        # leave a durable tombstone rather than a publishable candidate intent.
        for interrupted in (False, True):
            with self.subTest(interrupted=interrupted):
                issuance = self.world.issuer.issue()
                self.world.store.faults.queue("write", Fault("late_timeout"))
                cancelled = [False]
                stage = self.owner.store.stage_refresh
                def uncertain_stage(ref, payload):
                    result = stage(ref, payload)
                    if interrupted:
                        raise KeyboardInterrupt()
                    cancelled[0] = True
                    return result
                with patch.object(self.owner.store, "stage_refresh", uncertain_stage):
                    if interrupted:
                        with self.assertRaises(KeyboardInterrupt):
                            self.owner.accept_login(issuance.wire(), "secret-service")
                    else:
                        result = self.owner.accept_login(issuance.wire(), "secret-service", cancelled=lambda: cancelled[0])
                        self.assertEqual(result.kind, "signedOut")
                late = self.world.store.late_writes[-1]
                manifest = auth.LinuxManifest().read()
                self.assertTrue(manifest["signedOut"])
                self.assertIsNone(manifest["active"])
                self.assertIsNone(manifest["transition"])
                self.assertTrue(any(ref["generation"] == late.ref.generation for ref in manifest["cleanupRefs"]))
                self.owner = self.make_owner()
                self.assertEqual(self.owner.ensure_access("restart").kind, "signedOut")
                late.release()
                self.assertEqual(self.make_owner().ensure_access("maintenance").kind, "signedOut")
                self.owner.logout()
                self.assertNotIn(late.ref, self.world.store.items)
                self.assertEqual(auth.LinuxManifest().read()["cleanupRefs"], [])
                self.assertEqual(self.world.ledger.counts["issuer.refresh_request"], 0)

    def test_corrupt_manifest_before_legacy_retirement_remains_byte_identical(self):
        issuance = self.world.issuer.issue()
        for raw in (b'{"login":"fixture-legacy","tokenBackend":"secret-service","authV2":',
                    b'{"login":"fixture-legacy","tokenBackend":"secret-service","tokenGeneration":"fixture-old","authV2":{"formatVersion":9}}'):
            with self.subTest(corrupt_size=len(raw)):
                common.write_atomic(common.SYNC_STATE_PATH, raw)
                before = self.world.ledger.mark()
                with self.assertRaises(sync.LoginError):
                    sync.begin_login()
                # Admission itself now strictly rejects unreadable state. A
                # previously captured device response must also be rejected.
                with self.assertRaises(sync.LoginError):
                    sync.login_finish(issuance.wire(), attempt="fixture-stale-attempt")
                with open(common.SYNC_STATE_PATH, "rb") as file:
                    self.assertEqual(file.read(), raw)
                delta = self.world.ledger.since(before)
                self.assertEqual(delta.get("store.write_attempt", 0), 0)
                self.assertEqual(delta.get("store.delete_attempt", 0), 0)
                self.assertEqual(delta.get("protected.user_request", 0), 0)

    def test_v2_writer_fence_closes_fd_when_thread_start_fails_or_interrupts(self):
        # Narrow real/tmp adapter allowance. No CredentialStore constructor or
        # real SS is used. Worker launch is tested both before and after a real
        # bounded thread exists; its transfer gate must prevent the SS callback.
        import errno
        import fcntl
        import threading
        from ccl import vault
        real_thread = threading.Thread
        real_open = os.open
        self.patch(vault.CredentialStore, "_writes", {})
        store = object.__new__(vault.CredentialStore)
        store.writer_id = os.getpid()
        for after_start in (False, True):
            for error_type in (RuntimeError, KeyboardInterrupt):
                with self.subTest(after_start=after_start, error_type=error_type.__name__):
                    workers, writer_fds, ss_calls = [], [], []
                    ref = {"generation": os.urandom(16).hex(), "backend": "secret-service"}
                    writer_path = os.path.join(common.STATE_DIR, "github-credential-writers", ref["generation"] + ".lock")
                    class FaultThread:
                        def __init__(self, *, target, name, daemon):
                            if name != "ccl-vault" or daemon is not True:
                                raise AssertionError("unexpected isolated worker")
                            self.worker = real_thread(target=target, name=name, daemon=daemon)
                        def start(self):
                            if after_start:
                                workers.append(self.worker)
                                self.worker.start()
                            raise error_type("synthetic thread start failure")
                    def observe_open(path, flags, *args):
                        fd = real_open(path, flags, *args)
                        if path == writer_path:
                            writer_fds.append(fd)
                        return fd
                    def fake_ss():
                        ss_calls.append("factory")
                        raise AssertionError("revoked worker launch reached synthetic SS")
                    try:
                        with patch.object(vault.threading, "Thread", FaultThread), patch.object(vault.os, "open", observe_open), \
                                patch.object(vault, "_ss_v2", fake_ss):
                            if error_type is KeyboardInterrupt:
                                with self.assertRaises(KeyboardInterrupt):
                                    store.stage_refresh(ref, "synthetic-envelope")
                            else:
                                self.assertNotEqual(store.stage_refresh(ref, "synthetic-envelope"), "ready")
                        self.assertEqual(len(writer_fds), 1)
                        for fd in writer_fds:
                            with self.assertRaises(OSError) as closed:
                                os.fstat(fd)
                            self.assertEqual(closed.exception.errno, errno.EBADF)
                        for worker in workers:
                            worker.join(2)
                            self.assertFalse(worker.is_alive(), "revoked launch worker did not finish")
                        self.assertEqual(ss_calls, [])
                        self.assertTrue(all(event.is_set() for event in store._writes[ref["generation"]]))
                        fd = real_open(writer_path, os.O_RDWR)
                        try:
                            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                            fcntl.flock(fd, fcntl.LOCK_UN)
                        finally:
                            os.close(fd)
                    finally:
                        for worker in workers:
                            worker.join(2)
                            self.assertFalse(worker.is_alive(), "fixture left a vault worker alive")

    def test_no_reply_free_client_lock_is_not_remote_daemon_settlement(self):
        # A D-Bus NoReply ends the local worker without proving whether the
        # daemon accepted CreateItem. Our remote promise remains explicit even
        # after local flock release and even when a payload becomes readable.
        import fcntl
        from ccl import vault
        class NoReply(Exception):
            def get_dbus_name(self):
                return "org.freedesktop.DBus.Error.NoReply"
        class SyntheticDaemon:
            def __init__(self):
                self.items = {}
                self.pending = []
                self.deletes = []
            def set(self, payload, generation):
                self.pending.append((generation, payload))
                raise NoReply("synthetic uncertain daemon reply")
            def get(self, generation):
                return self.items.get(generation)
            def has_locked(self, generation):
                return False
            def delete(self, generation):
                self.deletes.append(generation)
                self.items.pop(generation, None)
                return True
            def release_remote(self):
                for generation, payload in self.pending:
                    self.items[generation] = payload
                self.pending.clear()
        import threading
        thread_class = threading.Thread
        workers = []
        def tracked_thread(*args, **kwargs):
            worker = thread_class(*args, **kwargs)
            workers.append(worker)
            return worker
        self.patch(vault.threading, "Thread", tracked_thread)
        def join_workers():
            for worker in workers:
                worker.join(2)
                self.assertFalse(worker.is_alive(), "synthetic daemon fixture left local worker alive")
        self.addCleanup(join_workers)
        daemon = SyntheticDaemon()
        self.patch(vault, "_ss_v2", lambda: daemon)
        self.patch(vault, "TIMEOUT", 0.3)
        self.patch(vault.CredentialStore, "_writes", {})
        store = object.__new__(vault.CredentialStore)
        store.writer_id = os.getpid()
        ref = dict(generation=os.urandom(16).hex(), backend="secret-service", epoch="fixture-daemon-epoch",
                   writerPID=os.getpid(), uncertain=True)
        manifest = dict(formatVersion=2, epoch=ref["epoch"], active=None, transition=None,
                        cleanupRefs=[ref], signedOut=True, retryAt=None, failureReason="signedOut")
        auth.LinuxManifest().write(manifest)
        issuance = self.world.issuer.issue()
        credential = auth.parse_issuance(issuance.wire(), ref["epoch"], ref["generation"], self.world.clock(),
                                         user_id="1001", login="fixture-user")
        self.assertEqual(store.stage_refresh(ref, auth.encode_credential(credential)), "uncertain")
        self.assertEqual(len(daemon.pending), 1)
        join_workers()
        path = os.path.join(common.STATE_DIR, "github-credential-writers", ref["generation"] + ".lock")
        fd = os.open(path, os.O_RDWR)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(fd, fcntl.LOCK_UN)
        finally:
            os.close(fd)
        self.assertFalse(store.write_settled(ref), "local completion is not a daemon acknowledgement")
        self.owner = self.make_owner()
        self.owner.store = store
        self.assertFalse(self.owner.logout(), "unresolved remote writer must leave cleanup pending")
        self.assertTrue(any(item["generation"] == ref["generation"]
                            for item in auth.LinuxManifest().read()["cleanupRefs"]))
        daemon.release_remote()
        self.assertIn(ref["generation"], daemon.items)
        # A fresh wrapper must consult durable uncertainty, not a dead process's
        # in-memory Event or the presence of an already-readable item.
        fresh = object.__new__(vault.CredentialStore)
        fresh.writer_id = os.getpid()
        self.assertFalse(fresh.write_settled(ref), "readable replay cannot prove no other daemon writer")
        restarted = self.make_owner()
        restarted.store = fresh
        self.assertFalse(restarted.logout())
        self.assertEqual(daemon.deletes, [])
        self.assertTrue(any(item["generation"] == ref["generation"]
                            for item in auth.LinuxManifest().read()["cleanupRefs"]))

    def _expired_identity_candidate(self, origin):
        """Issuer, rather than client flags, determines whether access expired."""
        self.world.issuer.access_ttl = 1200
        mark = self.world.ledger.mark()
        if origin == 'refresh':
            self.login(user_id='1001', login='account-a')
            self.world.clock.advance(1200)
            self.world.issuer.faults.queue('user', Fault('reply', Reply(503, {})))
            self.assertFalse(sync.sync_cycle({}, allow_push=False).ok)
        else:
            attempt = sync.begin_login()
            response = self.world.issuer.explicit_login(user_id='1001', login='account-a')
            self.world.issuer.faults.queue('user', Fault('reply', Reply(503, {})))
            with self.assertRaises(sync.LoginError):
                sync.login_finish(response.payload, attempt=attempt)
        pending = auth.LinuxManifest().read()
        self.assertIsNotNone(pending['transition'], 'identity failure must retain durable staged pair')
        candidate = deepcopy(pending['transition']['to'])
        self.assertEqual(self.adapter.read_store(candidate).kind, 'ready')
        self.assertEqual(self.world.ledger.since(mark).get('issuer.refresh_request', 0), 1 if origin == 'refresh' else 0)
        self.world.clock.advance(7200)
        self.owner = self.make_owner()
        return candidate, pending['transition'].get('attemptID')

    def test_expired_durable_identity_candidate_refreshes_own_pair_and_preserves_account(self):
        for origin in ('login', 'refresh'):
            for rename in (False, True):
                with self.subTest(origin=origin, rename=rename):
                    self.owner.logout()
                    before = self.world.ledger.mark()
                    source, _ = self._expired_identity_candidate(origin)
                    # Rename retains immutable issuer ID; refresh must consume
                    # this unpublished candidate, whose predecessor is spent.
                    candidate_issue = self.world.issuer.issuances[-1]
                    if rename:
                        candidate_issue.login = 'renamed-account-a'
                    self.http.user_id = '1001'
                    self.cycle()
                    committed = auth.LinuxManifest().read()
                    self.assertEqual(committed['userID'], '1001')
                    self.assertEqual(committed['login'], 'renamed-account-a' if rename else 'account-a')
                    self.assertNotEqual(committed['active']['generation'], source['generation'])
                    self.assertIsNone(committed['transition'])
                    counts = self.world.ledger.since(before)
                    self.assertEqual(counts.get('issuer.refresh_request', 0), 2 if origin == 'refresh' else 1)
                    self.assertEqual(counts.get('issuer.refresh_rejected', 0), 0)
                    self.assertEqual(counts.get('device_flow', 0), 1)
                    self.assertEqual(self.adapter.read_store(source).kind, 'missing')
                    assert_nonsecret(committed)

    def test_expired_candidate_identity_mismatch_never_publishes_or_reuses_account_cache(self):
        self.login(user_id='1001', login='account-a')
        self.cycle()
        old_remote = sync.load_remote()
        self.world.clock.advance(8 * 3600)
        self.world.issuer.faults.queue('user', Fault('reply', Reply(503, {})))
        self.assertFalse(sync.sync_cycle({}, allow_push=False).ok)
        source = deepcopy(auth.LinuxManifest().read()['transition']['to'])
        self.world.clock.advance(9 * 3600)
        self.owner = self.make_owner()
        self.world.issuer.faults.queue('user', Fault('reply', Reply(200, {'id': '2002', 'login': 'account-b'})))
        self.assertFalse(sync.sync_cycle({}, allow_push=False).ok)
        committed = auth.LinuxManifest().read()
        self.assertEqual(committed['userID'], '1001')
        self.assertNotEqual(committed['active']['generation'], source['generation'])
        self.assertEqual(committed['failureReason'], 'identity_changed')
        self.assertEqual(sync.auth_snapshot()['kind'], 'actionRequired')
        self.assertEqual(sync.load_remote()['authUserID'], old_remote['authUserID'])
        self.assertEqual(sync.load_remote()['days'], old_remote['days'], 'failed identity must not publish new remote usage')

    def test_cancel_supersede_and_unknown_successor_budget_cannot_revive_expired_candidate(self):
        for operation in ('cancel', 'supersede', 'lost'):
            with self.subTest(operation=operation):
                self.owner.logout()
                source, attempt = self._expired_identity_candidate('login')
                before = self.world.ledger.mark()
                if operation == 'cancel':
                    sync.cancel_login(attempt)
                    self.owner = self.make_owner()
                    self.assertEqual(self.owner.ensure_access('restart').kind, 'signedOut')
                    self.assertEqual(self.world.ledger.since(before).get('issuer.refresh_request', 0), 0)
                elif operation == 'supersede':
                    self.login(user_id='2002', login='account-b')
                    self.cycle()
                    self.assertEqual(auth.LinuxManifest().read()['userID'], '2002')
                    self.assertEqual(self.world.ledger.since(before).get('issuer.refresh_request', 0), 0)
                else:
                    self.world.issuer.faults.queue('refresh', Fault('after_accept'))
                    self.assertFalse(sync.sync_cycle({}, allow_push=False).ok)
                    # One unknown grant and at most one recovery attempt, even
                    # after owner replacement; no automatic device flow.
                    for _ in range(4):
                        self.world.clock.advance(600)
                        self.owner = self.make_owner()
                        self.assertFalse(sync.sync_cycle({}, allow_push=False).ok)
                    counts = self.world.ledger.since(before)
                    self.assertLessEqual(counts.get('issuer.refresh_request', 0), 2)
                    self.assertEqual(counts.get('issuer.refresh_consumed', 0), 1)
                    self.assertEqual(counts.get('device_flow', 0), 0)
                    self.assertEqual(sync.auth_snapshot()['kind'], 'actionRequired')
                self.assertNotEqual((auth.LinuxManifest().read().get('active') or {}).get('generation'), source['generation'])

    def test_actual_adapter_protocol_proves_no_send_but_corrupt_receipt_and_old_refs_remain_unknown(self):
        from ccl import vault
        # Only root-local OS files and an explicitly fake Secret Service adapter
        # are reachable; the default constructor/factory remain forbidden.
        store = object.__new__(vault.CredentialStore)
        store.writer_id = os.getpid()
        store._writes = {}
        ref = dict(generation=os.urandom(16).hex(), backend='secret-service', epoch='fixture-nosend',
                   uncertain=True, writeProtocol=2)
        self.assertTrue(store.write_settled(ref), 'protocol journal + absent receipt proves no worker was launched')
        old = dict(ref)
        old.pop('writeProtocol')
        self.assertFalse(store.write_settled(old), 'pre-protocol missing receipt is not a no-send proof')
        receipt = os.path.join(common.STATE_DIR, 'github-credential-writers', ref['generation'] + '.lock.receipt')
        common.write_atomic(receipt, '{broken receipt', mode=0o600)
        self.assertFalse(store.write_settled(ref), 'corrupt receipt cannot become no-send proof')
        common.write_json(receipt, {'settled': False}, mode=0o600)
        self.assertFalse(store.write_settled(ref), 'durable pending receipt survives worker/process disappearance')
        common.write_json(receipt, {'settled': True}, mode=0o600)
        # A receipt without the owned lock pathname remains conservative; actual
        # launch creates the lock before receipt, so simulate that public file.
        lock_path = receipt.removesuffix('.receipt')
        fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
        os.close(fd)
        self.assertTrue(store.write_settled(ref), 'confirmed reply with free writer lock proves settlement')

    def test_new_pair_identity_401_allows_only_one_grant_per_outer_ensure_and_waits_backoff(self):
        for candidate_restart in (False, True):
            with self.subTest(candidate_restart=candidate_restart):
                self.owner.logout()
                if candidate_restart:
                    self._expired_identity_candidate('login')
                else:
                    self.login()
                    self.world.clock.advance(8 * 3600)
                before = self.world.ledger.mark()
                self.world.issuer.faults.queue('user', Fault('reply', Reply(401, {})))
                self.assertFalse(sync.sync_cycle({}, allow_push=False).ok)
                counts = self.world.ledger.since(before)
                self.assertEqual(counts.get('issuer.refresh_request', 0), 1,
                                 'one outer operation cannot recursively POST for its newly issued access')
                self.assertEqual(counts.get('issuer.refresh_consumed', 0), 1)
                snapshot = sync.auth_snapshot()
                self.assertEqual(snapshot['kind'], 'temporary')
                self.assertGreater(snapshot['retryAt'], self.world.clock())
                self.assertLessEqual(snapshot['retryAt'] - self.world.clock(), 600)
                self.owner = self.make_owner()
                self.assertFalse(sync.sync_cycle({}, allow_push=False).ok)
                self.assertEqual(self.world.ledger.since(before).get('issuer.refresh_request', 0), 1,
                                 'fresh owner must respect durable retry time')
                self.world.clock.advance(600)
                self.http.user_id = '1001'
                # A second independent rejection forces candidate renewal.
                # Without it, a healed /user may publish the first pair.
                self.world.issuer.faults.queue('user', Fault('reply', Reply(401, {})))
                self.cycle()
                self.assertEqual(self.world.ledger.since(before).get('issuer.refresh_request', 0), 2)
                self.assertEqual(self.world.ledger.since(before).get('issuer.refresh_rejected', 0), 0)
