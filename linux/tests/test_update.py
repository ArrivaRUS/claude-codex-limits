"""Self-update helpers: version compare and the tarball extraction filter."""

import io
import os
import shutil
import sys
import tarfile
import tempfile
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from ccl import update  # noqa: E402


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


if __name__ == "__main__":
    unittest.main()
