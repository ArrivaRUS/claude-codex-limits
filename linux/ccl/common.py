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
import unicodedata
import urllib.error
import urllib.parse
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

CLAUDE_JSON = os.path.join(HOME, ".claude.json")
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
    except (OSError, ValueError, RecursionError):
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
        # Persist the directory entry as well as the file contents.
        directory_fd = os.open(d, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
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


_held_locks = threading.local()


def lock_held_by_thread(name):
    return bool(getattr(_held_locks, "names", {}).get(name))


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
        if held:
            names = getattr(_held_locks, "names", {})
            names[name] = names.get(name, 0) + 1
            _held_locks.names = names
        try:
            yield held
        finally:
            if held:
                _held_locks.names[name] -= 1
    finally:
        if held:
            with contextlib.suppress(OSError):
                fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


# ---- settings (user choices) and state (things the app remembers) --------------------------

SETTINGS_DEFAULTS = {
    "lang": "ru",
    "interval": 1800,
    "monitor_claude": True,
    "monitor_codex": True,
    "advanced": False,
    "autoPoll": False,
    "trayMetrics": "session,weekly",
    "codexTray": False,
    "sound5h": False,
    "sound7d": False,
    "reachedOn": False,
    "notify": True,
    "sound5hChoice": "rise",
    "sound7dChoice": "celebrate",
    "reachedChoice": "outage",
    "advHistExpanded": True,
    "advHistProduct": "claude",
}


def product_enabled(product):
    # Missing keys preserve monitoring on upgrades from earlier versions.
    return settings().get("monitor_" + product, True) is not False


def selected_days(days):
    return {p: data for p, data in days.items() if product_enabled(p)}


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
        with self.lock:
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
        """Read-modify-write of only the given keys, under a cross-process lock: the tray and
        the timer both write sync-state.json, and writing back a whole stale copy would undo
        the other process's changes (e.g. resurrect a login right after a sign-out)."""
        with self.lock, file_lock("store-" + os.path.basename(self.path)):
            self._validate_sync_state()
            self.reload()
            for k, v in kw.items():
                if v is None:
                    self.data.pop(k, None)
                else:
                    self.data[k] = v
            self._write()

    def remove(self, *keys):
        self.update(**{k: None for k in keys})

    def save(self):
        with self.lock, file_lock("store-" + os.path.basename(self.path)):
            self._write()

    def _validate_sync_state(self):
        if self.path == SYNC_STATE_PATH:
            from .auth import LinuxManifest
            LinuxManifest()._read_file()  # strict; never turn corrupt auth into {}

    def _write(self):
        self._validate_sync_state()
        if self.path == SYNC_STATE_PATH and "authV2" in self.data:
            from .auth import validate_manifest
            validate_manifest(self.data["authV2"])
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

def _read_machine_id():
    with open(MACHINE_ID_PATH, "r", encoding="utf-8") as f:
        return f.read().strip()


def machine_id():
    """The id is created once and never replaced: a new id would leave the old
    machine-<id>.json in the gist, and the other machines would count this one twice for
    up to 45 days. So only a missing file creates one — atomically (O_EXCL), and if another
    process wins the race, its id is used."""
    for _ in range(50):
        try:
            t = _read_machine_id()
            if t:
                return t
        except FileNotFoundError:
            import uuid
            mid = str(uuid.uuid4()).lower()
            ensure_dirs()
            tmp = MACHINE_ID_PATH + ".%d.tmp" % os.getpid()
            with open(tmp, "w", encoding="utf-8") as f:
                f.write(mid + "\n")
            os.chmod(tmp, 0o600)
            try:
                os.link(tmp, MACHINE_ID_PATH)           # fails if someone else created it first
                return mid
            except FileExistsError:
                pass
            finally:
                os.unlink(tmp)
        time.sleep(0.1)                                 # empty = mid-write elsewhere; unreadable → retry
    raise OSError("cannot read " + MACHINE_ID_PATH)


def machine_name():
    n = settings().get("machineName")
    return n if n else socket.gethostname()


def machine_tag():
    """Short public tag from the configured name or the first hostname label."""
    name = settings().get("machineName")
    if not isinstance(name, str) or not name.strip():
        name = socket.gethostname().split(".", 1)[0]
    name = "".join(ch for ch in name if unicodedata.category(ch) not in ("Cc", "Cf"))
    name = unicodedata.normalize("NFKD", name).encode("ascii", "ignore").decode("ascii").lower()
    return re.sub(r"[^a-z0-9-]+", "-", name).strip("-")[:16].rstrip("-") or "linux"


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
    try:
        parts = tuple(map(int, (y, mo, d, h, mi, se)))
        if not (1 <= parts[2] <= calendar.monthrange(parts[0], parts[1])[1]
                and 0 <= parts[3] < 24 and 0 <= parts[4] < 60 and 0 <= parts[5] < 60):
            return None
        t = calendar.timegm(parts)
        if tz and tz != "Z":
            sign = 1 if tz[0] == "+" else -1
            tz = tz[1:].replace(":", "")
            hours, minutes = int(tz[:2]), int(tz[2:4])
            if hours >= 24 or minutes >= 60:
                return None
            t -= sign * (hours * 3600 + minutes * 60)
        return t + (float(frac) if frac else 0.0)
    except (ValueError, OverflowError):
        return None


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
    __slots__ = ("status", "data", "headers", "error", "definitely_not_sent")

    def __init__(self, status, data=None, headers=None, error=None, definitely_not_sent=False):
        self.status, self.data, self.headers, self.error = status, data, headers or {}, error
        self.definitely_not_sent = definitely_not_sent

    def json(self):
        try:
            return json.loads(self.data.decode("utf-8")) if self.data else None
        except (ValueError, RecursionError):
            return None


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


RAW_REDIRECT_REFUSED = "gist raw redirect refused"


def gist_raw_url(url):
    """Only this HTTPS origin can serve untrusted gist machine bodies."""
    if not isinstance(url, str) or not url.isascii() or any(ord(c) <= 32 or ord(c) == 127 for c in url):
        return False
    try:
        parts = urllib.parse.urlsplit(url)
        return (url.startswith("https://gist.githubusercontent.com/")
                and parts.netloc == "gist.githubusercontent.com" and not parts.fragment)
    except ValueError:
        return False


class _RawRedirectRefused(Exception):
    pass


class _GistRawRedirect(urllib.request.HTTPRedirectHandler):
    """Close intermediate responses without draining their untrusted bodies."""
    def __init__(self):
        self.hops = 0

    def http_error_302(self, req, fp, code, msg, headers):
        fp.close()
        location = headers.get("Location")
        if (not isinstance(location, str) or any(ord(c) <= 32 or ord(c) == 127 for c in location)
                or req.get_method() not in ("GET", "HEAD")):
            raise _RawRedirectRefused()
        try:
            target = urllib.parse.urljoin(req.full_url, location)
        except ValueError:
            raise _RawRedirectRefused() from None
        if self.hops >= 3 or not gist_raw_url(target):
            raise _RawRedirectRefused()
        self.hops += 1
        redirected = urllib.request.Request(target, headers=dict(req.header_items()), method=req.get_method())
        return self.parent.open(redirected, timeout=req.timeout)

    http_error_301 = http_error_303 = http_error_307 = http_error_308 = http_error_302


def http(url, method="GET", headers=None, body=None, timeout=15, follow_redirects=True, max_body=None):
    """Optional max_body bounds response bytes, including HTTP error bodies."""
    if max_body is not None and (type(max_body) is not int or max_body < 0):
        raise ValueError("max_body must be a non-negative integer or None")
    if isinstance(body, (dict, list)):
        body = json.dumps(body).encode("utf-8")
    elif isinstance(body, str):
        body = body.encode("utf-8")
    try:
        req = urllib.request.Request(url, data=body, method=method, headers=headers or {})
        if not follow_redirects:
            opener = urllib.request.build_opener(_NoRedirect()).open
        elif gist_raw_url(url):
            opener = urllib.request.build_opener(_GistRawRedirect()).open
        else:
            opener = urllib.request.urlopen
        with opener(req, timeout=timeout) as r:
            data = r.read() if max_body is None else r.read(max_body + 1)
            response_headers = {k.lower(): v for k, v in r.headers.items()}
            if max_body is not None and len(data) > max_body:
                return Resp(0, None, response_headers, "response body too large")
            return Resp(r.status, data, response_headers)
    except _RawRedirectRefused:
        return Resp(0, error=RAW_REDIRECT_REFUSED)
    except urllib.error.HTTPError as e:
        try:
            if 300 <= e.code < 400:
                e.close()
                data = None
            elif max_body is None:
                data = e.read()
            else:
                with e:
                    data = e.read(max_body + 1)
        except Exception:
            data = None
        if max_body is not None and data is not None and len(data) > max_body:
            return Resp(0, None, {k.lower(): v for k, v in (e.headers or {}).items()},
                        "response body too large")
        return Resp(e.code, data, {k.lower(): v for k, v in (e.headers or {}).items()})
    except Exception as e:  # network down, DNS, TLS, timeout
        import socket
        cause = e.reason if isinstance(e, urllib.error.URLError) else e
        # Only connection establishment failures prove no OAuth body reached the
        # issuer. Read/write timeouts and resets remain ambiguous.
        not_sent = isinstance(cause, socket.gaierror) or (isinstance(cause, OSError) and
            cause.errno in (errno.ECONNREFUSED, errno.ENETUNREACH, errno.EHOSTUNREACH))
        return Resp(0, None, None, str(e) or e.__class__.__name__, definitely_not_sent=not_sent)
