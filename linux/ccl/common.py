"""Paths, small file helpers, settings, localisation and HTTP — shared by the CLI and the tray.

Everything lives in the user's home directory (Astra's mandatory integrity control: no system
paths, no sudo):
  ~/.config/claude-codex-limits/       settings.json, machine-id, github-token (0600 fallback)
  ~/.local/state/claude-codex-limits/  usage index, sync state, remote cache, history, cache
"""

import calendar
import contextlib
import errno
import fcntl
import json
import os
import re
import socket
import tempfile
import threading
import time
import urllib.error
import urllib.request

HOME = os.path.expanduser("~")
APP_ID = "claude-codex-limits"
CONFIG_DIR = os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.join(HOME, ".config"), APP_ID)
STATE_DIR = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.join(HOME, ".local", "state"), APP_ID)

SETTINGS_PATH = os.path.join(CONFIG_DIR, "settings.json")
MACHINE_ID_PATH = os.path.join(CONFIG_DIR, "machine-id")
TOKEN_FILE_PATH = os.path.join(CONFIG_DIR, "github-token")

USAGE_INDEX_PATH = os.path.join(STATE_DIR, "usage-index.json")
SYNC_STATE_PATH = os.path.join(STATE_DIR, "sync-state.json")
SYNC_REMOTE_PATH = os.path.join(STATE_DIR, "sync-remote.json")
HISTORY_PATH = os.path.join(STATE_DIR, "history.jsonl")
CACHE_PATH = os.path.join(STATE_DIR, "cache.json")
STATE_PATH = os.path.join(STATE_DIR, "state.json")

CLAUDE_PROJECTS = os.path.join(HOME, ".claude", "projects")
CLAUDE_CREDENTIALS = os.path.join(HOME, ".claude", ".credentials.json")
CODEX_SESSIONS = os.path.join(HOME, ".codex", "sessions")
CODEX_AUTH = os.path.join(HOME, ".codex", "auth.json")


def ensure_dirs():
    for d in (CONFIG_DIR, STATE_DIR):
        os.makedirs(d, mode=0o700, exist_ok=True)


# ---- files -------------------------------------------------------------------------------

def read_json(path, default=None):
    try:
        with open(path, "rb") as f:
            return json.loads(f.read().decode("utf-8"))
    except (OSError, ValueError):
        return default


def write_atomic(path, data, mode=0o600):
    """Write bytes/str through a temp file in the same directory + rename, so a reader never
    sees half a file and a crash never leaves one. `mode` is applied before the rename."""
    if isinstance(data, str):
        data = data.encode("utf-8")
    d = os.path.dirname(path) or "."
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix="." + os.path.basename(path) + ".", dir=d)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(OSError):
            os.unlink(tmp)
        raise


def write_json(path, obj, mode=0o600, compact=True):
    if compact:
        s = json.dumps(obj, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
    else:
        s = json.dumps(obj, ensure_ascii=False, indent=2, sort_keys=True)
    write_atomic(path, s, mode)


@contextlib.contextmanager
def file_lock(name, blocking=True, timeout=None):
    """Advisory lock shared by every process of the app (tray, timer, manual CLI).
    Yields True when held, False when `blocking=False` and someone else holds it."""
    ensure_dirs()
    path = os.path.join(STATE_DIR, name + ".lock")
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    held = False
    try:
        if blocking and timeout is None:
            fcntl.flock(fd, fcntl.LOCK_EX)
            held = True
        else:
            deadline = time.time() + (timeout or 0)
            while True:
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    held = True
                    break
                except OSError as e:
                    if e.errno not in (errno.EAGAIN, errno.EACCES):
                        raise
                    if not blocking or time.time() >= deadline:
                        break
                    time.sleep(0.2)
        yield held
    finally:
        if held:
            with contextlib.suppress(OSError):
                fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


# ---- settings (user choices) and state (things the app remembers) --------------------------

SETTINGS_DEFAULTS = {
    "lang": "ru",
    "interval": 60,
    "advanced": False,
    "trayMetrics": "session,weekly",
    "codexTray": False,
    "sound5h": False,
    "sound7d": False,
    "reachedOn": False,
    "sound5hChoice": "rise",
    "sound7dChoice": "celebrate",
    "reachedChoice": "outage",
    "advHistExpanded": True,
    "advHistProduct": "claude",
}


class Store:
    """A small JSON key/value file — the UserDefaults of this port. Re-read on every `get`
    is avoided; `reload()` picks up writes from other processes when it matters."""

    def __init__(self, path, defaults=None):
        self.path = path
        self.defaults = defaults or {}
        self.data = {}
        self.lock = threading.RLock()     # the tray's workers and its GUI thread share one Store
        self.reload()

    def reload(self):
        d = read_json(self.path, {})
        self.data = d if isinstance(d, dict) else {}

    def get(self, key, default=None):
        if key in self.data:
            return self.data[key]
        if default is not None:
            return default
        return self.defaults.get(key)

    def has(self, key):
        return key in self.data

    def set(self, key, value):
        self.update(**{key: value})

    def update(self, **kw):
        with self.lock:
            for k, v in kw.items():
                if v is None:
                    self.data.pop(k, None)
                else:
                    self.data[k] = v
            self.save()

    def remove(self, *keys):
        with self.lock:
            for k in keys:
                self.data.pop(k, None)
            self.save()

    def save(self):
        with self.lock:
            ensure_dirs()
            write_json(self.path, self.data, compact=False)


_settings = None
_state = None


def settings():
    global _settings
    if _settings is None:
        _settings = Store(SETTINGS_PATH, SETTINGS_DEFAULTS)
    return _settings


def state():
    global _state
    if _state is None:
        _state = Store(STATE_PATH)
    return _state


def app_lang():
    return "en" if settings().get("lang") == "en" else "ru"


def tr(ru, en):
    """Pick the string for the current UI language. Russian is the default, as on the Mac."""
    return en if app_lang() == "en" else ru


# ---- machine identity (docs/sync-protocol.md) ----------------------------------------------

def machine_id():
    try:
        with open(MACHINE_ID_PATH, "r", encoding="utf-8") as f:
            t = f.read().strip()
            if t:
                return t
    except OSError:
        pass
    import uuid
    mid = str(uuid.uuid4()).lower()
    ensure_dirs()
    write_atomic(MACHINE_ID_PATH, mid + "\n", 0o600)
    return mid


def machine_name():
    n = settings().get("machineName")
    return n if n else socket.gethostname()


def os_name():
    """"Astra Linux SE 1.8.5" — edition from os-release, exact build from /etc/astra_version."""
    rel = {}
    try:
        with open("/etc/os-release", encoding="utf-8") as f:
            for line in f:
                if "=" in line:
                    k, v = line.rstrip("\n").split("=", 1)
                    rel[k] = v.strip('"')
    except OSError:
        pass
    name = rel.get("NAME") or "Linux"
    ver = ""
    try:
        with open("/etc/astra_version", encoding="utf-8") as f:
            ver = f.read().strip()
    except OSError:
        ver = (rel.get("VERSION_ID") or "").split("_")[0]
    variant = rel.get("VARIANT_ID", "")
    if name.lower().startswith("astra") and variant:
        name += " " + variant.upper()
    return (name + " " + ver).strip()


def local_tz_name():
    tz = os.environ.get("TZ")
    if tz and "/" in tz:
        return tz.lstrip(":")
    try:
        p = os.path.realpath("/etc/localtime")
        if "zoneinfo/" in p:
            return p.split("zoneinfo/", 1)[1]
    except OSError:
        pass
    try:
        with open("/etc/timezone", encoding="utf-8") as f:
            t = f.read().strip()
            if t:
                return t
    except OSError:
        pass
    return time.tzname[0] or "UTC"


# ---- time --------------------------------------------------------------------------------

_TS_RE = re.compile(r"^(\d{4})-(\d\d)-(\d\d)[T ](\d\d):(\d\d):(\d\d)(\.\d+)?(Z|[+-]\d\d:?\d\d)?$")


def parse_iso(s):
    """ISO-8601 → epoch seconds (float), or None. Accepts `Z`, `+03:00`, any fraction length —
    Claude writes milliseconds, Anthropic's API microseconds with an offset."""
    if not isinstance(s, str):
        return None
    m = _TS_RE.match(s.strip())
    if not m:
        return None
    y, mo, d, h, mi, se, frac, tz = m.groups()
    t = calendar.timegm((int(y), int(mo), int(d), int(h), int(mi), int(se)))
    if tz and tz != "Z":
        sign = 1 if tz[0] == "+" else -1
        tz = tz[1:].replace(":", "")
        t -= sign * (int(tz[:2]) * 3600 + int(tz[2:4]) * 60)
    return t + (float(frac) if frac else 0.0)


def iso_utc(t=None):
    """"2026-09-27T10:15:00Z" — no fraction: the Mac reads it with ISO8601DateFormatter's
    default options, which reject fractional seconds."""
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() if t is None else t))


def day_key(t):
    """Local-calendar day ("2026-09-24") for an epoch — the day boundaries the user lives in."""
    return time.strftime("%Y-%m-%d", time.localtime(t))


def today_key():
    return day_key(time.time())


# ---- HTTP (urllib, synchronous; call off the GUI thread) -----------------------------------

class Resp(object):
    __slots__ = ("status", "data", "headers", "error")

    def __init__(self, status, data=None, headers=None, error=None):
        self.status, self.data, self.headers, self.error = status, data, headers or {}, error

    def json(self):
        try:
            return json.loads(self.data.decode("utf-8")) if self.data else None
        except ValueError:
            return None


def http(url, method="GET", headers=None, body=None, timeout=15):
    if isinstance(body, (dict, list)):
        body = json.dumps(body).encode("utf-8")
    elif isinstance(body, str):
        body = body.encode("utf-8")
    req = urllib.request.Request(url, data=body, method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return Resp(r.status, r.read(), {k.lower(): v for k, v in r.headers.items()})
    except urllib.error.HTTPError as e:
        try:
            data = e.read()
        except Exception:
            data = None
        return Resp(e.code, data, {k.lower(): v for k, v in (e.headers or {}).items()})
    except Exception as e:  # network down, DNS, TLS, timeout
        return Resp(0, None, None, str(e) or e.__class__.__name__)
