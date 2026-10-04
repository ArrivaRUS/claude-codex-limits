"""Durable GitHub credential owner. Dependencies are explicit; importing does no I/O.

Only this owner consumes a refresh token. Callers already holding the process sync
lock pass lock_held=True. Checkpoints carry a name only, never credential values.
"""
import base64
import copy
import json
import math
import secrets
import threading
from contextlib import contextmanager, nullcontext
from dataclasses import dataclass, field

MAX_LIFETIME = 10 * 366 * 86400
REFRESH_URL = "https://github.com/login/oauth/access_token"
CLIENT_ID = "Ov23lipk8voUWUAr59qS"


class RefreshNotSent(Exception):
    """Trusted adapter evidence that the issuer could not have received the body."""


@dataclass
class AuthRead:
    kind: str
    credential: dict = field(default=None, repr=False)
    ref: dict = None


@dataclass
class AccessResult:
    kind: str
    access: str = field(default=None, repr=False)
    epoch: str = None
    generation: str = None
    reason: str = None
    retry_at: float = None
    ref: dict = None


def lifetime(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value) if math.isfinite(value) and 0 < value <= MAX_LIFETIME else None


def _secret(value):
    return value if isinstance(value, str) and value and len(value) <= 16384 and all(
        c.isascii() and (c.isalnum() or c in "_-") for c in value) else None


def parse_issuance(body, epoch, generation, now, user_id=None, login=None, require_refresh=False):
    """Keep usable NEW values even in an incomplete response; never merge old secrets."""
    body = body if isinstance(body, dict) else {}
    access, refresh = _secret(body.get("access_token")), _secret(body.get("refresh_token"))
    ttl, refresh_ttl = lifetime(body.get("expires_in")), lifetime(body.get("refresh_token_expires_in"))
    return dict(schema=2, kind="credential" if access and (refresh or not require_refresh) else "incomplete",
                epoch=epoch, generation=generation, accessToken=access, refreshToken=refresh,
                obtainedAt=now, accessExpiresAt=now + ttl if ttl else None,
                refreshExpiresAt=now + refresh_ttl if refresh_ttl else None,
                tokenType="bearer", userID=user_id, login=login)


def encode_credential(value):
    return base64.urlsafe_b64encode(json.dumps(value, allow_nan=False, ensure_ascii=True,
                                             separators=(",", ":"), sort_keys=True).encode()).decode().rstrip("=")


def decode_credential(payload, ref=None):
    try:
        if not isinstance(payload, str) or len(payload) > 100000 or not payload.isascii():
            return None
        obj = json.loads(base64.b64decode(payload + "=" * (-len(payload) % 4), altchars=b"-_", validate=True))
        if not isinstance(obj, dict) or obj.get("schema") != 2 or obj.get("kind") not in ("credential", "incomplete"):
            return None
        if not all(isinstance(obj.get(k), str) and obj[k] for k in ("epoch", "generation")):
            return None
        if ref and (obj["generation"] != ref.get("generation") or obj["epoch"] != ref.get("epoch", obj["epoch"])):
            return None
        for k in ("accessToken", "refreshToken"):
            if obj.get(k) is not None and not _secret(obj[k]):
                return None
        if obj["kind"] == "credential" and not obj.get("accessToken"):
            return None
        for k in ("obtainedAt", "accessExpiresAt", "refreshExpiresAt"):
            v = obj.get(k)
            if v is not None and (isinstance(v, bool) or not isinstance(v, (float, int)) or not math.isfinite(v)):
                return None
        return obj
    except (ValueError, TypeError, UnicodeError, RecursionError):
        return None


def _identifier(value):
    return isinstance(value, str) and 0 < len(value) <= 128 and value.isascii()


def _timestamp(value):
    return (not isinstance(value, bool) and isinstance(value, (int, float))
            and math.isfinite(value) and 0 <= value <= 32503680000)


def valid_ref(ref):
    if not (isinstance(ref, dict) and _identifier(ref.get("generation"))
            and all(c in "0123456789abcdef-" for c in ref["generation"])
            and ref.get("backend") in ("file", "secret-service", "keychain")):
        return False
    if "epoch" in ref and not _identifier(ref["epoch"]):
        return False
    if "uncertain" in ref and type(ref["uncertain"]) is not bool:
        return False
    if "writeProtocol" in ref and (type(ref["writeProtocol"]) is not int or ref["writeProtocol"] != 2):
        return False
    pids = ref.get("writerPIDs", [])
    if not isinstance(pids, list) or len(pids) > 1024:
        return False
    if "writerPID" in ref:
        pids = pids + [ref["writerPID"]]
    return all(type(pid) is int and 0 < pid < 2 ** 31 for pid in pids)


def validate_manifest(m):
    if (not isinstance(m, dict) or type(m.get("formatVersion")) is not int or m["formatVersion"] != 2
            or not _identifier(m.get("epoch")) or (m.get("active") is not None and not valid_ref(m["active"]))
            or not isinstance(m.get("cleanupRefs", []), list) or len(m.get("cleanupRefs", [])) > 10000
            or not all(valid_ref(ref) for ref in m.get("cleanupRefs", []))):
        raise ValueError("corrupt manifest")
    for key in ("signedOut", "compatibilityChanged", "refreshDisabled"):
        if key in m and type(m[key]) is not bool:
            raise ValueError("corrupt manifest flag")
    if m.get("retryAt") is not None and not _timestamp(m["retryAt"]):
        raise ValueError("corrupt retry date")
    if type(m.get("failures", 0)) is not int or not 0 <= m.get("failures", 0) <= 3:
        raise ValueError("corrupt failure counter")
    for key in ("login", "userID", "failureReason"):
        if m.get(key) is not None and (not isinstance(m[key], str) or len(m[key]) > 1024):
            raise ValueError("corrupt manifest metadata")
    t = m.get("transition")
    if t is not None:
        if (not isinstance(t, dict) or not valid_ref(t.get("to"))
                or t.get("phase") not in ("prepared", "requestStarted", "ready", "validationPending")
                or t.get("type") not in ("login", "refresh")
                or type(t.get("recoveryAttempts", 0)) is not int or not 0 <= t.get("recoveryAttempts", 0) <= 1):
            raise ValueError("corrupt transition")
        for key in ("from", "probe"):
            if t.get(key) is not None and not valid_ref(t[key]):
                raise ValueError("corrupt transition reference")
        for key in ("unknown", "stageUncertain", "candidateSource", "loginChain"):
            if key in t and type(t[key]) is not bool:
                raise ValueError("corrupt transition flag")
        if t.get("candidateSource") and not valid_ref(t.get("from")):
            raise ValueError("missing candidate source")
        for key in ("targetEpoch", "attemptID"):
            if key in t and not _identifier(t[key]):
                raise ValueError("corrupt transition identity")
    return m


class AuthOwner:
    """manifest.read/write; store.read/stage_refresh/delete; transport(url,fields).

    Transport returns (status, JSON object or None, headers). identity(access)
    returns (status, JSON user or None, headers). lock() yields a held boolean.
    legacy() returns AuthRead. No dependency is silently supplied by this class.
    """
    def __init__(self, manifest, store, transport, identity, lock, clock, checkpoint=lambda point: None,
                 jitter=lambda: 0, legacy=lambda: AuthRead("signedOut"), defer=lambda: nullcontext(),
                 publication_lock=lambda: nullcontext()):
        self.manifest, self.store, self.transport, self.identity = manifest, store, transport, identity
        self.lock, self.clock, self.checkpoint, self.jitter = lock, clock, checkpoint, jitter
        self.legacy, self.defer = legacy, defer
        self.publication_lock = publication_lock
        self._login_cancellations = {}
        self._calls = threading.local()
        self._memory = {}
        self._snapshot = dict(kind="signedOut", reason=None, retryAt=None)

    @contextmanager
    def _grant_scope(self):
        # One refresh transport attempt for the entire public operation. Nested
        # helpers/recovery paths share it; another thread cannot reset it while
        # waiting for the auth lock. A subsequent ensure starts a fresh budget.
        previous = getattr(self._calls, "budget", None)
        self._calls.budget = previous if previous is not None else [0]
        try:
            yield
        finally:
            if previous is None:
                del self._calls.budget
            else:
                self._calls.budget = previous

    def _grant_available(self):
        budget = getattr(self._calls, "budget", None)
        return budget is not None and budget[0] < 1

    def _take_grant(self):
        if not self._grant_available():
            return False
        self._calls.budget[0] += 1
        return True

    def snapshot(self):
        return dict(self._snapshot)

    def _result(self, kind, c=None, ref=None, reason=None, retry_at=None):
        self._snapshot = dict(kind=kind, reason=reason, retryAt=retry_at,
                              login=(c or {}).get("login"), backend=(ref or {}).get("backend"))
        return AccessResult(kind, (c or {}).get("accessToken"), (c or {}).get("epoch"),
                            (c or {}).get("generation"), reason, retry_at, ref)

    def _load(self):
        m = self.manifest.read()
        if m is None:
            return None
        validate_manifest(m)
        return copy.deepcopy(m)

    def read_credential(self):
        try:
            m = self._load()
            if m is None:
                return self.legacy()
            if m.get("signedOut") or m.get("compatibilityChanged"):
                return AuthRead("signedOut")
            if not m.get("active"):
                return AuthRead("missing")
            r = self.store.read(m["active"])
            if r.kind != "ready":
                return r
            c = decode_credential(r.credential, m["active"])
            if not c or c["kind"] != "credential" or c["epoch"] != m["epoch"]:
                return AuthRead("corrupt", ref=m["active"])
            return AuthRead("ready", c, m["active"])
        except (OSError, ValueError):
            return AuthRead("corrupt")

    def _save(self, m):
        validate_manifest(m)
        self.manifest.write(copy.deepcopy(m))

    def _temporary(self, m, reason, now, headers=None):
        n = min(int(m.get("failures", 0)), 2)
        delay = min(600, (60, 300, 600)[n] + max(0, min(10, self.jitter())))
        headers = {str(k).lower(): v for k, v in (headers or {}).items()}
        try:
            retry = float(headers.get("retry-after", 0))
            reset = float(headers.get("x-ratelimit-reset", 0)) if str(headers.get("x-ratelimit-remaining")) == "0" else 0
            if math.isfinite(retry) and retry >= 0:
                delay = max(delay, retry)
            if math.isfinite(reset):
                delay = max(delay, reset - now)
        except (ValueError, TypeError):
            pass
        m.update(retryAt=now + delay, failureReason=reason, failures=n + 1)
        self._save(m)
        return self._result("temporary", reason=reason, retry_at=m["retryAt"])

    def _terminal(self, m, reason, now):
        # Read candidate once more before interpreting a terminal issuer response.
        t = m.get("transition")
        if t:
            r = self.store.read(t["to"])
            if r.kind == "ready" and decode_credential(r.credential, t["to"]):
                return self._finish(m, now)
            if r.kind != "missing":
                return self._temporary(m, r.kind, now)
        m.update(failureReason=reason, retryAt=None, refreshDisabled=True)
        self._save(m)
        if (m.get("transition") or {}).get("candidateSource"):
            return self._result("actionRequired", reason=reason)
        r = self.read_credential()
        if r.kind == "ready" and (r.credential.get("accessExpiresAt") is None or now < r.credential["accessExpiresAt"]):
            return self._result("ready", r.credential, r.ref, reason)
        return self._result("actionRequired", reason=reason)

    def _write_settled(self, ref):
        check = getattr(self.store, "write_settled", None)
        return bool(check(ref)) if check else False

    def _new_ref(self, backend, epoch):
        ref = dict(generation=secrets.token_hex(16), backend=backend, epoch=epoch)
        writer_id = getattr(self.store, "writer_id", None)
        if writer_id is not None:
            ref["writerPID"] = writer_id
        return ref

    @staticmethod
    def _same_ref(a, b):
        return bool(a and b and all(a.get(k) == b.get(k) for k in ("generation", "backend", "epoch")))

    def _reserve_write(self, m, ref):
        # Durable before EVERY possible writer, including identity finalization.
        # A successful later writer does not prove an earlier timed-out writer
        # has finished. Its uncertainty survives supersession, publish and logout.
        earlier_uncertain = bool(ref.get("uncertain"))
        ref["uncertain"] = True
        # Every v2 backend RPC has a synchronously durable pending receipt
        # before worker launch. An absent receipt is therefore proven no-send.
        if not earlier_uncertain or ref.get("writeProtocol") == 2:
            ref["writeProtocol"] = 2
        writer = getattr(self.store, "writer_id", None)
        if writer is not None:
            pids = list(ref.get("writerPIDs", [ref["writerPID"]] if ref.get("writerPID") else [])) if earlier_uncertain else []
            if writer not in pids:
                pids.append(writer)
            ref["writerPIDs"] = pids
        self._save(m)
        return earlier_uncertain

    def _stage(self, m, ref, payload, reserved_prior=None):
        earlier_uncertain = self._reserve_write(m, ref) if reserved_prior is None else reserved_prior
        status = self.store.stage_refresh(ref, payload)
        if (status in ("ready", "failure") and not earlier_uncertain) or self._write_settled(ref):
            ref.pop("uncertain", None)
        self._save(m)
        return status

    def _cleanup(self, m):
        remaining = []
        for ref in m.get("cleanupRefs", []):
            transition = m.get("transition") or {}
            protected = (m.get("active"), transition.get("to"), transition.get("probe"),
                         transition.get("from") if transition.get("candidateSource") else None)
            if any(self._same_ref(ref, r) for r in protected):
                continue
            # Readability proves neither completion nor absence of another writer.
            if ref.get("uncertain") and not self._write_settled(ref):
                remaining.append(ref)
                continue
            if self.store.delete(ref) != "ready":
                remaining.append(ref)
        if remaining != m.get("cleanupRefs", []):
            m["cleanupRefs"] = remaining
            self._save(m)

    def _login_cancelled(self, t):
        if t.get("attemptID") is not None and self.manifest.current_attempt() != t["attemptID"]:
            return True
        check = self._login_cancellations.get(t["to"]["generation"])
        return (t.get("type") == "login" or t.get("loginChain")) and check is not None and check()

    def _abort_login(self, m):
        t = m["transition"]
        ref = t["to"]
        m.setdefault("cleanupRefs", []).append(copy.deepcopy(ref))
        for predecessor in (t.get("from") if t.get("candidateSource") else None, t.get("probe")):
            if predecessor:
                m["cleanupRefs"].append(copy.deepcopy(predecessor))
                self._memory.pop(predecessor["generation"], None)
                self._login_cancellations.pop(predecessor["generation"], None)
        m["transition"] = None
        m.update(retryAt=None, failureReason=None)
        if not m.get("active"):
            m["signedOut"] = True
        self._save(m)  # Recovery can no longer publish the abandoned attempt.
        self._login_cancellations.pop(ref["generation"], None)
        self._memory.pop(ref["generation"], None)
        self._cleanup(m)
        return self._result("signedOut", reason="cancelled")

    def _finish(self, m, now, allow_candidate_renew=True):
        t = m["transition"]
        ref = t["to"]
        if m.get("signedOut"):
            return self._result("signedOut")
        if self._login_cancelled(t):
            return self._abort_login(m)
        c = self._memory.get(ref["generation"])
        if c is not None:
            existing = self.store.read(ref)
            if existing.kind != "ready" or decode_credential(existing.credential, ref) != c:
                if self._stage(m, ref, encode_credential(c)) != "ready":
                    return self._temporary(m, "storage_write", now)
        r = self.store.read(ref)
        if r.kind != "ready":
            return self._temporary(m, r.kind, now)
        c = decode_credential(r.credential, ref)
        if not c or c["epoch"] != t.get("targetEpoch", m["epoch"]):
            return self._temporary(m, "corrupt", now)
        self.checkpoint("after_readback")
        self._memory.pop(ref["generation"], None)
        if c["kind"] == "incomplete":
            m.update(failureReason="incomplete_response", retryAt=None, refreshDisabled=True)
            self._save(m)
            return self._result("actionRequired", reason="incomplete_response")
        t["phase"] = "validationPending"
        self._save(m)
        if c.get("accessExpiresAt") is not None and now >= c["accessExpiresAt"] and c.get("refreshToken"):
            return self._renew_candidate(m, c, now, allow_candidate_renew)
        self.checkpoint("before_identity")
        status, user, headers = self.identity(c["accessToken"])
        self.checkpoint("after_identity")
        if self._login_cancelled(t):
            return self._abort_login(m)
        if status == 401 and c.get("refreshToken"):
            return self._renew_candidate(m, c, now, allow_candidate_renew)
        uid = user.get("id") if isinstance(user, dict) else None
        login = user.get("login") if isinstance(user, dict) else None
        if status != 200 or isinstance(uid, bool) or not isinstance(uid, (int, str)) or not str(uid) or not isinstance(login, str) or not login.strip():
            return self._temporary(m, "identity_pending", now, headers)
        if c.get("userID") is not None and str(uid) != str(c["userID"]):
            m.update(failureReason="identity_changed", retryAt=None, refreshDisabled=True)
            self._save(m)
            return self._result("actionRequired", reason="identity_changed")
        if c.get("userID") != str(uid) or c.get("login") != login.strip():
            c.update(userID=str(uid), login=login.strip())
            self._memory[ref["generation"]] = c
            if self._stage(m, ref, encode_credential(c)) != "ready":
                return self._temporary(m, "storage_write", now)
            verified = self.store.read(ref)
            if verified.kind != "ready" or decode_credential(verified.credential, ref) != c:
                return self._temporary(m, "storage_write", now)
            self._memory.pop(ref["generation"], None)
        self.checkpoint("before_publish")
        with self.publication_lock():
            if self._login_cancelled(t):
                return self._abort_login(m)
            current = self._load()
            if (current.get("epoch") != m["epoch"] or current.get("signedOut") or current.get("compatibilityChanged")
                    or not self._same_ref((current.get("transition") or {}).get("to"), ref)):
                return self._result("signedOut")
            old = m.get("active")
            if old and not self._same_ref(old, ref):
                m.setdefault("cleanupRefs", []).append(old)
            if t.get("candidateSource") and not self._same_ref(t.get("from"), old):
                m.setdefault("cleanupRefs", []).append(copy.deepcopy(t["from"]))
            m.update(epoch=c["epoch"], active=ref, transition=None, login=c["login"], userID=c["userID"],
                     retryAt=None, failureReason=None, failures=0, refreshDisabled=False)
            self._save(m)
            self._login_cancellations.pop(ref["generation"], None)
        self.checkpoint("after_publish")
        self.checkpoint("before_retire")
        self._cleanup(m)
        self.checkpoint("after_retire")
        return self._result("ready", c, ref)

    def _renew_candidate(self, m, c, now, allowed):
        """Renew a durable, still-unpublished credential without reviving active.

        The successor journal has exactly the same crash/budget/store guarantees
        as normal refresh. No unvalidated candidate becomes an active pointer.
        """
        t = m["transition"]
        if not allowed or not self._grant_available():
            return self._temporary(m, "identity_pending", now)
        if m.get("refreshDisabled"):
            return self._result("actionRequired", reason=m.get("failureReason"))
        if c.get("refreshExpiresAt") is not None and now >= c["refreshExpiresAt"]:
            m.update(refreshDisabled=True, retryAt=None, failureReason="refresh_expired")
            self._save(m)
            return self._result("actionRequired", reason="refresh_expired")
        source = copy.deepcopy(t["to"])
        successor = self._new_ref(source["backend"], c["epoch"])
        follow = dict(type="refresh", candidateSource=True, loginChain=t.get("type") == "login" or bool(t.get("loginChain")),
                      targetEpoch=c["epoch"], **{"from": source}, to=successor,
                      phase="prepared", recoveryAttempts=0, unknown=False)
        if t.get("attemptID") is not None:
            follow["attemptID"] = t["attemptID"]
        callback = self._login_cancellations.pop(source["generation"], None)
        if callback is not None:
            self._login_cancellations[successor["generation"]] = callback
        self.checkpoint("before_intent")
        if t.get("candidateSource"):
            # Its refresh was consumed to produce the now-durable source. It is
            # no longer needed for recovery, but its cleanup fence is retained.
            m.setdefault("cleanupRefs", []).append(copy.deepcopy(t["from"]))
        if t.get("probe"):
            m.setdefault("cleanupRefs", []).append(copy.deepcopy(t["probe"]))
        m.update(transition=follow, retryAt=None, failureReason=None, failures=0)
        self._save(m)
        self.checkpoint("after_intent")
        return self._renew(m, c, now, allow_candidate_renew=False)

    def _renew(self, m, c, now, allow_candidate_renew=True):
        t = m.get("transition")
        if t:
            candidate = self.store.read(t["to"])
            if candidate.kind == "ready" or t["to"]["generation"] in self._memory:
                return self._finish(m, now, allow_candidate_renew=allow_candidate_renew)
            if candidate.kind != "missing":
                return self._temporary(m, candidate.kind, now)
            if t["to"].get("uncertain") and not self._write_settled(t["to"]):
                return self._temporary(m, "storage_write", now)
            if t["phase"] in ("ready", "validationPending"):
                return self._temporary(m, "candidate_missing", now)
            if t["phase"] == "requestStarted":
                t["unknown"] = True
            if t.get("unknown"):
                if t.get("recoveryAttempts", 0) >= 1:
                    return self._terminal(m, "lost_result", now)
                self._save(m)
        else:
            ref = self._new_ref(m["active"]["backend"], m["epoch"])
            t = dict(type="refresh", **{"from": m["active"]}, to=ref, phase="prepared", recoveryAttempts=0, unknown=False)
            self.checkpoint("before_intent")
            m["transition"] = t
            self._save(m)
            self.checkpoint("after_intent")
        if not self._grant_available():
            return self._temporary(m, "identity_pending", now)
        # Probe is durable and distinct from BOTH credential references. Uncertain
        # probe writes block the issuer until observed, never silently fall back.
        probe = t.get("probe")
        if probe:
            r = self.store.read(probe)
            if r.kind == "missing" and self._write_settled(probe):
                m["cleanupRefs"] = [x for x in m["cleanupRefs"] if x != probe]
                t.pop("probe", None)
                self._save(m)
                return self._temporary(m, "probe_pending", now)
            if r.kind != "ready":
                return self._temporary(m, "probe_pending", now)
        else:
            probe = self._new_ref(t["to"]["backend"], m["epoch"])
            t["probe"] = probe
            m.setdefault("cleanupRefs", []).append(probe)
            self._save(m)
            probe_payload = encode_credential(dict(schema=2, kind="incomplete", epoch=m["epoch"], generation=probe["generation"]))
            probe_status = self._stage(m, probe, probe_payload)
            if probe_status != "ready":
                if probe_status == "failure":  # proven failure before any write
                    m["cleanupRefs"] = [x for x in m["cleanupRefs"] if x != probe]
                    t.pop("probe", None)
                return self._temporary(m, "probe_pending", now)
            r = self.store.read(probe)
            if r.kind != "ready" or r.credential != probe_payload:
                return self._temporary(m, "probe_pending", now)
        if probe.get("uncertain") and not self._write_settled(probe):
            return self._temporary(m, "probe_pending", now)
        # Leave a durable cleanup ref even if a backend reports uncertain deletion.
        if (not probe.get("uncertain") or self._write_settled(probe)) and self.store.delete(probe) == "ready":
            m["cleanupRefs"] = [x for x in m["cleanupRefs"] if x != probe]
        t.pop("probe", None)
        if not self._take_grant():
            return self._temporary(m, "identity_pending", now)
        was_unknown = bool(t.get("unknown"))
        if was_unknown:
            t["recoveryAttempts"] = t.get("recoveryAttempts", 0) + 1
        t["phase"] = "requestStarted"
        reserved_prior = self._reserve_write(m, t["to"])
        self.checkpoint("after_request_started")
        with self.defer():
            try:
                status, body, headers = self.transport(REFRESH_URL, dict(client_id=CLIENT_ID,
                    grant_type="refresh_token", refresh_token=c["refreshToken"]))
            except RefreshNotSent:
                if not reserved_prior:
                    t["to"].pop("uncertain", None)
                t["phase"] = "requestStarted" if was_unknown else "prepared"
                if was_unknown:
                    t["recoveryAttempts"] -= 1
                return self._temporary(m, "network", now)
            self.checkpoint("after_response")
            candidate = parse_issuance(body, t.get("targetEpoch", m["epoch"]), t["to"]["generation"], now,
                                       c.get("userID"), c.get("login"), require_refresh=True)
            self.checkpoint("after_parse")
            if candidate.get("accessToken") or candidate.get("refreshToken"):
                self._memory[t["to"]["generation"]] = candidate
                saved = self._stage(m, t["to"], encode_credential(candidate), reserved_prior=reserved_prior)
                self.checkpoint("after_stage")
                if saved != "ready":
                    t["stageUncertain"] = True
                    return self._temporary(m, "storage_write", now)
                t["stageUncertain"] = False
                t["phase"] = "ready"
                self._save(m)
        if candidate.get("accessToken") or candidate.get("refreshToken"):
            return self._finish(m, now, allow_candidate_renew=allow_candidate_renew)
        if not reserved_prior:
            t["to"].pop("uncertain", None)
        if isinstance(body, dict) and body.get("error") == "bad_refresh_token" and status in (200, 400, 401):
            return self._terminal(m, "lost_result" if t.get("unknown") else "refresh_invalid", now)
        if status in (403, 429) and not t.get("unknown"):
            t["phase"] = "prepared"
        else:
            t["unknown"] = True
            t["phase"] = "requestStarted"
        return self._temporary(m, "network" if status == 0 else "issuer_pending", now, headers)

    def ensure_access(self, reason="sync", now=None, lock_held=False):
        now = self.clock() if now is None else now
        try:
            with (nullcontext(True) if lock_held else self.lock()) as held, self._grant_scope():
                if not held:
                    return self._result("temporary", reason="busy")
                m = self._load()
                if m is None:
                    r = self.legacy()
                    return self._result("ready", r.credential, r.ref) if r.kind == "ready" else self._result(
                        "signedOut" if r.kind == "signedOut" else "actionRequired" if r.kind == "missing" else "temporary", reason=r.kind)
                if m.get("signedOut") or m.get("compatibilityChanged"):
                    return self._result("signedOut")
                if m.get("transition") and self._login_cancelled(m["transition"]):
                    return self._abort_login(m)
                if m.get("retryAt", 0) and now < m["retryAt"]:
                    return self._result("temporary", reason=m.get("failureReason"), retry_at=m["retryAt"])
                self._cleanup(m)
                if m.get("transition"):
                    t = m["transition"]
                    r = self.store.read(t["to"])
                    if r.kind == "ready" or t["to"]["generation"] in self._memory:
                        return self._finish(m, now)
                    if t.get("type") == "login":
                        return self._temporary(m, "candidate_missing", now)
                    if t.get("candidateSource"):
                        if m.get("refreshDisabled"):
                            return self._result("actionRequired", reason=m.get("failureReason"))
                        source = self.store.read(t["from"])
                        if source.kind != "ready":
                            return self._temporary(m, source.kind, now)
                        credential = decode_credential(source.credential, t["from"])
                        if not credential or credential.get("kind") != "credential" or not credential.get("refreshToken"):
                            return self._temporary(m, "corrupt", now)
                        if (credential.get("refreshExpiresAt") is not None and now >= credential["refreshExpiresAt"]
                                and t["phase"] == "prepared" and not t.get("unknown")):
                            return self._terminal(m, "refresh_expired", now)
                        return self._renew(m, credential, now)
                r = self.read_credential()
                if r.kind != "ready":
                    return self._temporary(m, r.kind, now) if r.kind != "missing" else self._result("actionRequired", reason="missing")
                c = r.credential
                if m.get("refreshDisabled"):
                    return self._result("ready", c, r.ref, m.get("failureReason")) if reason != "access401" and (
                        c.get("accessExpiresAt") is None or now < c["accessExpiresAt"]) else self._result("actionRequired", reason=m.get("failureReason"))
                expiry = c.get("accessExpiresAt")
                lead = min(900, max(0, expiry - c["obtainedAt"]) / 4) if expiry else 0
                due = bool(m.get("transition")) or reason == "access401" or (expiry is not None and now >= expiry - lead)
                if not due or not c.get("refreshToken"):
                    return self._result("ready", c, r.ref)
                if c.get("refreshExpiresAt") is not None and now >= c["refreshExpiresAt"] and not m.get("transition"):
                    return self._terminal(m, "refresh_expired", now)
                return self._renew(m, c, now)
        except (OSError, ValueError):
            return self._result("temporary", reason="manifest_unavailable")

    def accept_login(self, issuance, backend, cancelled=lambda: False, lock_held=False, attempt_id=None):
        """Explicit login only. Caller selects its existing approved backend policy."""
        with (nullcontext(True) if lock_held else self.lock()) as held, self._grant_scope():
            if not held:
                return self._result("temporary", reason="busy")
            old = self._load()
            if attempt_id is not None and self.manifest.current_attempt() != attempt_id:
                return self._result("signedOut", reason="cancelled")
            if cancelled():
                return self._result("signedOut")
            epoch = secrets.token_hex(16)
            ref = self._new_ref(backend, epoch)
            generation = ref["generation"]
            c = parse_issuance(issuance, epoch, generation, self.clock())
            if not c.get("accessToken"):
                return self._result("actionRequired", reason="incomplete_response")
            cleanup = list((old or {}).get("cleanupRefs", []))
            old_transition = (old or {}).get("transition") or {}
            for x in (old_transition.get("to"), old_transition.get("probe"),
                      old_transition.get("from") if old_transition.get("candidateSource") else None):
                if x:
                    cleanup.append(copy.deepcopy(x))
            m = dict(old or dict(formatVersion=2, epoch=epoch, active=None))
            if m.pop("compatibilityChanged", False):
                if m.get("active"):
                    cleanup.append(m["active"])
                m.update(epoch=epoch, active=None)
                m.pop("login", None)
                m.pop("userID", None)
            m.update(transition=dict(type="login", to=ref, targetEpoch=epoch,
                     phase="ready", recoveryAttempts=0), cleanupRefs=cleanup, retryAt=None, failureReason=None, signedOut=False)
            if attempt_id is not None:
                m["transition"]["attemptID"] = attempt_id
            try:
                self._save(m)
                self._memory[generation] = c
                self._login_cancellations[generation] = cancelled
                stage_status = self._stage(m, ref, encode_credential(c))
                # Cancellation during a timed-out writer must remove the durable
                # transition before this process releases the auth lock. A late
                # candidate is cleanup-only, including for another process.
                if cancelled():
                    return self._abort_login(m)
                if stage_status != "ready":
                    return self._temporary(m, "storage_write", self.clock())
                return self._finish(m, self.clock())
            except BaseException:
                # SIGINT is delivered before CLI's outer catch can set its
                # process-local cancelled flag. Treat all escaping errors as an
                # abandoned explicit attempt while we still hold the auth lock.
                with self.defer():
                    current = self._load()
                    if current and (self._same_ref((current.get("transition") or {}).get("to"), ref)
                                    or ((current.get("transition") or {}).get("loginChain")
                                        and (current.get("transition") or {}).get("targetEpoch") == epoch)):
                        self._abort_login(current)
                raise
            finally:
                # Covers cancellation while _temporary saves its retry metadata,
                # and every other early-return path. Never cancel a newer login.
                if cancelled():
                    with self.defer():
                        current = self._load()
                        if current and (self._same_ref((current.get("transition") or {}).get("to"), ref)
                                    or ((current.get("transition") or {}).get("loginChain")
                                        and (current.get("transition") or {}).get("targetEpoch") == epoch)):
                            self._abort_login(current)

    def logout(self, lock_held=False):
        with (nullcontext(True) if lock_held else self.lock()) as held:
            if not held:
                return False
            m = self._load()
            if m is None:
                return True
            refs = list(m.get("cleanupRefs", []))
            transition = m.get("transition") or {}
            for r in (m.get("active"), transition.get("to"), transition.get("probe"),
                      transition.get("from") if transition.get("candidateSource") else None):
                if r and r not in refs:
                    r = dict(r)
                    # Every interrupted transition can still have a late writer.
                    if r == (m.get("transition") or {}).get("to") and (m.get("transition") or {}).get("stageUncertain"):
                        r["uncertain"] = True
                    refs.append(r)
            m = dict(formatVersion=2, epoch=secrets.token_hex(16), active=None, transition=None,
                     cleanupRefs=refs, signedOut=True, retryAt=None, failureReason="signedOut")
            self._save(m)
            self.checkpoint("after_logout_tombstone")
            self._memory.clear()
            self._login_cancellations.clear()
            self._cleanup(m)
            self._result("signedOut")
            return not m["cleanupRefs"]


class LinuxManifest:
    """Atomic authV2 inside existing sync state; all other sync fields survive.

    read() is strict: an unreadable/corrupt file is never an empty session. The
    caller holds the sync flock; the store flock also excludes unrelated writers.
    """
    def _read_file(self):
        from . import common
        try:
            with open(common.SYNC_STATE_PATH, "r", encoding="utf-8") as f:
                obj = json.load(f)
        except FileNotFoundError:
            return {}
        if not isinstance(obj, dict):
            raise ValueError("corrupt sync state")
        if "authV2" in obj:
            validate_manifest(obj["authV2"])
        if obj.get("loginAttempt") is not None and not _identifier(obj["loginAttempt"]):
            raise ValueError("corrupt login attempt")
        return obj

    def current_attempt(self):
        attempt = self._read_file().get("loginAttempt")
        if attempt is not None and not _identifier(attempt):
            raise ValueError("corrupt login attempt")
        return attempt

    def read(self):
        obj = self._read_file()
        m = obj.get("authV2")
        if m is None:
            return None
        m = copy.deepcopy(m)
        if not isinstance(m, dict):
            raise ValueError("corrupt auth state")
        expected = (m.get("active") or {}).get("generation") or m.get("epoch")
        if not m.get("signedOut") and (obj.get("tokenBackend") != "credential-v2" or obj.get("tokenGeneration") != expected
                                      or (m.get("login") and obj.get("login") != m["login"])):
            m["compatibilityChanged"] = True
        return m

    def write(self, manifest):
        import os
        from . import common
        with common.file_lock("store-" + os.path.basename(common.SYNC_STATE_PATH)):
            obj = self._read_file()
            old_manifest = obj.get("authV2") or {}
            old_user = old_manifest.get("userID")
            # Invalidate the old account's disk cache BEFORE publishing a new
            # identity/epoch. In-memory consumers also check the cache binding.
            if manifest.get("active") and (old_manifest.get("epoch") != manifest["epoch"]
                                           or old_user != manifest.get("userID")):
                try:
                    os.unlink(common.SYNC_REMOTE_PATH)
                except FileNotFoundError:
                    pass
            obj["authV2"] = manifest
            obj["tokenBackend"] = "credential-v2"
            obj["tokenGeneration"] = (manifest.get("active") or {}).get("generation") or manifest["epoch"]
            if manifest.get("signedOut"):
                obj.pop("loginAttempt", None)
                obj.pop("login", None)
                obj["tokenGeneration"] = ""
                for key in ("gistId", "pushHash", "pushedAt", "lastOkAt", "discoveredAt", "lastSync", "revoked"):
                    obj.pop(key, None)
            elif manifest.get("login"):
                previous = obj.get("login")
                obj["login"] = manifest["login"]
                obj.pop("revoked", None)
                if previous != manifest["login"] and old_user != manifest.get("userID"):
                    for key in ("gistId", "pushHash", "pushedAt", "lastOkAt", "discoveredAt", "lastSync"):
                        obj.pop(key, None)
            if (manifest.get("transition") or {}).get("type") == "login":
                obj.pop("revoked", None)
            common.write_json(common.SYNC_STATE_PATH, obj)
