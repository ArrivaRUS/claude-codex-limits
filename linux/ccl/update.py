"""Self-update of the installed Linux port from the repository's `main` branch.

The Mac app updates from GitHub releases (DMG); the Linux port has no binary to ship, so its
version is `APP_VERSION` in `linux/ccl/__init__.py` on `main`, and an update is: download the
branch tarball, take `linux/` + `Resources/` from it, run its own `linux/install.sh` with the
same choices (autostart / timer) as the current install.

A run from a git checkout is never overwritten — that one updates with `git pull`.
"""

import os
import re
import shutil
import subprocess
import tarfile
import tempfile
import time

from . import APP_VERSION, common

REPO = "ArrivaRUS/claude-codex-limits"
BRANCH = "main"
VERSION_URL = "https://raw.githubusercontent.com/%s/%s/linux/ccl/__init__.py" % (REPO, BRANCH)
TARBALL_URL = "https://codeload.github.com/%s/tar.gz/refs/heads/%s" % (REPO, BRANCH)
CHANGES_URL = "https://github.com/%s/commits/%s/linux" % (REPO, BRANCH)
MAX_TARBALL = 64 * 1024 * 1024
CHECK_EVERY = 6 * 3600

_VER_RE = re.compile(r'^APP_VERSION\s*=\s*["\'](\d+(?:\.\d+)*)["\']', re.M)


def parse_version(text):
    m = _VER_RE.search(text or "")
    return m.group(1) if m else None


def vtuple(v):
    return tuple(int(x) for x in v.split("."))


def is_newer(a, b):
    """a > b for dotted versions."""
    try:
        return vtuple(a) > vtuple(b)
    except (ValueError, AttributeError):
        return False


def app_dir():
    """The directory holding `ccl/` and the two entry scripts."""
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def is_checkout():
    return os.path.isdir(os.path.join(os.path.dirname(app_dir()), ".git"))


def check():
    """→ (latest_version or None, error or None). Remembers the result in the state file."""
    r = common.http(VERSION_URL, headers={"User-Agent": "ClaudeCodexLimits"}, timeout=15)
    st = common.state()
    if r.status == 404:
        st.update(updateCheckedAt=time.time(), updateAvailable=None)
        return None, common.tr("в main пока нет Linux-версии", "no Linux version on main yet")
    if r.status != 200 or not r.data:
        return None, ("HTTP %d" % r.status) if r.status else (r.error or "network")
    latest = parse_version(r.data.decode("utf-8", "replace"))
    if not latest:
        return None, "no APP_VERSION"
    st.update(updateCheckedAt=time.time(), updateAvailable=latest if is_newer(latest, APP_VERSION) else None)
    return latest, None


def available():
    v = common.state().get("updateAvailable")
    return v if v and is_newer(v, APP_VERSION) else None


def due():
    return time.time() - float(common.state().get("updateCheckedAt") or 0) > CHECK_EVERY


def _installer_flags():
    conf = os.environ.get("XDG_CONFIG_HOME") or os.path.join(common.HOME, ".config")
    flags = []
    if not os.path.exists(os.path.join(conf, "autostart", "claude-codex-limits.desktop")):
        flags.append("--no-autostart")
    timer = os.path.exists(os.path.join(conf, "systemd", "user", "ccl-sync.timer"))
    if not timer:
        try:
            r = subprocess.run(["crontab", "-l"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=5)
            timer = b"ccl-sync" in r.stdout
        except (OSError, subprocess.SubprocessError):
            pass
    if not timer:
        flags.append("--no-timer")
    return flags


def _safe_extract(tar, dest):
    """Regular files and directories under <top>/linux/ and <top>/Resources/ only — no links,
    no absolute paths, no `..` (tarfile's own filters need Python 3.12)."""
    root = None
    for m in tar.getmembers():
        parts = m.name.split("/")
        if root is None:
            root = parts[0]
        if (m.name.startswith("/") or ".." in parts or parts[0] != root or len(parts) < 2
                or parts[1] not in ("linux", "Resources") or not (m.isfile() or m.isdir())):
            continue
        target = os.path.join(dest, *parts)
        if m.isdir():
            os.makedirs(target, exist_ok=True)
            continue
        os.makedirs(os.path.dirname(target), exist_ok=True)
        src = tar.extractfile(m)
        with open(target, "wb") as out:
            shutil.copyfileobj(src, out)
        os.chmod(target, 0o755 if m.mode & 0o111 else 0o644)
    return os.path.join(dest, root) if root else None


def apply():
    """Download main, check it, run its installer. → (new_version, installer_output).
    Raises RuntimeError with a readable message."""
    if is_checkout():
        raise RuntimeError(common.tr("Запущено из git-копии — обновляйте её командой git pull.",
                                     "Running from a git checkout — update it with git pull."))
    common.ensure_dirs()
    tmp = tempfile.mkdtemp(prefix="update-", dir=common.STATE_DIR)
    try:
        r = common.http(TARBALL_URL, headers={"User-Agent": "ClaudeCodexLimits"}, timeout=120)
        if r.status != 200 or not r.data:
            raise RuntimeError(common.tr("Не удалось скачать обновление", "Download failed")
                               + (" (HTTP %d)" % r.status if r.status else ""))
        if len(r.data) > MAX_TARBALL:
            raise RuntimeError("tarball too large")
        tgz = os.path.join(tmp, "src.tar.gz")
        with open(tgz, "wb") as f:
            f.write(r.data)
        with tarfile.open(tgz, "r:gz") as tar:
            top = _safe_extract(tar, os.path.join(tmp, "src"))
        if not top:
            raise RuntimeError("empty tarball")
        installer = os.path.join(top, "linux", "install.sh")
        try:
            with open(os.path.join(top, "linux", "ccl", "__init__.py"), encoding="utf-8") as f:
                new = parse_version(f.read())
        except OSError:
            new = None
        if not new or not os.path.exists(installer):
            raise RuntimeError(common.tr("В архиве нет Linux-версии", "No Linux version in the archive"))
        p = subprocess.run(["sh", installer] + _installer_flags(), stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, timeout=300)
        out = p.stdout.decode("utf-8", "replace")
        if p.returncode != 0:
            raise RuntimeError(common.tr("Установщик завершился с ошибкой:\n", "The installer failed:\n") + out[-800:])
        common.state().update(updateAvailable=None, updateCheckedAt=time.time())
        return new, out
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
