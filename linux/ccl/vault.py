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
import secrets
import threading

from . import common

ATTRS = {"application": "claude-codex-limits", "service": "github"}
LABEL = "Claude Codex Limits GitHub"

_SS = "org.freedesktop.secrets"
_SS_PATH = "/org/freedesktop/secrets"
_I_SERVICE = "org.freedesktop.Secret.Service"
_I_ITEM = "org.freedesktop.Secret.Item"
_I_COLLECTION = "org.freedesktop.Secret.Collection"
_worker = threading.local()


class _SecretService(object):
    def __init__(self):
        import dbus  # python3-dbus from the OS repository
        self.dbus = dbus
        self.bus = dbus.SessionBus(private=True)
        # Register before the first D-Bus call, including a failing/hung constructor.
        _worker.buses.append(self.bus)
        obj = self.bus.get_object(_SS, _SS_PATH)
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
        attrs = dict(ATTRS, generation=generation) if generation != "legacy" else ATTRS
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
        dbus = self.dbus
        coll = self.service.ReadAlias("default")
        if coll == "/":
            raise RuntimeError("no default collection")
        if coll not in self._unlocked([coll]):
            raise RuntimeError("collection locked")
        c = dbus.Interface(self.bus.get_object(_SS, coll), _I_COLLECTION)
        props = {
            "org.freedesktop.Secret.Item.Label": dbus.String(LABEL),
            "org.freedesktop.Secret.Item.Attributes": dbus.Dictionary(dict(ATTRS, generation=generation), signature="ss"),
        }
        secret = dbus.Struct((self.session, dbus.ByteArray(b""), dbus.ByteArray(token.encode("utf-8")),
                              dbus.String("text/plain")), signature="oayays")
        item, prompt = c.CreateItem(dbus.Dictionary(props, signature="sv"), secret, True)
        if item == "/" or prompt != "/":
            raise RuntimeError("keyring asked for a prompt")

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
    except Exception:
        return None


TIMEOUT = 15.0          # seconds per Secret Service operation (connect + calls)


class Timeout(Exception):
    """The Secret Service didn't answer within TIMEOUT."""


def timeout_text():
    return common.tr("Хранилище секретов не ответило за %g с" % TIMEOUT,
                     "The Secret Service didn't answer in %g s" % TIMEOUT)


def _timed(fn):
    """Run `fn` in a daemon thread and wait at most TIMEOUT. Raises Timeout (the thread is
    left behind — a hung D-Bus call can't be cancelled) or whatever `fn` raised."""
    box = {}

    def run():
        _worker.buses = []
        try:
            box["v"] = fn()
        except BaseException as e:      # handed to the caller below
            box["e"] = e
        finally:
            for bus in _worker.buses:
                try:
                    bus.close()
                except Exception:
                    pass
            del _worker.buses
    t = threading.Thread(target=run, name="ccl-vault", daemon=True)
    t.start()
    t.join(TIMEOUT)
    if t.is_alive():
        raise Timeout()
    if "e" in box:
        raise box["e"]
    return box.get("v")


def _ss_read(generation):
    """(token or None, locked), restricted to the captured generation."""
    ss = _ss()
    if ss is None:
        return None, False
    t = ss.get(generation)
    if t:
        return t, False
    return None, ss.has_locked(generation)


def _file_get(generation="legacy"):
    try:
        with open(common.TOKEN_FILE_PATH, "r", encoding="utf-8") as f:
            lines = f.read().splitlines()
        stored_generation = lines[1] if len(lines) > 1 else "legacy"
        return (lines[0].strip() or None) if lines and stored_generation == generation else None
    except OSError:
        return None


def _file_set(token, generation):
    common.ensure_dirs()
    common.write_atomic(common.TOKEN_FILE_PATH, token + "\n" + generation + "\n", 0o600)


def _file_delete(generation):
    # Mutating callers hold the sync lock, including this compare + unlink.
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


def _active(st):
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
    active = _active(st)
    result = _read(*active)
    st.reload()
    return result if _active(st) == active else (None, None)


def reachable():
    try:
        return _timed(lambda: _ss() is not None)
    except Exception:
        return False


def _delete(generation, backend):
    """Delete a captured reference, never whatever happens to be active later."""
    if not generation:
        return True
    legacy_discovery = generation == "legacy" and backend is None
    ok = True
    if backend == "secret-service" or legacy_discovery:
        def ss_delete():
            ss = _ss()
            return ss is not None and ss.delete(generation)
        try:
            ok = bool(_timed(ss_delete))
        except Exception:
            ok = False
    if backend == "file" or legacy_discovery:
        ok = _file_delete(generation) and ok
    return ok


def delete_if(token):
    """Compare and delete only the captured generation. Call with the sync lock held.
    Returns deleted/missing/other/timeout; unreadable copies are left alone.
    """
    generation, backend = _active(common.Store(common.SYNC_STATE_PATH))
    cur, found_backend = _read(generation, backend)
    if found_backend in ("timeout", "locked", "unreachable"):
        return "timeout"
    if cur is None:
        return "missing"
    if cur != token:
        return "other"
    return "deleted" if _delete(generation, found_backend) else "timeout"


def write(token):
    """Store a new generation, then publish it. Caller must hold the sync lock.
    A timed-out D-Bus write can only leave an orphan, never replace a later generation.
    """
    if not token or not all(c.isalnum() or c in "_-" for c in token):
        raise ValueError("unexpected token format")
    generation = secrets.token_hex(8)

    def ss_write(generation=generation):
        ss = _ss()
        if ss is None:
            return False
        ss.set(token, generation)
        return ss.get(generation) == token
    backend = "file"
    try:
        if _timed(ss_write):
            backend = "secret-service"
    except Exception:                   # incl. Timeout → a distinct file generation
        pass
    if backend == "file":
        generation = secrets.token_hex(8)
        _file_set(token, generation)
        if _file_get(generation) != token:
            raise OSError("could not save the token")
    common.Store(common.SYNC_STATE_PATH).update(tokenGeneration=generation, tokenBackend=backend)
    return backend


def delete():
    """Invalidate before deletion; retain failed references for a repeated sign-out.
    Caller must hold the sync lock. No delayed operation can address a newer generation.
    """
    st = common.Store(common.SYNC_STATE_PATH)
    generation, backend = _active(st)
    pending = list(st.get("tokenDeletePending") or [])
    ref = [generation, backend]
    if generation and ref not in pending:
        pending.append(ref)
    st.update(tokenGeneration="", tokenBackend=None, tokenDeletePending=pending)
    failed = [ref for ref in pending if not _delete(*ref)]
    st.update(tokenDeletePending=failed or None)
    return not failed
