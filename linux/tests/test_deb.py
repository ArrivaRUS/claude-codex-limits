"""The .deb built by linux/packaging/build-deb.sh: control fields, file list, modes, and that the
unpacked program starts. Skipped where dpkg-deb isn't installed."""

if __package__:
    from . import _isolate  # noqa: F401
else:
    import _isolate  # noqa: F401


import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
LINUX = os.path.dirname(HERE)
sys.path.insert(0, LINUX)

from ccl import APP_VERSION, update  # noqa: E402

PKG = "claude-codex-limits"


def run(*cmd):
    return subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True).stdout.decode("utf-8")


@unittest.skipUnless(shutil.which("dpkg-deb"), "dpkg-deb not installed")
class TestDeb(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp()
        cls.deb = run("sh", os.path.join(LINUX, "packaging", "build-deb.sh"), cls.tmp).strip()
        cls.listing = {}
        for line in run("dpkg-deb", "-c", cls.deb).splitlines():
            f = line.split()
            cls.listing[f[5][1:]] = (f[0], f[1])            # path without the leading "." → (mode, owner)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp)

    def field(self, name):
        return run("dpkg-deb", "-f", self.deb, name).strip()

    def test_control(self):
        self.assertEqual(os.path.basename(self.deb), "%s_%s_all.deb" % (PKG, APP_VERSION))
        self.assertEqual(self.field("Version"), APP_VERSION)
        self.assertEqual(self.field("Architecture"), "all")
        for dep in ("python3-pyqt5", "python3-dbus"):
            self.assertIn(dep, self.field("Depends"))
        with open(self.deb, "rb") as f:
            self.assertTrue(update.is_deb(f.read(64)))

    def test_files(self):
        must = ["/usr/bin/claude-codex-limits", "/usr/bin/ccl-sync", "/usr/share/applications/%s.desktop" % PKG,
                "/usr/share/icons/hicolor/256x256/apps/%s.png" % PKG, "/usr/lib/systemd/user/ccl-sync.timer",
                "/usr/lib/systemd/user/ccl-sync.service", "/usr/share/%s/ccl/gui/app.py" % PKG,
                "/usr/share/%s/Resources/snd-chime.wav" % PKG, "/usr/share/doc/%s/copyright" % PKG]
        for p in must:
            self.assertIn(p, self.listing)
        for p, (mode, owner) in self.listing.items():
            self.assertEqual(owner, "root/root", p)
            self.assertNotIn("__pycache__", p)
            self.assertFalse(p.endswith(".pyc"), p)
            self.assertTrue(p.startswith("/usr/") or p == "/", p)        # nothing in /etc, no conffiles
            if mode.startswith("d"):
                self.assertEqual(mode, "drwxr-xr-x", p)
            elif p.startswith("/usr/bin/"):
                self.assertEqual(mode, "-rwxr-xr-x", p)
            else:
                self.assertIn(mode, ("-rw-r--r--", "-rwxr-xr-x"), p)

    def test_unpacked_program_runs(self):
        root = os.path.join(self.tmp, "root")
        run("dpkg-deb", "-x", self.deb, root)
        with open(os.path.join(root, "usr", "bin", "ccl-sync")) as f:
            self.assertIn("exec /usr/bin/python3 /usr/share/%s/ccl-sync" % PKG, f.read())
        out = run(sys.executable, os.path.join(root, "usr", "share", PKG, "ccl-sync"), "--version")
        self.assertIn(APP_VERSION, out)
        with open(os.path.join(root, "usr", "lib", "systemd", "user", "ccl-sync.service")) as f:
            self.assertIn("ExecStart=/usr/bin/ccl-sync push --auto --quiet", f.read())


if __name__ == "__main__":
    unittest.main()
