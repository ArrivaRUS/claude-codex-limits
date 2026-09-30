"""Update helpers: version compare, the tarball extraction filter, the .deb release pick and
download. Nothing here reaches the network or the real state folder."""

if __package__:
    from . import _isolate  # noqa: F401
else:
    import _isolate  # noqa: F401


import io
import os
import shutil
import sys
import tarfile
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from ccl import cli, common, sync, update, usage  # noqa: E402

DEB_BYTES = b"!<arch>\ndebian-binary   1234567890  0     0     100644  4         `\n2.0\n"


class Isolated(unittest.TestCase):
    """Points the state/config folders and the state store at a temp dir (lesson 006)."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        # Include every derived config/state path, including token and remote cache.
        roots = (common.CONFIG_DIR, common.STATE_DIR)
        paths = {name: value for name, value in vars(common).items()
                 if isinstance(value, str) and
                 any(value == root or value.startswith(root + os.sep) for root in roots)}
        self.saved = dict(paths, _state=common._state, _settings=common._settings)
        for name, value in paths.items():
            root = next(root for root in roots if value == root or value.startswith(root + os.sep))
            base = "config" if root == roots[0] else "state"
            setattr(common, name, os.path.normpath(os.path.join(self.tmp, base, os.path.relpath(value, root))))
        common._state = common._settings = None

    def tearDown(self):
        for name, value in self.saved.items():
            setattr(common, name, value)
        shutil.rmtree(self.tmp)


def _add(tar, name, data=b"x", kind=tarfile.REGTYPE, link=""):
    ti = tarfile.TarInfo(name)
    ti.type = kind
    ti.linkname = link
    ti.size = len(data) if kind == tarfile.REGTYPE else 0
    ti.mode = 0o755 if name.endswith(".sh") else 0o644
    tar.addfile(ti, io.BytesIO(data) if kind == tarfile.REGTYPE else None)


class TestVersions(unittest.TestCase):
    def test_parse_and_compare(self):
        self.assertEqual(update.parse_version('"""doc"""\n\nAPP_VERSION = "0.10.2"\n'), "0.10.2")
        self.assertIsNone(update.parse_version("VERSION = 1"))
        self.assertTrue(update.is_newer("0.10.0", "0.9.9"))
        self.assertFalse(update.is_newer("0.2.0", "0.2.0"))
        self.assertFalse(update.is_newer("garbage", "0.1.0"))


class TestExtract(unittest.TestCase):
    def test_only_linux_and_resources_no_escapes(self):
        tmp = tempfile.mkdtemp()
        try:
            buf = io.BytesIO()
            with tarfile.open(fileobj=buf, mode="w:gz") as tar:
                _add(tar, "repo-main/linux/install.sh", b"echo hi\n")
                _add(tar, "repo-main/linux/ccl/__init__.py", b'APP_VERSION = "9.9.9"\n')
                _add(tar, "repo-main/Resources/appicon.png", b"png")
                _add(tar, "repo-main/Sources/LimitsMonitor.swift", b"swift")
                _add(tar, "repo-main/linux/../../evil", b"evil")
                _add(tar, "/abs/evil", b"evil")
                _add(tar, "repo-main/linux/link", kind=tarfile.SYMTYPE, link="/etc/passwd")
            buf.seek(0)
            with tarfile.open(fileobj=buf, mode="r:gz") as tar:
                top = update._safe_extract(tar, os.path.join(tmp, "src"))
            got = sorted(os.path.relpath(os.path.join(dp, f), tmp) for dp, _, fs in os.walk(tmp) for f in fs)
            self.assertEqual(got, ["src/repo-main/Resources/appicon.png", "src/repo-main/linux/ccl/__init__.py",
                                   "src/repo-main/linux/install.sh"])
            self.assertTrue(os.access(os.path.join(top, "linux", "install.sh"), os.X_OK))
        finally:
            shutil.rmtree(tmp)


def _rel(tag, assets, **kw):
    r = {"tag_name": tag, "draft": False, "prerelease": False, "html_url": "https://github.com/x/releases/tag/" + tag,
         "assets": [{"name": n, "browser_download_url": "https://github.com/dl/" + n} for n in assets]}
    r.update(kw)
    return r


class TestDebRelease(unittest.TestCase):
    def test_picks_newest_linux_deb(self):
        rels = [_rel("v3.1.2", ["ClaudeCodexLimits-3.1.2.dmg"]),              # the Mac's
                _rel("linux-v0.3.0", ["claude-codex-limits_0.3.0_all.deb"]),
                _rel("linux-v0.10.0", ["claude-codex-limits_0.10.0_all.deb"]),
                _rel("linux-v0.9.0", ["claude-codex-limits_0.9.0_all.deb"]),
                _rel("linux-v0.11.0", ["notes.txt"]),                         # no package attached
                _rel("linux-v0.12.0", ["claude-codex-limits_0.12.0_all.deb"], draft=True),
                _rel("linux-v0.13.0", ["claude-codex-limits_0.13.0_all.deb"], prerelease=True),
                _rel("linux-vnext", ["claude-codex-limits_next_all.deb"]),
                "garbage"]
        ver, url, page = update.latest_deb(rels)
        self.assertEqual(ver, "0.10.0")
        self.assertEqual(url, "https://github.com/dl/claude-codex-limits_0.10.0_all.deb")
        self.assertTrue(page.endswith("/linux-v0.10.0"))
        self.assertIsNone(update.latest_deb([_rel("v3.1.2", ["x.dmg"])]))
        self.assertIsNone(update.latest_deb({"message": "rate limited"}))

    def test_is_deb(self):
        self.assertTrue(update.is_deb(DEB_BYTES))
        self.assertFalse(update.is_deb(b"<html>Not Found</html>"))
        self.assertFalse(update.is_deb(b"!<arch>\nother           "))
        self.assertFalse(update.is_deb(None))

    def test_packaged_by_location(self):
        real = update.app_dir
        try:
            update.app_dir = lambda: "/usr/share/claude-codex-limits"
            self.assertTrue(update.is_packaged())
            update.app_dir = lambda: "/home/u/.local/share/claude-codex-limits"
            self.assertFalse(update.is_packaged())
        finally:
            update.app_dir = real


class TestFetchDeb(Isolated):
    def setUp(self):
        super().setUp()
        self.real = (common.http, update.download_dir)
        update.download_dir = lambda: self.tmp
        common.state().update(updateAvailable="9.9.9", updateDebUrl="https://github.com/dl/p_9.9.9_all.deb")

    def tearDown(self):
        common.http, update.download_dir = self.real
        super().tearDown()

    def test_saves_package(self):
        common.http = lambda url, **kw: common.Resp(200, DEB_BYTES)
        ver, path = update.fetch_deb()
        self.assertEqual(ver, "9.9.9")
        self.assertEqual(path, os.path.join(self.tmp, "claude-codex-limits_9.9.9_all.deb"))
        with open(path, "rb") as f:
            self.assertEqual(f.read(), DEB_BYTES)

    def test_refuses_what_is_not_a_package(self):
        common.http = lambda url, **kw: common.Resp(200, b"<html>captive portal</html>")
        self.assertRaises(RuntimeError, update.fetch_deb)
        common.http = lambda url, **kw: common.Resp(404, b"")
        self.assertRaises(RuntimeError, update.fetch_deb)
        self.assertEqual([f for f in os.listdir(self.tmp) if f.endswith(".deb")], [])


class TestTimerForStrangers(Isolated):
    """The .deb enables the timer for every user; `push --auto` must leave non-users alone."""

    def test_auto_push_without_sign_in_does_nothing(self):
        real = (usage.refresh, sync.sync_cycle)

        def boom(*a, **kw):
            raise AssertionError("must not run")
        usage.refresh = sync.sync_cycle = boom
        try:
            self.assertEqual(cli.main(["push", "--auto", "--quiet"]), 0)
            self.assertFalse(os.path.exists(common.STATE_DIR))
        finally:
            usage.refresh, sync.sync_cycle = real


if __name__ == "__main__":
    unittest.main()
