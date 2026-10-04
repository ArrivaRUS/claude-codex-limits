"""Independent processes + actual sync flock; all issuer/storage content is fake."""
if __package__:
    from . import _isolate
    from ._auth_env import (AuthWorld, Fault, InjectedCrash, IsolatedAuthCase, Issuance,
                            OwnerHarness, StoreRef, LateWrite, assert_nonsecret)
else:
    import _isolate
    from _auth_env import (AuthWorld, Fault, InjectedCrash, IsolatedAuthCase, Issuance,
                           OwnerHarness, StoreRef, LateWrite, assert_nonsecret)

from collections import Counter
from contextlib import contextmanager
from dataclasses import asdict
import json
import multiprocessing
import os
from pathlib import Path
import webbrowser
from ccl import auth, common, vault, sync


def _save_fake_world(path, world):
    """Synthetic secrets stay only in the parent's private /tmp fixture file."""
    value = {"clock": world.clock(), "manifest": world.manifest.cell.value,
             "revision": world.manifest.cell.revision, "counts": dict(world.ledger.counts),
             "issuer_namespace": world.issuer._namespace,
             "issuances": [asdict(item) for item in world.issuer.issuances],
             "items": [{"ref": asdict(ref), "payload": payload} for ref, payload in world.store.items.items()],
             "marker": world.gist.marker}
    fd = os.open(path + ".new", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="ascii") as file:
        json.dump(value, file)
    os.replace(path + ".new", path)


def _load_fake_world(path, world):
    with open(path, encoding="ascii") as file:
        value = json.load(file)
    world.clock.set(value["clock"])
    world.manifest.cell.value = value["manifest"]
    world.manifest.cell.revision = value["revision"]
    world.ledger.counts = Counter(value["counts"])
    world.issuer._namespace = value["issuer_namespace"]
    world.issuer.issuances = [Issuance(**item) for item in value["issuances"]]
    world.issuer._access = {item.access: item for item in world.issuer.issuances}
    world.issuer._refresh = {item.refresh: item for item in world.issuer.issuances if item.refresh is not None}
    world.store.items = {StoreRef(**item["ref"]): item["payload"] for item in value["items"]}
    world.gist.marker = value["marker"]


class DiskHarness(OwnerHarness):
    def __init__(self, path, waiting=None):
        super().__init__(auth, AuthWorld())
        self.path, self.waiting = path, waiting
        # ensure_access captures clock BEFORE lock acquisition. Bootstrap the
        # shared synthetic clock now; locked() still reloads authoritative state
        # under flock, so followers cannot consume a stale refresh generation.
        # Atomic fixture replacement guarantees a whole snapshot on this read.
        _load_fake_world(self.path, self.world)

    @contextmanager
    def locked(self):
        if self.waiting:
            self.waiting.set()
        with common.file_lock("auth-core-process", timeout=5) as held:
            if held:
                _load_fake_world(self.path, self.world)
            try:
                yield held
            finally:
                if held:
                    _save_fake_world(self.path, self.world)


def _process_worker(root, path, queue, entered=None, release=None, waiting=None):
    # Spawn imports this file: _isolate is its FIRST import before any ccl module.
    # Restore shared paths only after that safety bootstrap; no production factory.
    try:
        if not Path(root).resolve().is_relative_to(Path("/tmp").resolve()):
            raise AssertionError("process fixture root must be /tmp")
        if not Path(path).resolve().is_relative_to(Path(root).resolve()):
            raise AssertionError("process fixture file escaped its root")
        def no_real(*args, **kwargs):
            raise AssertionError("real process auth boundary forbidden")
        vault._ss = vault._ss_v2 = vault._SecretService = no_real
        vault.read = vault.store = vault._file_get = no_real
        for name in ("read", "stage_refresh", "delete", "login_backend"):
            setattr(vault.CredentialStore, name, no_real)
        common.http = sync.transport = sync.sync_cycle = no_real
        if hasattr(sync, "auth_owner"):
            sync.auth_owner = no_real
        auth.LinuxManifest.read = auth.LinuxManifest.write = no_real
        webbrowser.open = no_real
        for name in ("CONFIG_DIR", "STATE_DIR", "CACHE_DIR", "DATA_DIR"):
            setattr(common, name, os.path.join(root, name.lower()))
        for name in ("SYNC_STATE_PATH", "SYNC_REMOTE_PATH", "TOKEN_FILE_PATH", "HISTORY_PATH"):
            if hasattr(common, name):
                setattr(common, name, os.path.join(root, name.lower()))
        h = DiskHarness(path, waiting)
        if entered is not None:
            def pause():
                entered.set()
                if not release.wait(5):
                    raise AssertionError("process barrier was not released")
            h.world.checkpoints.at("after_request_started", pause)
        result = h.owner().ensure_access("maintenance")
        with h.locked() as held:
            if not held:
                raise AssertionError("protected read could not lock fixture")
            marker = h.protected_read(result)
        public = {"kind": result.kind, "generation": result.generation, "marker": marker}
        assert_nonsecret(public)
        queue.put(public)
    except BaseException as error:
        # Never stringify an arbitrary dependency exception (might contain payload).
        queue.put({"error_type": type(error).__name__})


class TestAuthConcurrency(IsolatedAuthCase):
    def test_two_real_processes_share_one_refresh_and_current_reads(self):
        h = self.harness(auth)
        h.login()
        h.due()
        path = os.path.join(self.tmp.name, "synthetic-world.json")
        _save_fake_world(path, h.world)
        ctx = multiprocessing.get_context("spawn")
        queue, entered, release, waiting = ctx.Queue(), ctx.Event(), ctx.Event(), ctx.Event()
        first = ctx.Process(target=_process_worker, args=(self.tmp.name, path, queue, entered, release))
        second = ctx.Process(target=_process_worker, args=(self.tmp.name, path, queue, None, None, waiting))
        processes = (first, second)
        try:
            first.start()
            self.assertTrue(entered.wait(5), "first process did not enter renewal")
            second.start()
            self.assertTrue(waiting.wait(5), "follower did not attempt shared lock")
            release.set()
            results = [queue.get(timeout=10), queue.get(timeout=10)]
            for process in processes:
                process.join(10)
                self.assertFalse(process.is_alive())
                self.assertEqual(process.exitcode, 0)
            self.assertTrue(all(item.get("kind") == "ready" for item in results), "child auth operation failed")
            self.assertEqual(results[0]["generation"], results[1]["generation"])
            _load_fake_world(path, h.world)
            self.assertEqual(h.world.ledger.counts["issuer.refresh_consumed"], 1)
            self.assertEqual(h.world.ledger.counts["issuer.refresh_request"], 1)
            self.assertEqual(h.world.ledger.counts["protected.gist_authorized"], 2)
            self.assertEqual(h.world.ledger.counts["device_flow"], 1)
            self.assertEqual(h.world.gist.marker, 2)
        finally:
            release.set()
            for process in processes:
                if process.pid is not None:
                    if process.is_alive():
                        process.terminate()
                    process.join(5)
            queue.close()
            queue.join_thread()

    def test_lock_busy_has_no_storage_or_issuer_side_effect(self):
        h = self.harness(auth)
        owner, _ = h.login()
        h.due()
        mark = h.world.ledger.mark()
        with h.world.lock.held("another-process"):
            self.assertEqual(owner.ensure_access().kind, "temporary")
        delta = h.world.ledger.since(mark)
        for operation in ("store.read", "store.write_attempt", "issuer.refresh_request", "manifest.replace_attempt"):
            self.assertEqual(delta.get(operation, 0), 0)

    def test_logout_tombstone_survives_late_candidate_write(self):
        h = self.harness(auth)
        owner, _ = h.login()
        h.due()
        h.world.checkpoints.at("after_parse", lambda: h.world.store.faults.queue("write", Fault("late_timeout")))
        self.assertEqual(owner.ensure_access().kind, "temporary")
        old_epoch = h.world.manifest.read()["epoch"]
        # Caller holds the real conceptual auth lock; late backend worker doesn't.
        owner.logout()
        tombstone = h.world.manifest.read()
        self.assertNotEqual(tombstone["epoch"], old_epoch)
        self.assertTrue(tombstone["signedOut"])
        h.world.store.late_writes[0].release()
        self.assertEqual(h.owner().ensure_access().kind, "signedOut")
        self.assertIsNone(h.world.manifest.read()["active"])
        self.assertEqual(h.world.ledger.counts["device_flow"], 1)

    def test_new_login_epoch_rejects_old_commit(self):
        h = self.harness(auth)
        owner, _ = h.login()
        h.due()
        def change_epoch():
            manifest = h.world.manifest.read()
            manifest["epoch"] = "replacement-epoch"
            manifest["signedOut"] = True
            h.world.manifest.replace(manifest)
        h.world.checkpoints.at("before_publish", change_epoch)
        self.assertEqual(owner.ensure_access().kind, "signedOut")
        self.assertTrue(h.world.manifest.read()["signedOut"])
        newer, result = h.login()
        h.protected_read(result)
        self.assertFalse(h.world.manifest.read()["signedOut"])
        h.protected_read(newer.ensure_access())

    def test_independent_machines_local_logout_does_not_revoke_other(self):
        left, right = self.harness(auth), self.harness(auth)
        left_owner, left_result = left.login()
        right_owner, right_result = right.login()
        self.assertFalse(left_result.access == right_result.access)
        left_owner.logout()
        self.assertEqual(left.owner().ensure_access().kind, "signedOut")
        right.protected_read(right_owner.ensure_access())
        right.due()
        right.protected_read(right.owner().ensure_access())
        self.assertEqual(right.world.ledger.counts["issuer.refresh_consumed"], 1)

    def test_uncertain_login_stage_logout_retains_late_writer_address(self):
        h = self.harness(auth)
        owner = h.owner()
        issuance = h.world.issuer.explicit_login()
        h.world.store.faults.queue("write", Fault("late_timeout"))
        self.assertEqual(owner.accept_login(issuance.payload, "secret-service").kind, "temporary")
        late = h.world.store.late_writes[0]
        owner.logout()
        manifest = h.world.manifest.read()
        self.assertTrue(manifest["signedOut"])
        self.assertTrue(any(ref["generation"] == late.ref.generation for ref in manifest["cleanupRefs"]))
        late.release()
        self.assertEqual(h.owner().ensure_access().kind, "signedOut")
        h.owner().logout()
        self.assertNotIn(late.ref, h.world.store.items)
        self.assertEqual(h.world.manifest.read()["cleanupRefs"], [])

    def test_cancel_during_identity_or_publish_never_commits_login(self):
        for point in ("after_identity", "before_publish"):
            h = self.harness(auth)
            owner = h.owner()
            issuance = h.world.issuer.explicit_login()
            cancelled = [False]
            h.world.checkpoints.at(point, lambda: cancelled.__setitem__(0, True))
            result = owner.accept_login(issuance.payload, "secret-service", cancelled=lambda: cancelled[0])
            self.assertEqual(result.kind, "signedOut")
            self.assertIsNone(h.world.manifest.read().get("active"))
            self.assertIsNone(h.world.manifest.read().get("transition"))
            self.assertNotEqual(h.owner().ensure_access().kind, "ready")
            self.assertEqual(h.world.ledger.counts["device_flow"], 1)

    def test_explicit_login_clears_previous_compatibility_fence(self):
        h = self.harness(auth)
        owner, _ = h.login()
        manifest = h.world.manifest.read()
        manifest["compatibilityChanged"] = True
        h.world.manifest.replace(manifest)
        self.assertEqual(h.owner().ensure_access().kind, "signedOut")
        newer, result = h.login()
        h.protected_read(result)
        self.assertFalse(h.world.manifest.read().get("compatibilityChanged", False))
        h.protected_read(newer.ensure_access())

    def test_existing_item_does_not_prove_all_same_generation_writers_settled(self):
        h = self.harness(auth)
        owner, _ = h.login()
        h.due()
        h.world.checkpoints.at("after_parse", lambda: h.world.store.faults.queue("write", Fault("late_timeout")))
        self.assertEqual(owner.ensure_access().kind, "temporary")
        first = h.world.store.late_writes[0]
        second = LateWrite(h.world.store, first.ref, first.payload)
        h.world.store.late_writes.append(second)
        first.release()
        self.assertFalse(h.write_settled({"generation": first.ref.generation, "backend": first.ref.backend}))
        owner.logout()
        self.assertIn(first.ref, h.world.store.items)
        self.assertTrue(any(ref["generation"] == first.ref.generation for ref in h.world.manifest.read()["cleanupRefs"]))
        second.release()
        self.assertTrue(h.write_settled({"generation": first.ref.generation, "backend": first.ref.backend}))
        h.owner().logout()
        self.assertNotIn(first.ref, h.world.store.items)

# Additional OS crash fixture: no credentials are passed through argv/environment,
# and the spawned entry point has already imported _isolate before ccl above.
import shutil
import signal
if __package__:
    from ._auth_integration_env import PipelineCase
else:
    from _auth_integration_env import PipelineCase


def _process_file_stage_before_replace(root, ref, channel):
    try:
        if not Path(root).resolve().is_relative_to(Path('/tmp').resolve()):
            raise AssertionError('file crash root must be /tmp')
        if ref.get('backend') != 'file' or not auth.valid_ref(ref):
            raise AssertionError('file crash reference is invalid')
        channel.send({'scratch': _isolate.ROOT})
        def no_real(*args, **kwargs):
            raise AssertionError('real file crash boundary forbidden')
        vault._ss = vault._ss_v2 = vault._SecretService = no_real
        vault.read = vault.store = vault._file_get = no_real
        common.http = sync.transport = sync.auth_owner = sync.sync_cycle = no_real
        webbrowser.open = no_real
        from ccl import limits, usage
        limits.fetch_claude = limits.fetch_codex = usage.refresh = usage.load_index = no_real
        old_roots = (('CONFIG_DIR', common.CONFIG_DIR), ('STATE_DIR', common.STATE_DIR))
        for name, value in list(vars(common).items()):
            if not name.isupper() or not isinstance(value, str):
                continue
            for base, old_root in old_roots:
                if value == old_root or value.startswith(old_root + os.sep):
                    setattr(common, name, os.path.normpath(os.path.join(root, base.lower(), os.path.relpath(value, old_root))))
                    break
        for name in ('CLAUDE_PROJECTS', 'CLAUDE_CREDENTIALS', 'CODEX_SESSIONS', 'CODEX_AUTH'):
            setattr(common, name, os.path.join(root, 'cli', name.lower()))
        common._settings = common._state = None
        store = object.__new__(vault.CredentialStore)
        store.writer_id = os.getpid()
        store._writes = {}
        target = os.path.join(common.CONFIG_DIR, 'github-credentials', ref['generation'])
        # Only this synthetic root-local generation may supply the opaque payload.
        with open(target, encoding='ascii') as file:
            payload = file.read()
        original_replace = os.replace
        def stop_at_replace(source, destination):
            if destination != target:
                return original_replace(source, destination)
            if not Path(source).resolve().is_relative_to(Path(target).parent.resolve()):
                raise AssertionError('atomic credential temp escaped file generation directory')
            channel.send({'phase': 'before_replace'})
            if not channel.poll(10) or channel.recv() != 'release':
                raise AssertionError('file crash barrier was not released')
            return original_replace(source, destination)
        common.os.replace = stop_at_replace
        store.stage_refresh(ref, payload)
        channel.send({'outcome': 'finished'})
    except BaseException as error:
        channel.send({'error_type': type(error).__name__})
    finally:
        channel.close()


class TestActualFileCrash(PipelineCase):
    def test_sigkill_before_replace_logout_removes_final_and_secret_temp_copies(self):
        issued = self.world.issuer.issue()
        ref = dict(generation=os.urandom(16).hex(), backend='file', epoch='fixture-file-crash', uncertain=True)
        credential = auth.parse_issuance(issued.wire(), ref['epoch'], ref['generation'], self.world.clock(),
                                         user_id='1001', login='fixture-user')
        payload = auth.encode_credential(credential)
        directory = os.path.join(common.CONFIG_DIR, 'github-credentials')
        final_path = os.path.join(directory, ref['generation'])
        common.write_atomic(final_path, payload)
        manifest = dict(formatVersion=2, epoch=ref['epoch'], active=ref, transition=None, cleanupRefs=[],
                        signedOut=False, retryAt=None, failureReason=None, userID='1001', login='fixture-user')
        auth.LinuxManifest().write(manifest)
        ctx = multiprocessing.get_context('spawn')
        parent_channel, child_channel = ctx.Pipe(duplex=True)
        child = ctx.Process(target=_process_file_stage_before_replace, args=(self.tmp.name, ref, child_channel))
        scratch = None
        try:
            child.start()
            child_channel.close()
            self.assertTrue(parent_channel.poll(5), 'file crash child did not bootstrap within deadline')
            bootstrap = parent_channel.recv()
            self.assertIn('scratch', bootstrap, 'file crash child did not safely bootstrap')
            scratch = bootstrap['scratch']
            # The parent learns the writer PID from its own Process object; no
            # credential value or arbitrary child metadata controls this fence.
            manifest = auth.LinuxManifest().read()
            manifest['active']['writerPID'] = child.pid
            auth.LinuxManifest().write(manifest)
            self.assertTrue(parent_channel.poll(5), 'file child did not reach atomic credential replace')
            checkpoint = parent_channel.recv()
            self.assertEqual(checkpoint, {'phase': 'before_replace'}, 'child failed before atomic credential replace')
            temporary = [name for name in os.listdir(directory) if name.startswith('.' + ref['generation'] + '.')]
            self.assertEqual(len(temporary), 1, 'expected one owned durable atomic secret temp')
            self.assertTrue(os.path.exists(final_path))
            self.assertEqual(os.stat(os.path.join(directory, temporary[0])).st_mode & 0o777, 0o600)
            os.kill(child.pid, signal.SIGKILL)
            child.join(5)
            self.assertFalse(child.is_alive())
            self.assertEqual(child.exitcode, -signal.SIGKILL)
            self.patch(vault.CredentialStore, '_writes', {})
            store = object.__new__(vault.CredentialStore)
            store.writer_id = os.getpid()
            self.owner = self.make_owner()
            self.owner.store = store
            self.assertTrue(self.owner.logout(), 'file backend logout must physically clear every owned secret copy')
            remaining = [name for name in os.listdir(directory)
                         if name == ref['generation'] or name.startswith('.' + ref['generation'] + '.')]
            self.assertEqual(remaining, [], 'logout left final or atomic temporary credential copy')
            self.assertEqual(auth.LinuxManifest().read()['cleanupRefs'], [])
            self.assertEqual(self.make_owner().ensure_access('restart').kind, 'signedOut')
            self.assertEqual(self.world.ledger.counts['issuer.refresh_request'], 0)
        finally:
            # Never signal an Event/Condition held by a killed process. Pipe
            # endpoints close locally and do not acquire a dead child's lock.
            parent_channel.close()
            child_channel.close()
            if child.pid is not None:
                if child.is_alive():
                    child.terminate()
                child.join(2)
                if child.is_alive():
                    child.kill()
                    child.join(2)
                self.assertFalse(child.is_alive(), 'file crash fixture left child alive')
            if scratch:
                scratch_path = Path(scratch).resolve()
                if (scratch_path.is_relative_to(Path('/tmp').resolve())
                        and scratch_path.name.startswith('ccl-tests-')):
                    shutil.rmtree(scratch_path, ignore_errors=True)


def _process_supersede_device_attempt(root, operation, queue):
    # Child's module imported _isolate before every ccl import. Shared state is
    # root-local, credentials never exist, and the owner has only explicit fakes.
    try:
        if not Path(root).resolve().is_relative_to(Path('/tmp').resolve()):
            raise AssertionError('device attempt process root must be /tmp')
        def no_real(*args, **kwargs):
            raise AssertionError('real device attempt boundary forbidden')
        vault._ss = vault._ss_v2 = vault._SecretService = no_real
        vault.read = vault.store = vault._file_get = no_real
        common.http = sync.transport = sync.sync_cycle = sync.device_start = sync.device_poll = no_real
        webbrowser.open = no_real
        old_roots = (('CONFIG_DIR', common.CONFIG_DIR), ('STATE_DIR', common.STATE_DIR))
        for name, value in list(vars(common).items()):
            if not name.isupper() or not isinstance(value, str):
                continue
            for base, old_root in old_roots:
                if value == old_root or value.startswith(old_root + os.sep):
                    setattr(common, name, os.path.normpath(os.path.join(root, base.lower(), os.path.relpath(value, old_root))))
                    break
        for name in ('CLAUDE_PROJECTS', 'CLAUDE_CREDENTIALS', 'CODEX_SESSIONS', 'CODEX_AUTH'):
            setattr(common, name, os.path.join(root, 'cli', name.lower()))
        common._settings = common._state = None
        from types import SimpleNamespace
        store = SimpleNamespace(read=lambda ref: auth.AuthRead('missing', ref=ref),
                                stage_refresh=no_real, delete=lambda ref: 'ready',
                                write_settled=lambda ref: True, login_backend=no_real)
        owner = auth.AuthOwner(auth.LinuxManifest(), store, no_real, no_real,
                              lambda: common.file_lock('sync', timeout=0.3), lambda: 1_800_000_000,
                              legacy=lambda: auth.AuthRead('signedOut'))
        sync.auth_owner = lambda: owner
        def retire_empty(refs):
            if refs:
                raise AssertionError('device fixture unexpectedly found legacy credentials')
            return True
        vault.retire = retire_empty
        if operation == 'logout':
            success = sync.logout()
        elif operation == 'new_attempt':
            success = sync.is_current(sync.begin_login())
        else:
            raise AssertionError('unknown device fixture operation')
        queue.put({'completed': success, 'scratch': _isolate.ROOT})
    except BaseException as error:
        queue.put({'error_type': type(error).__name__, 'scratch': _isolate.ROOT})


class TestDurableDeviceAttempt(PipelineCase):
    def test_device_response_after_other_process_logout_or_new_attempt_cannot_publish(self):
        for operation in ('logout', 'new_attempt'):
            with self.subTest(operation=operation):
                # No issuance exists at the time of the durable device attempt.
                auth.LinuxManifest().write(dict(formatVersion=2, epoch=os.urandom(16).hex(), active=None,
                    transition=None, cleanupRefs=[], signedOut=True, retryAt=None, failureReason='signedOut'))
                attempt = sync.begin_login()
                self.assertTrue(sync.is_current(attempt))
                ctx = multiprocessing.get_context('spawn')
                queue = ctx.Queue()
                child = ctx.Process(target=_process_supersede_device_attempt, args=(self.tmp.name, operation, queue))
                scratch = None
                try:
                    child.start()
                    result = queue.get(timeout=5)
                    scratch = result.get('scratch')
                    child.join(5)
                    self.assertFalse(child.is_alive())
                    self.assertEqual(child.exitcode, 0)
                    self.assertTrue(result.get('completed'), 'child did not complete synthetic administrative operation')
                    self.assertFalse(sync.is_current(attempt), 'process-local attempt survived a durable superseding action')
                    with open(common.SYNC_STATE_PATH, 'rb') as file:
                        superseding_state = file.read()
                    issued = self.world.issuer.issue()
                    before = self.world.ledger.mark()
                    with self.assertRaises(sync.LoginError):
                        sync.login_finish(issued.wire(), attempt=attempt)
                    with open(common.SYNC_STATE_PATH, 'rb') as file:
                        self.assertEqual(file.read(), superseding_state)
                    delta = self.world.ledger.since(before)
                    self.assertEqual(delta.get('store.write_attempt', 0), 0)
                    self.assertEqual(delta.get('protected.user_request', 0), 0)
                    self.assertEqual(self.world.ledger.counts['issuer.refresh_request'], 0)
                finally:
                    if child.pid is not None:
                        if child.is_alive():
                            child.terminate()
                        child.join(5)
                        self.assertFalse(child.is_alive(), 'device fixture left child alive')
                    queue.close()
                    queue.join_thread()
                    if scratch:
                        scratch_path = Path(scratch).resolve()
                        if (scratch_path.is_relative_to(Path('/tmp').resolve())
                                and scratch_path.name.startswith('ccl-tests-')):
                            shutil.rmtree(scratch_path, ignore_errors=True)
