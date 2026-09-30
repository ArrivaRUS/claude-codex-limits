"""Where the GitHub token lives: the desktop's Secret Service (KWallet / GNOME Keyring through
org.freedesktop.secrets) when it is reachable and unlocked, otherwise a 0600 file in
~/.config/claude-codex-limits/. The token is never printed or logged, not even in part.

Only non-interactive Secret Service calls are made: if the keyring would need a password
prompt (locked collection, no default collection), we fall back to the file rather than pop
a dialog from a background timer.

Every Secret Service operation runs under a deadline (`TIMEOUT`, docs/sync-protocol.md →
Errors): a keyring that hangs on D-Bus must not hold the sync cycle (and its lock) forever.
Test seams: `_ss` (the Secret Service factory) and `TIMEOUT`.
"""

import os
import threading

from . import common

ATTRS = {"application": "claude-codex-limits", "service": "github"}
LABEL = "Claude Codex Limits GitHub"

_SS = "org.freedesktop.secrets"
_SS_PATH = "/org/freedesktop/secrets"
_I_SERVICE = "org.freedesktop.Secret.Service"
_I_ITEM = "org.freedesktop.Secret.Item"
_I_COLLECTION = "org.freedesktop.Secret.Collection"


class _SecretService(object):
    def __init__(self):
        import dbus  # python3-dbus from the OS repository
        self.dbus = dbus
        self.bus = dbus.SessionBus()
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

    def find(self):
        unlocked, locked = self.service.SearchItems(ATTRS)
        items = list(unlocked) + self._unlocked(list(locked))
        return items[0] if items else None

    def has_locked(self):
        _unlocked, locked = self.service.SearchItems(ATTRS)
        return bool(locked) and not self._unlocked(list(locked))

    def get(self):
        path = self.find()
        if not path:
            return None
        item = self.dbus.Interface(self.bus.get_object(_SS, path), _I_ITEM)
        secret = item.GetSecret(self.session)
        value = bytes(bytearray(secret[2])).decode("utf-8").strip()
        return value or None

    def set(self, token):
        dbus = self.dbus
        coll = self.service.ReadAlias("default")
        if coll == "/":
            raise RuntimeError("no default collection")
        if coll not in self._unlocked([coll]):
            raise RuntimeError("collection locked")
        c = dbus.Interface(self.bus.get_object(_SS, coll), _I_COLLECTION)
        props = {
            "org.freedesktop.Secret.Item.Label": dbus.String(LABEL),
            "org.freedesktop.Secret.Item.Attributes": dbus.Dictionary(ATTRS, signature="ss"),
        }
        secret = dbus.Struct((self.session, dbus.ByteArray(b""), dbus.ByteArray(token.encode("utf-8")),
                              dbus.String("text/plain")), signature="oayays")
        item, prompt = c.CreateItem(dbus.Dictionary(props, signature="sv"), secret, True)
        if item == "/" or prompt != "/":
            raise RuntimeError("keyring asked for a prompt")

    def delete(self):
        unlocked, locked = self.service.SearchItems(ATTRS)
        for path in list(unlocked) + self._unlocked(list(locked)):
            item = self.dbus.Interface(self.bus.get_object(_SS, path), _I_ITEM)
            item.Delete()


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
        try:
            box["v"] = fn()
        except BaseException as e:      # handed to the caller below
            box["e"] = e
    t = threading.Thread(target=run, name="ccl-vault", daemon=True)
    t.start()
    t.join(TIMEOUT)
    if t.is_alive():
        raise Timeout()
    if "e" in box:
        raise box["e"]
    return box.get("v")


def _ss_read():
    """(token or None, locked) from the Secret Service; (None, False) when it isn't there."""
    ss = _ss()
    if ss is None:
        return None, False
    t = ss.get()
    if t:
        return t, False
    return None, ss.has_locked()


def _file_get():
    try:
        with open(common.TOKEN_FILE_PATH, "r", encoding="utf-8") as f:
            t = f.read().strip()
            return t or None
    except OSError:
        return None


def _file_set(token):
    common.ensure_dirs()
    common.write_atomic(common.TOKEN_FILE_PATH, token + "\n", 0o600)


def _file_delete():
    try:
        os.unlink(common.TOKEN_FILE_PATH)
    except OSError:
        pass


def read():
    """(token, backend) or (None, None). The Secret Service wins when it holds one.
    (None, "locked") means the keyring holds our token but is locked right now — the caller
    should wait, not treat it as a sign-out. (None, "timeout") means the Secret Service didn't
    answer in time and there is no file token either — the caller can't tell, so it must not
    treat it as a sign-out."""
    locked = timed_out = False
    try:
        t, locked = _timed(_ss_read)
        if t:
            return t, "secret-service"
    except Timeout:
        timed_out = True
    except Exception:
        pass
    t = _file_get()
    if t:
        return t, "file"
    if timed_out:
        return None, "timeout"
    return (None, "locked") if locked else (None, None)


def reachable():
    try:
        return _timed(lambda: _ss() is not None)
    except Exception:
        return False


def delete_if(token):
    """Delete the stored token only if it is still `token` — a sync cycle that got a 401 with
    an old token must not wipe a new one saved by a fresh sign-in meanwhile.
    Returns "deleted", "missing" (nothing stored), "other" (a different token is stored — keep
    it), or "timeout" (the store didn't answer — the token may still be there)."""
    cur, backend = read()
    if backend == "timeout":
        return "timeout"
    if cur is None:
        return "missing"
    if cur != token:
        return "other"
    return "deleted" if delete() else "timeout"


def write(token):
    """Store the token; returns the backend used. Verifies by reading it back."""
    if not token or not all(c.isalnum() or c in "_-" for c in token):
        raise ValueError("unexpected token format")

    def ss_write():
        ss = _ss()
        if ss is None:
            return False
        ss.set(token)
        return ss.get() == token
    try:
        if _timed(ss_write):
            _file_delete()              # one copy only
            return "secret-service"
    except Exception:                   # incl. Timeout → the file below
        pass
    _file_set(token)
    if _file_get() != token:
        raise OSError("could not save the token")
    return "file"


def delete():
    """Remove the token from both places. False when the Secret Service didn't answer in time
    (its copy may still be there); other Secret Service errors are ignored, as before."""
    def ss_delete():
        ss = _ss()
        if ss is not None:
            ss.delete()
    ok = True
    try:
        _timed(ss_delete)
    except Timeout:
        ok = False
    except Exception:
        pass
    _file_delete()
    return ok
