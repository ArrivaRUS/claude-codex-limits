"""Where the GitHub token lives: the desktop's Secret Service (KWallet / GNOME Keyring through
org.freedesktop.secrets) when it is reachable and unlocked, otherwise a 0600 file in
~/.config/claude-codex-limits/. The token is never printed or logged, not even in part.

Only non-interactive Secret Service calls are made: if the keyring would need a password
prompt (locked collection, no default collection), we fall back to the file rather than pop
a dialog from a background timer.

Every Secret Service operation runs under a deadline (`TIMEOUT`, docs/sync-protocol.md →
Errors): a keyring that hangs on D-Bus must not hold the sync cycle (and its lock) forever.
Test seams (replace before exercising sync/vault): `_ss` (Secret Service factory),
`TIMEOUT`, `_file_get` / `common.TOKEN_FILE_PATH` (file fallback), `sync.transport`
(all GitHub requests), `sync.REVOKE_RECHECK_DELAY` (variant a's recheck pause), and
`sync.LOGIN_LOCK_TIMEOUT` (sign-in/out lock deadline).
"""

import os
import fcntl
import json
import secrets
import signal
import threading
from contextlib import contextmanager
from threading import current_thread, main_thread

from . import common

ATTRS = {"application": "claude-codex-limits", "service": "github"}
LABEL = "Claude Codex Limits GitHub"

_SS = "org.freedesktop.secrets"
_SS_PATH = "/org/freedesktop/secrets"
_I_SERVICE = "org.freedesktop.Secret.Service"
_I_ITEM = "org.freedesktop.Secret.Item"
_I_COLLECTION = "org.freedesktop.Secret.Collection"
_worker = threading.local()


class _SecretServiceAbsent(Exception):
    """No Secret Service backend exists; other connection failures are retryable."""


class _SecretWriteNotStarted(Exception):
    """No mutating Secret Service request was sent."""


class _SecretWriteCompleted(Exception):
    """The server replied to CreateItem, but the returned item was unusable."""


class _SecretService(object):
    def __init__(self, attrs=None, label=None):
        self.attrs = attrs or ATTRS
        self.label = label or LABEL
        try:
            import dbus  # python3-dbus from the OS repository
        except ImportError as e:
            raise _SecretServiceAbsent() from e
        self.dbus = dbus
        try:
            self.bus = dbus.SessionBus(private=True)
        except FileNotFoundError as e:
            raise _SecretServiceAbsent() from e
        except dbus.DBusException as e:
            if e.get_dbus_name() in (
                    "org.freedesktop.DBus.Error.NotSupported",
                    "org.freedesktop.DBus.Error.FileNotFound",
                    "org.freedesktop.DBus.Error.NoServer"):
                raise _SecretServiceAbsent() from e
            raise
        # Register before the first D-Bus call, including a failing/hung constructor.
        _worker.buses.append(self.bus)
        try:
            obj = self.bus.get_object(_SS, _SS_PATH)
        except dbus.DBusException as e:
            if e.get_dbus_name() in (
                    "org.freedesktop.DBus.Error.ServiceUnknown",
                    "org.freedesktop.DBus.Error.NameHasNoOwner"):
                raise _SecretServiceAbsent() from e
            raise
        self.service = dbus.Interface(obj, _I_SERVICE)
        _, self.session = self.service.OpenSession("plain", dbus.String("", variant_level=1))

    def _unlocked(self, paths):
        """Unlock what can be unlocked without a prompt (a returned prompt is never run);
        returns the paths that are usable now."""
        if not paths:
            return []
        unlocked, _prompt = self.service.Unlock(self.dbus.Array(paths, signature="o"))
        return list(unlocked)

    def _paths(self, generation):
        attrs = dict(self.attrs, generation=generation) if generation != "legacy" else self.attrs
        unlocked, locked = self.service.SearchItems(attrs)
        if generation == "legacy":
            # SearchItems matches subsets: ATTRS alone also finds every new generation.
            def legacy(path):
                props = self.dbus.Interface(self.bus.get_object(_SS, path),
                                            "org.freedesktop.DBus.Properties")
                return props.Get(_I_ITEM, "Attributes").get("generation", "legacy") == "legacy"
            unlocked = [p for p in unlocked if legacy(p)]
            locked = [p for p in locked if legacy(p)]
        return list(unlocked), list(locked)

    def find(self, generation):
        unlocked, locked = self._paths(generation)
        items = unlocked + self._unlocked(locked)
        return items[0] if items else None

    def has_locked(self, generation):
        _unlocked, locked = self._paths(generation)
        return bool(locked) and not self._unlocked(locked)

    def get(self, generation):
        path = self.find(generation)
        if not path:
            return None
        item = self.dbus.Interface(self.bus.get_object(_SS, path), _I_ITEM)
        secret = item.GetSecret(self.session)
        value = bytes(bytearray(secret[2])).decode("utf-8").strip()
        return value or None

    def set(self, token, generation):
        try:
            dbus = self.dbus
            coll = self.service.ReadAlias("default")
            if coll == "/":
                raise RuntimeError("no default collection")
            if coll not in self._unlocked([coll]):
                raise RuntimeError("collection locked")
            c = dbus.Interface(self.bus.get_object(_SS, coll), _I_COLLECTION)
            props = {
                "org.freedesktop.Secret.Item.Label": dbus.String(self.label),
                "org.freedesktop.Secret.Item.Attributes": dbus.Dictionary(dict(self.attrs, generation=generation), signature="ss"),
            }
            secret = dbus.Struct((self.session, dbus.ByteArray(b""), dbus.ByteArray(token.encode("utf-8")),
                                  dbus.String("text/plain")), signature="oayays")
        except Exception as e:
            raise _SecretWriteNotStarted() from e
        # Any exception here can be NoReply/disconnect after the server accepted
        # CreateItem. Client completion/death cannot prove server completion.
        item, prompt = c.CreateItem(dbus.Dictionary(props, signature="sv"), secret, True)
        if item == "/" or prompt != "/":
            raise _SecretWriteCompleted("keyring asked for a prompt")

    def delete(self, generation):
        unlocked, locked = self._paths(generation)
        newly_unlocked = self._unlocked(locked)
        ok = set(locked).issubset(newly_unlocked)
        for path in unlocked + newly_unlocked:
            item = self.dbus.Interface(self.bus.get_object(_SS, path), _I_ITEM)
            if item.Delete() != "/":
                ok = False                    # a prompt is not a completed deletion
        return ok


def _ss():
    try:
        return _SecretService()
    except _SecretServiceAbsent:
        return None


TIMEOUT = 15.0          # seconds per Secret Service operation (connect + calls)


class Timeout(Exception):
    """The Secret Service didn't answer within TIMEOUT."""


def timeout_text():
    return common.tr("Хранилище секретов не ответило за %g с" % TIMEOUT,
                     "The Secret Service didn't answer in %g s" % TIMEOUT)


@contextmanager
def _sigint_deferred():
    """Replay at most one SIGINT after restoring the previous Python handler.

    Nested sections and non-main threads are no-ops, as are non-Python handlers
    and interpreters where signal.signal is unavailable. If the body also raises,
    a replayed KeyboardInterrupt wins; the body's exception stays in __context__.
    """
    if current_thread() is not main_thread():
        yield
        return
    prev = signal.getsignal(signal.SIGINT)
    if not callable(prev) or getattr(prev, "_ccl_sigint_deferred", False):
        yield
        return
    received = False
    interrupted_frame = None

    def defer(signum, frame):
        nonlocal received, interrupted_frame
        interrupted_frame = frame
        received = True

    # The installed handler itself identifies the outer section, without a separate
    # depth flag that could be left stale when installing/restoring a handler fails.
    defer._ccl_sigint_deferred = True
    try:
        signal.signal(signal.SIGINT, defer)
    except ValueError:
        yield
        return
    try:
        yield
    finally:
        signal.signal(signal.SIGINT, prev)
        if received:
            prev(signal.SIGINT, interrupted_frame)


def _timed(fn, on_transfer=None, on_not_started=None):
    """Run `fn` in a daemon thread and wait at most TIMEOUT. Raises Timeout (the thread is
    left behind — a hung D-Bus call can't be cancelled) or whatever `fn` raised."""
    box = {}
    abandoned = threading.Event()
    done = threading.Event()
    guard = threading.Lock()
    launch_gate = threading.Event()
    launch = {"transferred": False}

    def run():
        # A thread created by Thread.start may outlive an exception/SIGINT raised
        # by start itself. It cannot touch the caller's resource until this gate
        # explicitly transfers ownership; a revoked launch never calls fn.
        launch_gate.wait()
        with guard:
            permitted = launch["transferred"]
        if not permitted:
            return
        _worker.buses = []
        _worker.abandoned = abandoned
        _worker.cleanup = None
        try:
            box["v"] = fn()
        except BaseException as e:      # handed to the caller below
            box["e"] = e
        finally:
            # Completion and abandonment must be ordered even at the deadline boundary.
            with guard:
                cleanup = _worker.cleanup if abandoned.is_set() else None
                done.set()
            if cleanup is not None:
                try:
                    cleanup()
                except Exception:
                    pass                 # the reference remains eligible for a retry
            for bus in _worker.buses:
                try:
                    bus.close()
                except Exception:
                    pass
            del _worker.buses
            del _worker.abandoned
            del _worker.cleanup
    try:
        t = threading.Thread(target=run, name="ccl-vault", daemon=True)
        t.start()
        with guard:
            if on_transfer is not None:
                on_transfer()
            launch["transferred"] = True
        launch_gate.set()
        completed = done.wait(TIMEOUT)
        if not completed:
            with guard:
                if not done.is_set():
                    abandoned.set()
                    raise Timeout()
    except BaseException:
        try:
            with guard:
                if not launch["transferred"] and on_not_started is not None:
                    on_not_started()
                if not done.is_set():
                    abandoned.set()
        finally:
            # Also suppress a not-yet-started write if acquiring guard itself raises
            # (e.g. a second, directly raised KeyboardInterrupt, rather than SIGINT).
            abandoned.set()
        raise
    finally:
        launch_gate.set()
    if "e" in box:
        raise box["e"]
    return box.get("v")


def _ss_read(generation):
    """(token or None, locked), restricted to the captured generation."""
    ss = _ss()
    if ss is None:
        raise _SecretServiceAbsent()
    t = ss.get(generation)
    if t:
        return t, False
    return None, ss.has_locked(generation)


def _staged_path(generation):
    # Encode the reference so a generation read from state can never introduce a path.
    return common.TOKEN_FILE_PATH + ".pending-" + generation.encode("utf-8").hex()


def _file_get(generation="legacy", staged=False):
    try:
        with open(_staged_path(generation) if staged else common.TOKEN_FILE_PATH,
                  "r", encoding="utf-8") as f:
            lines = f.read().splitlines()
        stored_generation = lines[1] if len(lines) > 1 else "legacy"
        return (lines[0].strip() or None) if lines and stored_generation == generation else None
    except OSError:
        return None


def _file_set(token, generation):
    common.ensure_dirs()
    common.write_atomic(_staged_path(generation), token + "\n" + generation + "\n", 0o600)


def _file_delete(generation):
    # Mutating callers hold the sync lock, including this compare + unlink.
    try:
        os.unlink(_staged_path(generation))
    except FileNotFoundError:
        pass
    except OSError:
        return False
    # A hard kill before write_atomic's replace can leave this generation's temp.
    prefix = "." + os.path.basename(_staged_path(generation)) + "."
    try:
        names = os.listdir(common.CONFIG_DIR)
    except FileNotFoundError:
        names = []
    except OSError:
        return False
    for name in names:
        if name.startswith(prefix):
            try:
                os.unlink(os.path.join(common.CONFIG_DIR, name))
            except FileNotFoundError:
                pass
            except OSError:
                return False
    try:
        with open(common.TOKEN_FILE_PATH, "r", encoding="utf-8") as f:
            lines = f.read().splitlines()
        stored_generation = lines[1] if len(lines) > 1 else "legacy"
        if stored_generation == generation:
            os.unlink(common.TOKEN_FILE_PATH)
        return True
    except FileNotFoundError:
        return True
    except OSError:
        return False


def _delete_all_token_files():
    """Sweep crash remnants under the sync lock; unlink names, never symlink targets."""
    base = os.path.basename(common.TOKEN_FILE_PATH)
    try:
        names = os.listdir(common.CONFIG_DIR)
    except FileNotFoundError:
        return True
    except OSError:
        return False
    ok = True
    for name in names:
        # write_atomic's main and staged temp names both start with '.' + base + '.'.
        if (name == base or name.startswith(base + ".pending-") or
                name.startswith("." + base + ".")):
            try:
                os.unlink(os.path.join(common.CONFIG_DIR, name))
            except FileNotFoundError:
                pass
            except OSError:
                ok = False
    return ok


def active(st):
    # An explicit empty generation is a tombstone, never an invitation to migrate again.
    generation = st.get("tokenGeneration") if st.has("tokenGeneration") else "legacy"
    return generation, st.get("tokenBackend")


def _read(generation, backend):
    if not generation:
        return None, None
    # Only pre-generation installations with an unknown backend may discover a legacy copy.
    legacy_discovery = generation == "legacy" and backend is None
    if backend == "file":
        token = _file_get(generation)
        return (token, "file") if token else (None, None)
    if backend == "secret-service" or legacy_discovery:
        try:
            token, locked = _timed(lambda: _ss_read(generation))
            if token:
                return token, "secret-service"
            if locked:
                return None, "locked"
        except _SecretServiceAbsent:
            if not legacy_discovery:
                return None, "unreachable"
        except Timeout:
            return None, "timeout"
        except Exception:
            return None, "unreachable"
    if legacy_discovery:
        token = _file_get("legacy")
        if token:
            return token, "file"
    return None, None


def read():
    """Read only the active generation/backend; a timeout never falls through to a file.
    Installations without tokenGeneration still read their existing legacy token.
    """
    st = common.Store(common.SYNC_STATE_PATH)
    ref = active(st)
    result = _read(*ref)
    st.reload()
    return result if active(st) == ref else (None, None)


def reachable():
    try:
        return _timed(lambda: _ss() is not None)
    except Exception:
        return False


def _delete_stored(generation, backend):
    """Delete a captured reference, never whatever happens to be active later."""
    if not generation:
        return True
    legacy_discovery = generation == "legacy" and backend is None
    ok = True
    if backend == "secret-service" or legacy_discovery:
        def ss_delete():
            ss = _ss()
            return legacy_discovery if ss is None else ss.delete(generation)
        try:
            ok = bool(_timed(ss_delete))
        except Exception:
            ok = False
    if backend == "file" or legacy_discovery:
        ok = _file_delete(generation) and ok
    return ok


def _pending(st, *refs):
    pending = []
    for ref in list(st.get("tokenDeletePending") or []) + list(refs):
        ref = list(ref)
        if ref[0] and ref not in pending:
            pending.append(ref)
    return pending


def delete_ref(ref_or_generation, backend=None):
    """Delete only this reference; remember failures. Caller must hold the sync lock."""
    with _sigint_deferred():
        ref = list(ref_or_generation) if isinstance(ref_or_generation, (tuple, list)) else [ref_or_generation, backend]
        ok = _delete_stored(*ref)
        st = common.Store(common.SYNC_STATE_PATH)
        pending = _pending(st)
        if ok:
            pending = [p for p in pending if p != ref]
        else:
            pending = _pending(st, ref)
        if pending != (st.get("tokenDeletePending") or []):
            st.update(tokenDeletePending=pending or None)
        return ok


def store(token):
    """Store and verify a new, unpublished reference. Caller must hold the sync lock."""
    if not token or not all(c.isalnum() or c in "_-" for c in token):
        raise ValueError("unexpected token format")
    generation = secrets.token_hex(8)
    ss_write_started = threading.Event()
    st = common.Store(common.SYNC_STATE_PATH)
    ss_ref = [generation, "secret-service"]
    with _sigint_deferred():
        # Persist intent before a worker can create a copy, including one that outlives us.
        st.update(tokenDeletePending=_pending(st, ss_ref))

        def ss_write(generation=generation):
            ss = _ss()
            if ss is None:
                return None                   # no CreateItem was attempted
            _worker.cleanup = lambda: ss.delete(generation)
            # Publish intent before checking abandonment: after _timed abandons under its
            # guard, an unset flag guarantees this worker cannot subsequently call set.
            ss_write_started.set()
            if _worker.abandoned.is_set():
                return False
            ss.set(token, generation)
            if _worker.abandoned.is_set():
                ss.delete(generation)          # same connection as the late CreateItem
                _worker.cleanup = None
                return False
            return ss.get(generation) == token
        backend = "file"
        try:
            if _timed(ss_write):
                backend = "secret-service"
        except Exception:                   # incl. Timeout → a distinct file generation
            pass
        finally:
            # _timed marks abandonment before propagating BaseException/Timeout. A worker
            # that has not set this flag can no longer reach set after abandonment.
            if not ss_write_started.is_set():
                st = common.Store(common.SYNC_STATE_PATH)
                pending = [p for p in _pending(st) if p != ss_ref]
                st.update(tokenDeletePending=pending or None)
        if backend == "file":
            generation = secrets.token_hex(8)
            st = common.Store(common.SYNC_STATE_PATH)
            st.update(tokenDeletePending=_pending(st, [generation, "file"]))
            _file_set(token, generation)
            if _file_get(generation, staged=True) != token:
                delete_ref(generation, "file")
                raise OSError("could not save the token")
        return generation, backend


def publish(ref, cleanup=True):
    """Publish under the sync lock; optionally return old references for deferred retirement."""
    with _sigint_deferred():
        generation, backend = ref
        st = common.Store(common.SYNC_STATE_PATH)
        prev = active(st)
        if backend == "file":
            os.replace(_staged_path(generation), common.TOKEN_FILE_PATH)
        pending = _pending(st, prev)
        pending = [p for p in pending if p != list(ref)]
        st.update(tokenGeneration=generation, tokenBackend=backend, tokenDeletePending=pending or None)
    if not cleanup:
        return pending
    retire(pending)
    return backend


def retire(refs):
    """Retire captured copies after publication. Caller must still hold the sync lock."""
    # Each delete_ref is a section: pending already tracks the remaining copies,
    # so SIGINT need not wait through several consecutive Secret Service timeouts.
    for ref in refs:
        delete_ref(ref)


def write(token):
    """Store, verify and publish a new token. Caller must hold the sync lock."""
    return publish(store(token))


def delete():
    """Invalidate before deletion; retain failed references for a repeated sign-out.
    Caller must hold the sync lock. No delayed operation can address a newer generation.
    """
    with _sigint_deferred():
        st = common.Store(common.SYNC_STATE_PATH)
        pending = _pending(st, active(st))
        st.update(tokenGeneration="", tokenBackend=None, tokenDeletePending=pending)
    # Interruption between references is safe now that all copies are pending.
    for ref in pending:
        delete_ref(ref)
    with _sigint_deferred():
        # Addressed deletion cannot find files left between replace and state publication,
        # or write_atomic's temporary files. Sweep even when another deletion failed.
        files_deleted = _delete_all_token_files()
        if not files_deleted:
            st = common.Store(common.SYNC_STATE_PATH)
            st.update(tokenDeletePending=_pending(st, ["legacy", "file"]))
        return not common.Store(common.SYNC_STATE_PATH).get("tokenDeletePending")

# V2 uses a separate namespace. Legacy code must never interpret an envelope as
# a raw access token. Refresh writes are immutable-by-generation and NEVER use
# the abandoned-login cleanup or plaintext fallback in store().
def _ss_v2():
    try:
        return _SecretService(dict(ATTRS, service="github-credential-v2"), LABEL + " credential v2")
    except _SecretServiceAbsent:
        return None


def _v2_path(ref):
    from .auth import valid_ref
    if not valid_ref(ref):
        raise ValueError("invalid credential reference")
    return os.path.join(common.CONFIG_DIR, "github-credentials", ref["generation"])


class CredentialStore:
    _writes = {}  # process-wide: another owner must see every late local writer

    def __init__(self):
        self.writer_id = os.getpid()

    def _writer_lock_path(self, ref):
        _v2_path(ref)  # validate generation before constructing a path
        return os.path.join(common.STATE_DIR, "github-credential-writers", ref["generation"] + ".lock")

    def _writer_receipt(self, ref):
        return self._writer_lock_path(ref) + ".receipt"

    def _mark_server(self, ref, settled):
        # Nonsecret acknowledgement only. Persist pending BEFORE the DBus call;
        # only a completed backend reply (or proven no-send) can replace it.
        common.write_json(self._writer_receipt(ref), {"settled": settled}, mode=0o600)

    def _receipt_state(self, ref):
        try:
            with open(self._writer_receipt(ref), "r", encoding="utf-8") as f:
                receipt = json.load(f)
        except FileNotFoundError:
            return "absent"
        except (OSError, ValueError, UnicodeError):
            return "unknown"
        if isinstance(receipt, dict) and type(receipt.get("settled")) is bool:
            return "settled" if receipt["settled"] else "pending"
        return "unknown"

    def write_settled(self, ref):
        path = self._writer_lock_path(ref)
        try:
            fd = os.open(path, os.O_RDWR)
        except FileNotFoundError:
            # writeProtocol=2 is durable before stage is reachable. Every RPC
            # requires a durable pending receipt before Thread.start; therefore
            # absence here proves no-send, not completion of an unknown RPC.
            # The caller holds the auth lock, excluding a future stage launcher.
            return ref.get("writeProtocol") == 2 and self._receipt_state(ref) == "absent"
        except OSError:
            return False
        try:
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                return False
            if ref["backend"] == "file":
                return True  # No external daemon can finish a dead file writer.
            state = self._receipt_state(ref)
            return state == "settled" or (state == "absent" and ref.get("writeProtocol") == 2)
        finally:
            os.close(fd)

    def read(self, ref):
        from .auth import AuthRead
        try:
            path = _v2_path(ref)
            if ref["backend"] == "file":
                try:
                    with open(path, "r", encoding="ascii") as f:
                        value = f.read(100001)
                except FileNotFoundError:
                    return AuthRead("missing", ref=ref)
                return AuthRead("ready", value, ref)

            def read():
                ss = _ss_v2()
                if ss is None:
                    return AuthRead("unreachable", ref=ref)
                value = ss.get(ref["generation"])
                if value:
                    return AuthRead("ready", value, ref)
                return AuthRead("locked" if ss.has_locked(ref["generation"]) else "missing", ref=ref)
            return _timed(read)
        except Timeout:
            return AuthRead("timeout", ref=ref)
        except (UnicodeError, ValueError):
            return AuthRead("corrupt", ref=ref)
        except Exception:
            return AuthRead("unreachable", ref=ref)

    def stage_refresh(self, ref, payload):
        finished = threading.Event()
        writer_fd = None
        ownership = {"worker": False, "server_settled": False, "receipt_pending": False}
        close_guard = threading.Lock()

        def finish():
            nonlocal writer_fd
            with close_guard:
                fd, writer_fd = writer_fd, None
                if fd is not None:
                    try:
                        fcntl.flock(fd, fcntl.LOCK_UN)
                    finally:
                        os.close(fd)
                finished.set()

        def transfer():
            ownership["worker"] = True

        def no_worker():
            # The launch gate proves that no CreateItem could be sent.
            try:
                if ownership["receipt_pending"]:
                    self._mark_server(ref, True)
            finally:
                finish()

        self._writes.setdefault(ref["generation"], []).append(finished)
        try:
            path = _v2_path(ref)
            if not isinstance(payload, str) or not payload.isascii():
                finished.set()
                return "failure"
            writer_path = self._writer_lock_path(ref)
            os.makedirs(os.path.dirname(writer_path), mode=0o700, exist_ok=True)
            writer_fd = os.open(writer_path, os.O_RDWR | os.O_CREAT, 0o600)
            try:
                fcntl.flock(writer_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                os.close(writer_fd)
                writer_fd = None
                finished.set()
                return "uncertain"  # existing writer retains the reference

            if ref["backend"] == "file":
                try:
                    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
                    common.write_atomic(path, payload, mode=0o600)
                    return "ready"
                finally:
                    finish()

            # Never overwrite an unresolved prior server operation with a new
            # apparent acknowledgement for the same generation.
            receipt_state = self._receipt_state(ref)
            if receipt_state not in ("absent", "settled"):
                return "uncertain"
            self._mark_server(ref, False)
            ownership["receipt_pending"] = True

            def write():
                started = False
                try:
                    ss = _ss_v2()
                    if ss is None:
                        ownership["server_settled"] = True
                        return "failure"
                    # No abandoned-login cleanup. Intent already names this ref.
                    started = True
                    ss.set(payload, ref["generation"])
                    ownership["server_settled"] = True
                    return "ready" if ss.get(ref["generation"]) == payload else "uncertain"
                except _SecretWriteNotStarted:
                    ownership["server_settled"] = True
                    return "failure"
                except _SecretWriteCompleted:
                    ownership["server_settled"] = True
                    return "uncertain"
                except Exception:
                    if not started:
                        ownership["server_settled"] = True
                    return "uncertain" if started else "failure"
                finally:
                    try:
                        if ownership["server_settled"]:
                            self._mark_server(ref, True)
                    finally:
                        finish()
            return _timed(write, on_transfer=transfer, on_not_started=no_worker)
        except Timeout:
            return "uncertain"
        except Exception:
            return "uncertain"
        finally:
            if not ownership["worker"]:
                no_worker()

    def delete(self, ref):
        try:
            path = _v2_path(ref)
            if ref["backend"] == "file":
                if ref.get("uncertain") and not self.write_settled(ref):
                    return "uncertain"
                directory = os.path.dirname(path)
                try:
                    names = os.listdir(directory)
                except FileNotFoundError:
                    return "ready"
                prefix = "." + ref["generation"] + "."
                # SIGKILL may leave write_atomic's FULL credential envelope in a
                # generation-addressed temp. Unlink names, never symlink targets.
                for name in names:
                    if name == ref["generation"] or name.startswith(prefix):
                        try:
                            os.unlink(os.path.join(directory, name))
                        except FileNotFoundError:
                            pass
                fd = os.open(directory, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
                try:
                    os.fsync(fd)
                finally:
                    os.close(fd)
                return "ready"
            if ref.get("uncertain") and not self.write_settled(ref):
                return "uncertain"
            def delete():
                ss = _ss_v2()
                return "ready" if ss is not None and ss.delete(ref["generation"]) else "failure"
            return _timed(delete)
        except Timeout:
            return "uncertain"
        except Exception:
            return "failure"

    def login_backend(self):
        # Existing explicit-login policy permits file selection if SS is not
        # usable. This method is NEVER used for refresh or recovery.
        def usable():
            ss = _ss_v2()
            if ss is None:
                return False
            coll = ss.service.ReadAlias("default")
            return coll != "/" and coll in ss._unlocked([coll])
        try:
            return "secret-service" if _timed(usable) else "file"
        except Exception:
            return "file"
