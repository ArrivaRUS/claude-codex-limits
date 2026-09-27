"""Where the GitHub token lives: the desktop's Secret Service (KWallet / GNOME Keyring through
org.freedesktop.secrets) when it is reachable and unlocked, otherwise a 0600 file in
~/.config/claude-codex-limits/. The token is never printed or logged, not even in part.

Only non-interactive Secret Service calls are made: if the keyring would need a password
prompt (locked collection, no default collection), we fall back to the file rather than pop
a dialog from a background timer.
"""

import os

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
    """(token, backend) or (None, None). The Secret Service wins when it holds one."""
    ss = _ss()
    if ss is not None:
        try:
            t = ss.get()
            if t:
                return t, "secret-service"
        except Exception:
            pass
    t = _file_get()
    return (t, "file") if t else (None, None)


def write(token):
    """Store the token; returns the backend used. Verifies by reading it back."""
    if not token or not all(c.isalnum() or c in "_-" for c in token):
        raise ValueError("unexpected token format")
    ss = _ss()
    if ss is not None:
        try:
            ss.set(token)
            if ss.get() == token:
                _file_delete()          # one copy only
                return "secret-service"
        except Exception:
            pass
    _file_set(token)
    if _file_get() != token:
        raise OSError("could not save the token")
    return "file"


def delete():
    ss = _ss()
    if ss is not None:
        try:
            ss.delete()
        except Exception:
            pass
    _file_delete()
