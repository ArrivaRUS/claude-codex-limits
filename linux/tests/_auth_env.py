"""Independent, stdlib-only auth fixtures; no production imports or import-time I/O.

Test entry points and child-process bootstraps must import `_isolate` BEFORE `ccl`
or the new auth owner. This module deliberately does not import `_isolate`: that
module imports production common/vault transitively. Future adapters wrap these
fixtures after isolation; this oracle does not call or reproduce production
parsers, transitions, retry policy, or lock implementations.

All credentials are synthetic sentinels. Memory-backed durability means data
survives wrapper replacement, not OS/process death; real process-lock/atomic-file
integration must be tested separately under a temporary root.
"""

from collections import Counter, deque
from contextlib import contextmanager
from copy import deepcopy
from dataclasses import dataclass, field
import base64
import json
import math
import re
import threading
from types import SimpleNamespace
import uuid
import os
import sys
import tempfile
import unittest
from unittest.mock import patch


DAY = 86400
OAUTH_URL = "https://github.com/login/oauth/access_token"
USER_URL = "https://api.github.com/user"
SECRET_KEYS = frozenset(("accessToken", "refreshToken", "access_token", "refresh_token",
                         "client_secret", "authorization"))
SENTINEL = re.compile(r"ccl-test-(?:access|refresh)-[0-9a-f]+")


def assert_nonsecret(value, depth=0):
    """Reject credentials in public state/errors without echoing their values."""
    if depth > 12:
        raise AssertionError("public fixture value is too deeply nested")
    if isinstance(value, dict):
        for key, item in value.items():
            if key in SECRET_KEYS or str(key).lower() == "authorization":
                raise AssertionError("credential field in public fixture state")
            assert_nonsecret(item, depth + 1)
    elif isinstance(value, (list, tuple)):
        for item in value:
            assert_nonsecret(item, depth + 1)
    elif isinstance(value, bytes):
        assert_nonsecret(value.decode("ascii", errors="replace"), depth + 1)
    elif isinstance(value, str):
        if SENTINEL.search(value):
            raise AssertionError("credential sentinel in public fixture state")
        # Also catch a serialized/base64 envelope hidden in a nonsecret field.
        if len(value) >= 16 and re.fullmatch(r"[A-Za-z0-9_+/=-]+", value):
            try:
                decoded = base64.urlsafe_b64decode(value + "=" * (-len(value) % 4)).decode("ascii")
            except (ValueError, UnicodeError):
                return
            if decoded != value:
                if SENTINEL.search(decoded):
                    raise AssertionError("encoded credential sentinel in public fixture state")


@dataclass(frozen=True)
class Event:
    sequence: int
    operation: str
    details: dict


class Ledger:
    def __init__(self):
        self.events = []
        self.counts = Counter()
        self._lock = threading.Lock()

    def record(self, operation, **details):
        assert_nonsecret(details)
        with self._lock:
            self.counts[operation] += 1
            self.events.append(Event(len(self.events) + 1, operation, deepcopy(details)))

    def mark(self):
        return Counter(self.counts)

    def since(self, mark):
        return {name: self.counts[name] - mark[name] for name in self.counts
                if self.counts[name] != mark[name]}


class FakeClock:
    def __init__(self, now=1_800_000_000.0):
        self.set(now)

    def __call__(self):
        return self._now

    def set(self, value):
        if isinstance(value, bool) or not isinstance(value, (float, int)) or not math.isfinite(value):
            raise ValueError("fake clock requires a finite numeric instant")
        self._now = float(value)

    def advance(self, seconds):
        self.set(self._now + seconds)
        return self._now


@dataclass(frozen=True)
class Reply:
    status: int
    payload: object = field(default=None, repr=False)
    headers: dict = field(default_factory=dict, repr=False)
    raw: bytes = field(default=None, repr=False)


class KnownNotSent(Exception):
    """Independent transport fact: issuer definitely did not receive the request."""


class OutcomeUnknown(Exception):
    """Issuer may have consumed a one-use refresh; never contains token values."""


@dataclass(frozen=True)
class Fault:
    kind: str
    reply: Reply = field(default=None, repr=False)
    consume: bool = False


class Faults:
    def __init__(self):
        self._queues = {}

    def queue(self, operation, *faults):
        self._queues.setdefault(operation, deque()).extend(faults)

    def take(self, operation):
        queue = self._queues.get(operation)
        return queue.popleft() if queue else None

    def assert_drained(self):
        if any(self._queues.values()):
            raise AssertionError("unconsumed fixture faults")


@dataclass
class Issuance:
    ordinal: int
    access: str = field(repr=False)
    refresh: str = field(repr=False)
    user_id: str = "1001"
    login: str = "fixture-user"
    issued_at: float = 0.0
    access_until: float = None
    refresh_until: float = None
    access_valid: bool = True
    refresh_valid: bool = True

    def wire(self):
        body = {"access_token": self.access, "token_type": "bearer", "scope": "gist"}
        if self.refresh is not None:
            body["refresh_token"] = self.refresh
        if self.access_until is not None:
            body["expires_in"] = self.access_until - self.issued_at
        if self.refresh_until is not None:
            body["refresh_token_expires_in"] = self.refresh_until - self.issued_at
        return body


class FakeIssuer:
    """Issuer-owned one-use ledger; tokens expire even if client metadata is wrong."""
    def __init__(self, clock, ledger, access_ttl=8 * 3600, refresh_ttl=180 * DAY):
        self.clock, self.ledger = clock, ledger
        self.access_ttl, self.refresh_ttl = access_ttl, refresh_ttl
        self.issuances = []
        self.faults = Faults()
        self._access, self._refresh = {}, {}
        self._lock = threading.RLock()
        self._namespace = uuid.uuid4().hex

    def issue(self, *, legacy=False, user_id="1001", login="fixture-user"):
        with self._lock:
            ordinal = len(self.issuances) + 1
            now = self.clock()
            issuance = Issuance(ordinal, "ccl-test-access-" + self._namespace + "%016x" % ordinal,
                                None if legacy else "ccl-test-refresh-" + self._namespace + "%016x" % ordinal,
                                str(user_id), login, now,
                                None if legacy else now + self.access_ttl,
                                None if legacy else now + self.refresh_ttl)
            self.issuances.append(issuance)
            self._access[issuance.access] = issuance
            if issuance.refresh is not None:
                self._refresh[issuance.refresh] = issuance
            self.ledger.record("issuer.issue", issuance=ordinal, legacy=legacy, user_id=str(user_id))
            return issuance

    def explicit_login(self, **kwargs):
        self.ledger.record("device_flow")
        return Reply(200, self.issue(**kwargs).wire())

    def authorize(self, access):
        with self._lock:
            issued = self._access.get(access)
            if issued is None or not issued.access_valid:
                return None
            if issued.access_until is not None and self.clock() >= issued.access_until:
                return None
            return issued

    def _consume(self, refresh):
        old = self._refresh.get(refresh)
        if old is None or not old.refresh_valid or self.clock() >= old.refresh_until:
            self.ledger.record("issuer.refresh_rejected")
            return None
        old.access_valid = old.refresh_valid = False
        self.ledger.record("issuer.refresh_consumed", issuance=old.ordinal)
        return self.issue(user_id=old.user_id, login=old.login)

    def refresh(self, refresh):
        with self._lock:
            self.ledger.record("refresh.attempt")
            fault = self.faults.take("refresh")
            if fault and (fault.kind not in ("before_send", "after_accept", "reply")
                          or (fault.kind == "reply" and fault.reply is None)):
                raise AssertionError("unsupported issuer fault")
            if fault and fault.kind == "before_send":
                self.ledger.record("refresh.not_sent")
                raise KnownNotSent("synthetic request was not sent")
            self.ledger.record("issuer.refresh_request")
            if fault and fault.kind == "reply" and not fault.consume:
                if fault.reply is None:
                    raise AssertionError("reply fault requires a Reply")
                return fault.reply
            issued = self._consume(refresh)
            if issued is None:
                return Reply(400, {"error": "bad_refresh_token"})
            if fault and fault.kind == "after_accept":
                self.ledger.record("refresh.response_lost", issuance=issued.ordinal)
                raise OutcomeUnknown("synthetic issuer consumed refresh; response lost")
            if fault and fault.kind == "reply":
                if fault.reply is None:
                    raise AssertionError("reply fault requires a Reply")
                return fault.reply
            if fault:
                raise AssertionError("unsupported issuer fault")
            return Reply(200, issued.wire())

    def user(self, access):
        self.ledger.record("protected.user_request")
        issued = self.authorize(access)
        if issued is None:
            return Reply(401, {"message": "synthetic unauthorized"})
        fault = self.faults.take("user")
        if fault:
            if fault.kind == "before_send":
                raise KnownNotSent("synthetic identity request was not sent")
            if fault.kind != "reply" or fault.reply is None:
                raise AssertionError("unsupported identity fault")
            return fault.reply
        self.ledger.record("protected.user_authorized", issuance=issued.ordinal)
        return Reply(200, {"id": issued.user_id, "login": issued.login})

    def oauth_request(self, method, url, headers, form, *, follow_redirects=False):
        """Strict lower-boundary spy; future production transport adapters use it."""
        if method != "POST" or url != OAUTH_URL or follow_redirects:
            raise AssertionError("OAuth request escaped exact HTTPS/no-redirect contract")
        if any(key.lower() == "authorization" for key in headers) or "client_secret" in form:
            raise AssertionError("OAuth request carried prohibited authentication fields")
        if form.get("grant_type") != "refresh_token" or not form.get("client_id"):
            raise AssertionError("unexpected OAuth fixture request")
        return self.refresh(form.get("refresh_token"))


class FakeProtectedGist:
    """A successful read requires current issuer authorization, not a client flag."""
    def __init__(self, issuer, ledger, user_id="1001"):
        self.issuer, self.ledger, self.user_id = issuer, ledger, str(user_id)
        self.marker = 0
        self.faults = Faults()

    def advance_marker(self):
        self.marker += 1
        return self.marker

    def read(self, access):
        self.ledger.record("protected.gist_request")
        issued = self.issuer.authorize(access)
        if issued is None or issued.user_id != self.user_id:
            return Reply(401, {"message": "synthetic unauthorized"})
        fault = self.faults.take("read")
        if fault:
            if fault.kind == "before_send":
                raise KnownNotSent("synthetic gist request was not sent")
            if fault.kind != "reply" or fault.reply is None:
                raise AssertionError("unsupported gist fault")
            return fault.reply
        self.ledger.record("protected.gist_authorized", issuance=issued.ordinal, marker=self.marker)
        return Reply(200, {"usage_marker": self.marker, "user_id": self.user_id})


@dataclass(frozen=True)
class StoreRef:
    generation: str
    backend: str


@dataclass(frozen=True)
class StoreRead:
    status: str
    payload: object = field(default=None, repr=False)


class StorageFailure(Exception):
    def __init__(self, status, late_write=None):
        self.status, self.late_write = status, late_write
        super().__init__("synthetic storage " + status)


@dataclass
class LateWrite:
    store: object = field(repr=False)
    ref: StoreRef
    payload: object = field(repr=False)
    completed: bool = False

    def release(self):
        if self.completed:
            raise AssertionError("late fixture write completed twice")
        self.store._write_durable(self.ref, self.payload)
        self.completed = True
        self.store.ledger.record("store.late_complete", generation=self.ref.generation, backend=self.ref.backend)


class FakeCredentialStore:
    """Opaque generation payloads; identity enrichment may replace bytes in-place."""
    def __init__(self, ledger):
        self.ledger = ledger
        self.items = {}
        self.backend_status = {}
        self.faults = Faults()
        self.late_writes = []

    def _status(self, ref):
        return self.backend_status.get(ref.backend, "ready")

    def read(self, ref):
        self.ledger.record("store.read", generation=ref.generation, backend=ref.backend)
        status = self._status(ref)
        fault = self.faults.take("read")
        if fault:
            status = fault.kind
        if status != "ready":
            return StoreRead(status)
        return StoreRead("ready", deepcopy(self.items[ref])) if ref in self.items else StoreRead("missing")

    def _write_durable(self, ref, payload):
        self.items[ref] = deepcopy(payload)
        self.ledger.record("store.durable_write", generation=ref.generation, backend=ref.backend)

    def write(self, ref, payload):
        self.ledger.record("store.write_attempt", generation=ref.generation, backend=ref.backend)
        status = self._status(ref)
        fault = self.faults.take("write")
        if fault:
            if fault.kind == "late_timeout":
                late = LateWrite(self, ref, deepcopy(payload))
                self.late_writes.append(late)
                raise StorageFailure("timeout", late)
            status = fault.kind
        if status != "ready":
            raise StorageFailure(status)
        self._write_durable(ref, payload)

    def delete(self, ref):
        self.ledger.record("store.delete_attempt", generation=ref.generation, backend=ref.backend)
        status = self._status(ref)
        fault = self.faults.take("delete")
        if fault:
            status = fault.kind
        if status != "ready":
            raise StorageFailure(status)
        self.items.pop(ref, None)
        self.ledger.record("store.delete_complete", generation=ref.generation, backend=ref.backend)

    def snapshot(self):
        """Sensitive comparison fixture: callers must never print/serialize to public logs."""
        return deepcopy(self.items)


@dataclass
class ManifestCell:
    value: object = None
    revision: int = 0


class FakeManifest:
    """Atomic memory cell, replaceable wrapper; not a substitute for real fsync tests."""
    def __init__(self, ledger, cell=None):
        self.ledger, self.cell = ledger, cell if cell is not None else ManifestCell()
        self.faults = Faults()

    def read(self):
        self.ledger.record("manifest.read", revision=self.cell.revision)
        fault = self.faults.take("read")
        if fault:
            raise StorageFailure(fault.kind)
        return deepcopy(self.cell.value)

    def replace(self, value):
        assert_nonsecret(value)
        self.ledger.record("manifest.replace_attempt", revision=self.cell.revision)
        fault = self.faults.take("replace")
        if fault:
            raise StorageFailure(fault.kind)
        self.cell.value = deepcopy(value)
        self.cell.revision += 1
        self.ledger.record("manifest.replace_complete", revision=self.cell.revision)

    def reopen(self):
        return FakeManifest(self.ledger, self.cell)


class InjectedCrash(BaseException):
    """A checkpoint stops the simulated process without ordinary Exception recovery."""


CHECKPOINTS = frozenset(("before_intent", "after_intent", "after_request_started",
                         "after_response", "after_parse", "after_stage", "after_readback",
                         "before_identity", "after_identity", "before_publish", "after_publish",
                         "before_retire", "after_retire", "after_logout_tombstone"))


class Checkpoints:
    def __init__(self, ledger):
        self.ledger = ledger
        self.actions = {}

    def at(self, name, action):
        if name not in CHECKPOINTS:
            raise ValueError("unknown fixture checkpoint")
        self.actions.setdefault(name, deque()).append(action)

    def __call__(self, name, **metadata):
        if name not in CHECKPOINTS:
            raise AssertionError("unexpected checkpoint")
        self.ledger.record("checkpoint." + name, **metadata)
        queue = self.actions.get(name)
        if not queue:
            return
        action = queue.popleft()
        if isinstance(action, BaseException):
            raise action
        action()


class LockBusy(Exception):
    pass


class FakeLock:
    """Deterministic ownership oracle; real interprocess exclusion is a later integration."""
    def __init__(self, ledger):
        self.ledger, self.owner = ledger, None

    @contextmanager
    def held(self, owner="fixture-owner"):
        self.ledger.record("lock.acquire_attempt", owner=owner)
        if self.owner is not None:
            if self.owner == owner:
                raise AssertionError("unexpected nested auth lock")
            raise LockBusy("synthetic lock busy")
        self.owner = owner
        self.ledger.record("lock.acquired", owner=owner)
        try:
            yield
        finally:
            self.owner = None
            self.ledger.record("lock.released", owner=owner)


class AuthWorld:
    """Fixture-only dependencies; no auth coordinator or production factory is created."""
    def __init__(self, *, now=1_800_000_000.0, access_ttl=8 * 3600, refresh_ttl=180 * DAY):
        self.clock, self.ledger = FakeClock(now), Ledger()
        self.issuer = FakeIssuer(self.clock, self.ledger, access_ttl, refresh_ttl)
        self.gist = FakeProtectedGist(self.issuer, self.ledger)
        self.store = FakeCredentialStore(self.ledger)
        self.manifest = FakeManifest(self.ledger)
        self.checkpoints, self.lock = Checkpoints(self.ledger), FakeLock(self.ledger)

    def public_snapshot(self):
        manifest = self.manifest.read()
        result = {"now": self.clock(), "counts": dict(self.ledger.counts),
                  "manifest": manifest,
                  "store_refs": [{"generation": ref.generation, "backend": ref.backend}
                                 for ref in self.store.items],
                  "gist_marker": self.gist.marker}
        assert_nonsecret(result)
        return result


class OwnerHarness:
    """Duck-typed adapters only; caller supplies the isolated production module.

    This boundary maps protocols, not parsing/transition/retry policy. It never
    chooses a production factory or default store/transport. Tests may replace
    each dependency explicitly before constructing the owner.
    """
    def __init__(self, auth_module, world=None, legacy=None):
        self.auth = auth_module
        self.world = world or AuthWorld()
        self.legacy = legacy

    @staticmethod
    def ref(value):
        return StoreRef(value["generation"], value["backend"])

    def read_store(self, ref):
        result = self.world.store.read(self.ref(ref))
        return SimpleNamespace(kind=result.status, credential=result.payload, ref=deepcopy(ref))

    def stage_refresh(self, ref, payload):
        try:
            self.world.store.write(self.ref(ref), payload)
            return "ready"
        except StorageFailure as error:
            return "uncertain" if error.late_write is not None else "failure"

    def write_settled(self, ref):
        return not any(write.ref == self.ref(ref) and not write.completed
                       for write in self.world.store.late_writes)

    def delete(self, ref):
        try:
            self.world.store.delete(self.ref(ref))
            return "ready"
        except StorageFailure as error:
            return error.status

    def read_manifest(self):
        try:
            return self.world.manifest.read()
        except StorageFailure as error:
            raise OSError("synthetic manifest unavailable") from error

    def write_manifest(self, value):
        try:
            self.world.manifest.replace(value)
        except StorageFailure as error:
            raise OSError("synthetic manifest unavailable") from error

    def transport(self, url, fields):
        try:
            reply = self.world.issuer.oauth_request("POST", url, {}, fields, follow_redirects=False)
        except OutcomeUnknown:
            return 0, None, {}
        except KnownNotSent:
            raise self.auth.RefreshNotSent("synthetic proven pre-send failure") from None
        return reply.status, reply.payload, reply.headers

    def identity(self, access):
        try:
            reply = self.world.issuer.user(access)
        except KnownNotSent:
            return 0, None, {}
        return reply.status, reply.payload, reply.headers

    @contextmanager
    def locked(self):
        if self.world.lock.owner is not None:
            self.world.ledger.record("lock.busy")
            yield False
            return
        with self.world.lock.held():
            yield True

    def owner(self):
        return self.auth.AuthOwner(
            manifest=SimpleNamespace(read=self.read_manifest, write=self.write_manifest),
            store=SimpleNamespace(read=self.read_store, stage_refresh=self.stage_refresh,
                                  delete=self.delete, write_settled=self.write_settled),
            transport=self.transport, identity=self.identity, lock=self.locked,
            clock=self.world.clock, checkpoint=self.world.checkpoints, jitter=lambda: 0,
            legacy=lambda: self.legacy or self.auth.AuthRead("signedOut"))

    def login(self, owner=None, *, backend="secret-service", legacy=False):
        owner = owner or self.owner()
        reply = self.world.issuer.explicit_login(legacy=legacy)
        result = owner.accept_login(reply.payload, backend)
        if result.kind != "ready":
            raise AssertionError("synthetic initial login did not commit")
        return owner, result

    def due(self):
        # Issuer-owned boundary; test cadence is intentionally fixed at 10 min,
        # rather than borrowing the production lead or due calculation.
        issued = self.world.issuer.issuances[-1]
        self.world.clock.set(issued.access_until)

    def protected_read(self, result):
        if result.kind != "ready":
            raise AssertionError("protected read requires a ready result")
        marker = self.world.gist.advance_marker()
        reply = self.world.gist.read(result.access)
        if reply.status != 200 or reply.payload.get("usage_marker") != marker:
            raise AssertionError("current issuance failed protected gist read")
        return marker


def forbidden(*args, **kwargs):
    raise AssertionError("real credential, API, browser or runtime boundary forbidden")


class IsolatedAuthCase(unittest.TestCase):
    """Only after entry-point `_isolate`: strict sentinels and per-test tmp paths."""
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="ccl-auth-test-", dir="/tmp")
        self.addCleanup(self.tmp.cleanup)
        common, vault, sync = (sys.modules["ccl." + name] for name in ("common", "vault", "sync"))
        modules = ((common, ("http",)), (sync, ("transport", "sync_cycle", "auth_owner")),
                   (vault, ("_ss", "_ss_v2", "_SecretService", "_file_get", "read", "store")))
        for module, names in modules:
            for name in names:
                if hasattr(module, name):
                    guard = patch.object(module, name, forbidden)
                    guard.start()
                    self.addCleanup(guard.stop)
        for name in ("CONFIG_DIR", "STATE_DIR", "CACHE_DIR", "DATA_DIR"):
            guard = patch.object(common, name, os.path.join(self.tmp.name, name.lower()), create=True)
            guard.start()
            self.addCleanup(guard.stop)
        for name in ("SYNC_STATE_PATH", "SYNC_REMOTE_PATH", "TOKEN_FILE_PATH", "HISTORY_PATH"):
            if hasattr(common, name):
                guard = patch.object(common, name, os.path.join(self.tmp.name, name.lower()))
                guard.start()
                self.addCleanup(guard.stop)
        for name in ("read", "stage_refresh", "delete", "login_backend"):
            guard = patch.object(vault.CredentialStore, name, forbidden)
            guard.start()
            self.addCleanup(guard.stop)
        auth_module = sys.modules.get("ccl.auth")
        if auth_module is not None:
            for name in ("read", "write"):
                guard = patch.object(auth_module.LinuxManifest, name, forbidden)
                guard.start()
                self.addCleanup(guard.stop)
        guard = patch("webbrowser.open", forbidden)
        guard.start()
        self.addCleanup(guard.stop)

    def harness(self, auth_module, **world_options):
        return OwnerHarness(auth_module, AuthWorld(**world_options))
