"""Updates of the installed Linux port. Two kinds of install, two update paths:

* per-user (`linux/install.sh`, under ~/.local/share): its version is `APP_VERSION` in
  `linux/ccl/__init__.py` on `main`, and an update is: download the branch tarball, take
  `linux/` + `Resources/` from it, run its own `linux/install.sh` with the same choices
  (autostart / timer) as the current install;
* the .deb (under /usr/share, owned by dpkg): updates are GitHub releases tagged
  `linux-v<version>` with a `…_all.deb` asset. The new package is downloaded to the user's
  Downloads folder and handed to the system package installer — root is the user's call.

The Mac app's releases are tagged `v<version>` and hold the DMG; `linux-v…` releases are
published with `--latest=false` (linux/packaging/release.sh), so `releases/latest` stays
the Mac's. A run from a git checkout is never overwritten — that one updates with `git pull`.
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
RELEASES_API = "https://api.github.com/repos/%s/releases?per_page=30" % REPO
RELEASES_PAGE = "https://github.com/%s/releases" % REPO
DEB_TAG = "linux-v"
MAX_TARBALL = 64 * 1024 * 1024
MAX_DEB = 32 * 1024 * 1024
UA = {"User-Agent": "ClaudeCodexLimits"}
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


def is_packaged():
    """Installed from the .deb: the files live under /usr and belong to dpkg."""
    return app_dir().startswith("/usr/")


def changes_url():
    if is_packaged():
        return common.state().get("updatePage") or RELEASES_PAGE
    return CHANGES_URL


def latest_deb(releases):
    """The newest published `linux-v…` release that carries a .deb → (version, url, page) or None.
    The Mac's `v…` releases, drafts and pre-releases are skipped."""
    best = None
    for r in releases if isinstance(releases, list) else []:
        if not isinstance(r, dict) or r.get("draft") or r.get("prerelease"):
            continue
        tag = r.get("tag_name") or ""
        ver = tag[len(DEB_TAG):]
        if not tag.startswith(DEB_TAG) or not re.match(r"^\d+(\.\d+)*$", ver):
            continue
        url = None
        for a in r.get("assets") or []:
            if isinstance(a, dict) and str(a.get("name") or "").endswith("_all.deb"):
                url = a.get("browser_download_url")
                break
        if url and (best is None or is_newer(ver, best[0])):
            best = (ver, url, r.get("html_url") or RELEASES_PAGE)
    return best


def _check_releases():
    r = common.http(RELEASES_API, headers=dict(UA, Accept="application/vnd.github+json"), timeout=15)
    if r.status != 200 or not r.data:
        return None, ("HTTP %d" % r.status) if r.status else (r.error or "network")
    rel = latest_deb(r.json())
    if not rel:
        return None, common.tr("в Releases пока нет Linux-пакета", "no Linux package in Releases yet")
    ver, url, page = rel
    newer = is_newer(ver, APP_VERSION)
    common.state().update(updateCheckedAt=time.time(), updateAvailable=ver if newer else None,
                          updateDebUrl=url if newer else None, updatePage=page if newer else None)
    return ver, None


def check():
    """→ (latest_version or None, error or None). Remembers the result in the state file."""
    if is_packaged():
        return _check_releases()
    r = common.http(VERSION_URL, headers=UA, timeout=15)
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


def download_dir():
    """The user's Downloads folder (xdg-user-dirs), else ~/Downloads, else the state dir."""
    d = None
    try:
        p = subprocess.run(["xdg-user-dir", "DOWNLOAD"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=5)
        d = p.stdout.decode("utf-8", "replace").strip()
    except (OSError, subprocess.SubprocessError):
        pass
    if not d or os.path.normpath(d) == os.path.normpath(common.HOME) or not os.path.isdir(d):
        d = os.path.join(common.HOME, "Downloads")
    if not os.path.isdir(d):
        common.ensure_dirs()
        d = common.STATE_DIR
    return d


def is_deb(data):
    """A Debian package is an ar archive whose first member is `debian-binary`."""
    return bool(data) and data[:8] == b"!<arch>\n" and data[8:24].rstrip(b" /") == b"debian-binary"


def fetch_deb():
    """Download the newer .deb found by `check()` → (version, path). Installing it needs root,
    so that is left to the system package installer (GUI) or `sudo apt install` (CLI)."""
    st = common.state()
    st.reload()
    ver, url = st.get("updateAvailable"), st.get("updateDebUrl")
    if not (ver and url and is_newer(ver, APP_VERSION)):
        _latest, err = _check_releases()
        if err:
            raise RuntimeError(err)
        ver, url = st.get("updateAvailable"), st.get("updateDebUrl")
        if not (ver and url):
            raise RuntimeError(common.tr("Установлена последняя версия.", "You're up to date."))
    r = common.http(url, headers=UA, timeout=120)
    if r.status != 200 or not r.data:
        raise RuntimeError(common.tr("Не удалось скачать пакет", "Download failed")
                           + (" (HTTP %d)" % r.status if r.status else ""))
    if len(r.data) > MAX_DEB or not is_deb(r.data):
        raise RuntimeError(common.tr("Скачанный файл — не пакет .deb", "The download is not a .deb package"))
    path = os.path.join(download_dir(), "claude-codex-limits_%s_all.deb" % ver)
    common.write_atomic(path, r.data, 0o644)
    return ver, path


def apply():
    """Download main, check it, run its installer. → (new_version, installer_output).
    Raises RuntimeError with a readable message."""
    if is_packaged():
        raise RuntimeError(common.tr("Установлено из пакета .deb — обновление ставится новым пакетом.",
                                     "Installed from the .deb — updates come as a new package."))
    if is_checkout():
        raise RuntimeError(common.tr("Запущено из git-копии — обновляйте её командой git pull.",
                                     "Running from a git checkout — update it with git pull."))
    common.ensure_dirs()
    tmp = tempfile.mkdtemp(prefix="update-", dir=common.STATE_DIR)
    try:
        r = common.http(TARBALL_URL, headers=UA, timeout=120)
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
