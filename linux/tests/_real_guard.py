"""Guard for the owner's REAL files (lesson 006), independent of a live publisher on the machine.

Why not mtime: since A5 (2026-10-18) this machine runs an installed publisher (`ccl-sync.timer`, every 5 min).
It legitimately rewrites ~/.local/state/claude-codex-limits/* and, on refresh, the credential files — «mtime
unchanged» blamed the tests for the timer's writes. The question «did a TEST touch it» is answered at the source:
an audit hook (process-wide, installed before any `ccl` import) sees the operations of the test process and REFUSES
them before the system call (PermissionError), recording each violation; `assert_clean()` (module teardowns,
`test_zz_isolation`) fails on any record.

Refused (A5 T2 M5/m8 hardening, docs/security-remote-limits-a5-s4-t2.md):
  * write-like operations on protected paths — `open` with write/create/truncate/append flags, rename/replace,
    remove/unlink, rmdir, mkdir, chmod, chown, truncate, link, symlink, utime, mkfifo/mknod, shutil.rmtree/copy*/move;
    a path is resolved through symlinks (realpath of the parent; of the path itself for operations that follow
    links), relative paths with `dir_fd` through /proc/self/fd/<fd>; a relative `open` (its audit event carries no
    dir_fd) is also matched conservatively against every ancestor of the protected trees;
  * ANY open (reads too) of the real GitHub token: `github-token*`, its write_atomic temps `.github-token.*`,
    `github-credentials/`;
  * child processes (`subprocess.Popen`, `os.exec*`, `os.posix_spawn*`, `os.spawn*`, `os.system`) whose effective app
    directories are the real ones (XDG_* when absolute, else HOME/…; missing HOME = the passwd home) or whose
    argv/command names a protected path.
Not covered (by construction): ctypes/raw syscalls, and children started without an audit event
(`multiprocessing` spawn uses `_posixsubprocess` directly) — such children import `_isolate` and carry their own hook;
their records stay in the child.

Protected: the app's real config/state/data dirs (installed code included), ~/.local/bin wrappers, the systemd units,
the menu/autostart entries, and the CLI login files (~/.claude.json, ~/.claude/, ~/.codex/). `_rl_env` additionally
refuses ANY open of the CLI login files (mtime there is flaky: the live CLIs rewrite them).

Self-tests use a synthetic `Policy` in the sandbox (`extra_policy`), never the real paths (m8).
"""

import contextlib
import os
import pwd
import sys

APP = "claude-codex-limits"
REAL_HOME = pwd.getpwuid(os.getuid()).pw_dir
_WRITE_FLAGS = os.O_WRONLY | os.O_RDWR | os.O_CREAT | os.O_TRUNC | os.O_APPEND
# event → ((path index, dir_fd index or None, follows symlinks), …)
_PATH_EVENTS = {
    "os.rename": ((0, 2, False), (1, 3, False)), "os.remove": ((0, 1, False),), "os.rmdir": ((0, 1, False),),
    "os.mkdir": ((0, 2, False),), "os.chmod": ((0, 2, True),), "os.chown": ((0, 3, True),),
    "os.truncate": ((0, None, True),), "os.link": ((0, 2, False), (1, 3, False)), "os.symlink": ((1, 2, False),),
    "os.utime": ((0, 3, True),), "os.mkfifo": ((0, 2, False),), "os.mknod": ((0, 3, False),),
    "shutil.rmtree": ((0, 1, False),), "shutil.copyfile": ((1, None, True),), "shutil.copymode": ((1, None, True),),
    "shutil.copystat": ((1, None, True),), "shutil.copytree": ((1, None, False),),
    "shutil.move": ((0, None, False), (1, None, False))}
# event → (argv index, env index or None)
_CHILD_EVENTS = {"subprocess.Popen": (1, 3), "os.exec": (1, 2), "os.posix_spawn": (1, 2), "os.spawn": (2, 3),
                 "os.system": (0, None)}


def _abs(path):
    return os.path.normpath(os.path.abspath(path))


def _base(env, name, *default):
    value = env.get(name)
    if value and os.path.isabs(value):
        return value
    return os.path.join(env.get("HOME") or REAL_HOME, *default)


def _dirs_of(env, home):
    env = dict(env, HOME=env.get("HOME") or home)
    return {"config": _abs(_base(env, "XDG_CONFIG_HOME", ".config")),
            "state": _abs(_base(env, "XDG_STATE_HOME", ".local", "state")),
            "data": _abs(_base(env, "XDG_DATA_HOME", ".local", "share"))}


def _text(path):
    try:
        path = os.fspath(path)
    except TypeError:
        return None                        # an fd
    if isinstance(path, bytes):
        path = os.fsdecode(path)
    return path if isinstance(path, str) else None


def _variants(path):
    out = {_abs(path)}
    try:
        out.add(os.path.realpath(path))
    except (OSError, ValueError):
        pass
    return out


class Policy(object):
    """What is protected for one home. The real one is built once per process; tests build synthetic ones."""

    def __init__(self, home, dirs, app=APP):
        self.home, self.app = home, app
        self.dirs = {kind: set(values) for kind, values in dirs.items()}
        self.violations = []
        trees, files, secret_trees, secret_prefixes = set(), set(), set(), set()
        for kind in ("config", "state", "data"):
            for d in self.dirs[kind]:
                trees |= _variants(os.path.join(d, app))
        for p in (".claude", ".codex"):
            trees |= _variants(os.path.join(home, p))
        for p in (".claude.json", os.path.join(".local", "bin", "ccl-sync"), os.path.join(".local", "bin", app)):
            files |= _variants(os.path.join(home, p))
        for d in self.dirs["config"]:
            for p in (("systemd", "user", "ccl-sync.service"), ("systemd", "user", "ccl-sync.timer"),
                      ("autostart", app + ".desktop")):
                files |= _variants(os.path.join(d, *p))
            app_dir = os.path.join(d, app)
            secret_trees |= _variants(os.path.join(app_dir, "github-credentials"))
            for v in _variants(app_dir):
                secret_prefixes |= {os.path.join(v, "github-token"), os.path.join(v, ".github-token")}
        for d in self.dirs["data"]:
            files |= _variants(os.path.join(d, "applications", app + ".desktop"))
        self.trees, self.files = frozenset(trees), frozenset(files)
        self.secret_trees, self.secret_prefixes = frozenset(secret_trees), frozenset(secret_prefixes)
        # every ancestor of a protected location: the base of a relative path whose dir_fd is unknown
        ancestors = set()
        for p in trees | files:
            d = os.path.dirname(p)
            while d and d not in ancestors:
                ancestors.add(d)
                if d == os.path.dirname(d):
                    break
                d = os.path.dirname(d)
        self.ancestors = frozenset(ancestors)

    # ---- matching (lexical on already resolved candidates) -------------------------------------------------------
    def _hit(self, p):
        return p in self.files or any(p == t or p.startswith(t + os.sep) for t in self.trees)

    def _secret(self, p):
        return (any(p == t or p.startswith(t + os.sep) for t in self.secret_trees)
                or any(p.startswith(prefix) and os.sep not in p[len(prefix):] for prefix in self.secret_prefixes))

    def candidates(self, path, dir_fd=None, follow=True, unknown_dir_fd=False):
        path = _text(path)
        if path is None:
            return set()
        if os.path.isabs(path):
            bases = [None]
        elif isinstance(dir_fd, int) and dir_fd >= 0:
            try:
                bases = [os.readlink("/proc/self/fd/%d" % dir_fd)]
            except OSError:
                bases = [os.getcwd()]
        else:
            bases = [os.getcwd()] + (sorted(self.ancestors) if unknown_dir_fd else [])
        out = set()
        for base in bases:
            p = _abs(path if base is None else os.path.join(base, path))
            out.add(p)
            parent, name = os.path.split(p)
            try:
                out.add(os.path.join(os.path.realpath(parent), name))
                if follow:
                    out.add(os.path.realpath(p))
            except (OSError, ValueError):
                pass
        return out

    def protected(self, path, dir_fd=None, follow=True, unknown_dir_fd=False):
        return any(self._hit(p) for p in self.candidates(path, dir_fd, follow, unknown_dir_fd))

    def secret(self, path, unknown_dir_fd=False):
        return any(self._secret(p) for p in self.candidates(path, None, True, unknown_dir_fd))

    def child_env_is_real(self, env):
        dirs = _dirs_of(env, REAL_HOME)
        return [kind for kind in dirs if dirs[kind] in self.dirs[kind]]

    def argv_hits(self, argv):
        if isinstance(argv, (str, bytes)) or hasattr(argv, "__fspath__"):
            argv = [argv]
        hits = []
        for arg in argv or ():
            text = _text(arg)
            if text is None:
                continue
            for word in text.replace("=", " ").replace(":", " ").split():
                word = word.strip("'\"")
                if os.path.isabs(word) and self.protected(word):
                    hits.append(word)
        return hits

    # ---- the hook body ---------------------------------------------------------------------------------------------
    def check(self, event, args):
        if event == "open":
            if not args:
                return
            flags = args[2] if len(args) >= 3 and isinstance(args[2], int) else 0
            if self.secret(args[0], unknown_dir_fd=True):
                self.refuse(event, args[0], "открытие реального токена GitHub")
            if flags & _WRITE_FLAGS and self.protected(args[0], unknown_dir_fd=True):
                self.refuse(event, args[0], "запись в реальные файлы владельца")
            return
        spec = _PATH_EVENTS.get(event)
        if spec is not None:
            for index, fd_index, follow in spec:
                if index < len(args) and args[index] is not None:
                    dir_fd = args[fd_index] if fd_index is not None and fd_index < len(args) else None
                    if self.protected(args[index], dir_fd, follow):
                        self.refuse(event, args[index], "запись в реальные файлы владельца")
            return
        child = _CHILD_EVENTS.get(event)
        if child is not None:
            argv_index, env_index = child
            argv = args[argv_index] if argv_index < len(args) else None
            env = args[env_index] if env_index is not None and env_index < len(args) else None
            env = os.environ if env is None or not hasattr(env, "get") else env
            real = self.child_env_is_real(env)
            if real:
                self.refuse(event, "%r → real %s dir" % (argv, "/".join(real)),
                            "дочерний процесс видит реальные каталоги приложения")
            hits = self.argv_hits(argv)
            if hits:
                self.refuse(event, "%r → %s" % (argv, hits), "реальный путь в аргументах дочернего процесса")

    def refuse(self, event, what, why):
        self.violations.append((event, _text(what) if not isinstance(what, int) else what, _who()))
        raise PermissionError("%s (%s): %s" % (why, event, what))


def _who():
    f = sys._getframe(3)
    while f is not None:
        name = f.f_code.co_name
        if name.startswith("test"):
            return "%s (%s)" % (name, os.path.basename(f.f_code.co_filename))
        f = f.f_back
    return "?"


# One state per process: the module may be imported as `_real_guard` and `tests._real_guard`; a second copy imported
# after `_isolate` moved XDG_* must not take the sandbox for the real directories.
_SHARED = getattr(sys, "_ccl_real_guard", None)
if _SHARED is None:
    _default = _dirs_of({"HOME": REAL_HOME}, REAL_HOME)
    _original = _dirs_of(dict(os.environ, HOME=REAL_HOME), REAL_HOME)
    _SHARED = sys._ccl_real_guard = {
        "real": Policy(REAL_HOME, {kind: {_default[kind], _original[kind]} for kind in _default}),
        "extra": [], "hooked": False}
REAL = _SHARED["real"]
REAL_DIRS = REAL.dirs
VIOLATIONS = REAL.violations


def _hook(event, args):
    if event != "open" and event not in _PATH_EVENTS and event not in _CHILD_EVENTS:
        return
    for policy in [_SHARED["real"]] + list(_SHARED["extra"]):
        policy.check(event, args)


if not _SHARED["hooked"]:
    _SHARED["hooked"] = True
    sys.addaudithook(_hook)


@contextlib.contextmanager
def extra_policy(policy):
    """Self-tests: enforce a synthetic policy (sandbox paths) through the same installed hook."""
    _SHARED["extra"].append(policy)
    try:
        yield policy
    finally:
        _SHARED["extra"].remove(policy)


def protected(path):
    return REAL.protected(path)


def child_env_is_real(env):
    return REAL.child_env_is_real(env)


def assert_clean():
    if VIOLATIONS:
        raise AssertionError("tests tried to touch the owner's real files: %s" % (VIOLATIONS,))
