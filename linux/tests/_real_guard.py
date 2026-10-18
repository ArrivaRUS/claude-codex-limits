"""Write guard for the owner's REAL files (lesson 006), independent of a live publisher on the machine.

Why not mtime: since A5 (2026-10-18) this machine runs an installed publisher (`ccl-sync.timer`, every 5 min).
It legitimately rewrites ~/.local/state/claude-codex-limits/{sync-state.json, publisher.jsonl,
publisher-state.json, sync-remote.json} and, on refresh, the credential files — so «mtime unchanged» blamed the
tests for the timer's writes. The question «did a TEST write there» is answered at the source instead:

  * an audit hook (process-wide, installed before any `ccl` import) sees every write-like operation of the test
    process — `open` with write/create/truncate/append flags, rename/replace, remove/unlink, rmdir, mkdir, chmod,
    chown, truncate, link, symlink, utime, shutil.rmtree/copy* — and REFUSES it (PermissionError) when the path is
    inside the protected set, recording the violation;
  * a child process cannot carry the hook, so `subprocess.Popen` is checked instead: a child whose effective
    config/state/data directory (XDG_* or HOME/…, missing HOME = the passwd home, as Python and sh do) is the real
    one is refused and recorded;
  * `assert_clean()` (module teardowns, `test_zz_isolation`) fails on any recorded violation.

Nothing of the real files is read or even stat-ed here. Reads stay governed by the existing rules (`_rl_env`
refuses ANY open of ~/.claude.json, ~/.claude/, ~/.codex/ — stricter than stat/mtime; mtime would be flaky there
too, the live CLIs rewrite their login files themselves).

Protected: the app's real config/state/data dirs (installed code included), ~/.local/bin wrappers, the systemd
units, the menu/autostart entries, and the CLI login files (~/.claude.json, ~/.claude/, ~/.codex/).
"""

import os
import pwd
import sys

APP = "claude-codex-limits"
REAL_HOME = pwd.getpwuid(os.getuid()).pw_dir


def _abs(path):
    return os.path.normpath(os.path.abspath(path))


def _base(env, name, *default):
    value = env.get(name)
    if value and os.path.isabs(value):
        return value
    return os.path.join(env.get("HOME") or REAL_HOME, *default)


def _real_dirs(env):
    return {"config": _abs(_base(env, "XDG_CONFIG_HOME", ".config")),
            "state": _abs(_base(env, "XDG_STATE_HOME", ".local", "state")),
            "data": _abs(_base(env, "XDG_DATA_HOME", ".local", "share"))}


# Real locations: the passwd defaults and, when the original environment moved them, that location too.
# Computed ONCE per process (the module may be imported as `_real_guard` and `tests._real_guard`; a second copy
# imported after `_isolate` moved XDG_* must not take the sandbox for the real directories).
_SHARED = getattr(sys, "_ccl_real_guard", None)
if _SHARED is None:
    _DEFAULT = _real_dirs({"HOME": REAL_HOME})
    _ORIGINAL = _real_dirs(dict(os.environ, HOME=REAL_HOME))
    _SHARED = sys._ccl_real_guard = {"dirs": {kind: {_DEFAULT[kind], _ORIGINAL[kind]} for kind in _DEFAULT},
                                     "violations": [], "hooked": False}
REAL_DIRS = _SHARED["dirs"]


def _variants(path):
    out = {_abs(path)}
    try:
        out.add(os.path.realpath(path))
    except OSError:
        pass
    return out


PROTECTED_TREES = set()
for _kind in ("config", "state", "data"):
    for _d in REAL_DIRS[_kind]:
        PROTECTED_TREES |= _variants(os.path.join(_d, APP))
for _p in (".claude", ".codex"):
    PROTECTED_TREES |= _variants(os.path.join(REAL_HOME, _p))
PROTECTED_FILES = set()
for _p in (".claude.json", os.path.join(".local", "bin", "ccl-sync"), os.path.join(".local", "bin", APP)):
    PROTECTED_FILES |= _variants(os.path.join(REAL_HOME, _p))
for _d in REAL_DIRS["config"]:
    for _p in (("systemd", "user", "ccl-sync.service"), ("systemd", "user", "ccl-sync.timer"),
               ("autostart", APP + ".desktop")):
        PROTECTED_FILES |= _variants(os.path.join(_d, *_p))
for _d in REAL_DIRS["data"]:
    PROTECTED_FILES |= _variants(os.path.join(_d, "applications", APP + ".desktop"))

VIOLATIONS = _SHARED["violations"]
_WRITE_FLAGS = os.O_WRONLY | os.O_RDWR | os.O_CREAT | os.O_TRUNC | os.O_APPEND
# event → indexes of the path arguments that the operation changes
_PATH_EVENTS = {"os.rename": (0, 1), "os.remove": (0,), "os.rmdir": (0,), "os.mkdir": (0,), "os.chmod": (0,),
                "os.chown": (0,), "os.truncate": (0,), "os.link": (0, 1), "os.symlink": (1,), "os.utime": (0,),
                "shutil.rmtree": (0,), "shutil.copyfile": (1,), "shutil.copymode": (1,), "shutil.copystat": (1,),
                "shutil.copytree": (1,), "shutil.move": (0, 1), "os.mkfifo": (0,), "os.mknod": (0,)}


def protected(path):
    try:
        path = os.fspath(path)
    except TypeError:
        return False                       # an fd: nothing to resolve without syscalls
    if isinstance(path, bytes):
        path = os.fsdecode(path)
    if not isinstance(path, str):
        return False
    p = _abs(path)
    if p in PROTECTED_FILES:
        return True
    return any(p == t or p.startswith(t + os.sep) for t in PROTECTED_TREES)


def _who():
    f = sys._getframe(2)
    while f is not None:
        name = f.f_code.co_name
        if name.startswith("test"):
            return "%s (%s)" % (name, os.path.basename(f.f_code.co_filename))
        f = f.f_back
    return "?"


def _refuse(event, path):
    VIOLATIONS.append((event, os.fsdecode(os.fspath(path)) if not isinstance(path, int) else path, _who()))
    raise PermissionError("тест пишет в реальные файлы владельца (%s): %s" % (event, path))


def child_env_is_real(env):
    """The child's effective app directories: XDG_* when absolute, else HOME/… (missing HOME → passwd home)."""
    dirs = _real_dirs(env)
    return [kind for kind in dirs if dirs[kind] in REAL_DIRS[kind]]


def _hook(event, args):
    if event == "open":
        if len(args) >= 3 and isinstance(args[2], int) and args[2] & _WRITE_FLAGS and protected(args[0]):
            _refuse(event, args[0])
        return
    idx = _PATH_EVENTS.get(event)
    if idx is not None:
        for i in idx:
            if i < len(args) and args[i] is not None and protected(args[i]):
                _refuse(event, args[i])
        return
    if event == "subprocess.Popen":
        env = args[3] if len(args) > 3 and args[3] is not None else os.environ
        real = child_env_is_real(env)
        if real:
            VIOLATIONS.append((event, "%r → real %s dir" % (list(args[1]) if isinstance(args[1], (list, tuple))
                                                              else args[1], "/".join(real)), _who()))
            raise PermissionError("дочерний процесс теста видит реальные каталоги приложения: %s" % real)


if not _SHARED["hooked"]:
    _SHARED["hooked"] = True
    sys.addaudithook(_hook)


def assert_clean():
    if VIOLATIONS:
        raise AssertionError("tests tried to change the owner's real files: %s" % (VIOLATIONS,))
