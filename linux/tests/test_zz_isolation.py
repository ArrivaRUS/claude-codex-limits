"""Runs last under `unittest discover` (alphabetical): the whole suite neither created nor modified the owner's
real files (lesson 006). Since A5 an installed publisher on this machine rewrites its state files every 5 minutes,
so the signal is not mtime but `_real_guard`: every write-like operation of the test process on a real path was
refused and recorded, and so was a child process whose app directories were the real ones. Contents are never read.
The guard's own self-test (A5-16) runs on a synthetic home in the sandbox (m8), never on the real paths."""

if __package__:
    from . import _isolate
else:
    import _isolate

import os
import subprocess
import tempfile
import unittest

from ccl import common


class TestRealFilesUntouched(unittest.TestCase):
    # Scenario 17
    def test_no_write_reached_real_files(self):
        self.assertEqual(_isolate._real_guard.VIOLATIONS, [])

    def test_real_policy_covers_token_and_trees_lexically(self):
        """Pure matching on the real policy — no operation on the real paths (m8)."""
        g = _isolate._real_guard
        config = os.path.join(sorted(g.REAL.dirs["config"])[0], g.APP)
        self.assertTrue(any(g.REAL._secret(p) for p in (os.path.join(config, "github-token"),)))
        self.assertTrue(g.REAL._secret(os.path.join(config, "github-credentials", "a" * 32)))
        self.assertTrue(g.REAL._secret(os.path.join(config, ".github-token.tmp1")))
        self.assertTrue(g.REAL._hit(os.path.join(sorted(g.REAL.dirs["state"])[0], g.APP, "publisher.jsonl")))
        self.assertTrue(g.REAL._hit(os.path.join(g.REAL_HOME, ".claude.json")))
        self.assertFalse(g.REAL._hit(os.path.join(_isolate.ROOT, "x")))


class TestGuardSelfTest(unittest.TestCase):
    """A5-16 (T2 M5/m8): the guard on a SYNTHETIC home in the sandbox, enforced through the installed hook."""

    def setUp(self):
        g = _isolate._real_guard
        self.root = tempfile.mkdtemp(prefix="guard-", dir=_isolate.ROOT)
        self.home = os.path.join(self.root, "home")
        self.config = os.path.join(self.home, ".config")
        self.name = "ccl-guard-selftest"              # not the real app name: relative paths never hit the REAL policy
        self.app = os.path.join(self.config, self.name)
        os.makedirs(self.app)
        with open(os.path.join(self.app, "github-token"), "w") as f:
            f.write("synthetic\n")
        os.makedirs(os.path.join(self.app, "github-credentials"))
        self.policy = g.Policy(self.home, {"config": {self.config},
                                           "state": {os.path.join(self.home, ".local", "state")},
                                           "data": {os.path.join(self.home, ".local", "share")}}, app=self.name)
        self.outside = os.path.join(self.root, "outside")
        os.makedirs(self.outside)
        self.real_before = list(g.VIOLATIONS)

    def tearDown(self):
        self.assertEqual(_isolate._real_guard.VIOLATIONS, self.real_before, "self-test touched the REAL policy")

    def refused(self, action):
        start = len(self.policy.violations)
        with _isolate._real_guard.extra_policy(self.policy):
            with self.assertRaises(PermissionError):
                action()
        return self.policy.violations[start:]

    def allowed(self, action):
        with _isolate._real_guard.extra_policy(self.policy):
            return action()

    def test_write_through_sandbox_symlink(self):
        link = os.path.join(self.outside, "link")
        os.symlink(self.app, link)
        probe = os.path.join(link, "probe")
        self.assertEqual(len(self.refused(lambda: open(probe, "w"))), 1)
        self.assertEqual(len(self.refused(lambda: os.mkdir(probe))), 1)
        filelink = os.path.join(self.outside, "filelink")
        os.symlink(os.path.join(self.app, "settings.json"), filelink)
        self.assertEqual(len(self.refused(lambda: open(filelink, "w"))), 1)
        self.assertFalse(os.path.lexists(os.path.join(self.app, "probe")), "refused before the syscall")
        self.assertFalse(os.path.lexists(os.path.join(self.app, "settings.json")))
        # removing the sandbox link itself is not a write into the protected tree
        self.allowed(lambda: os.unlink(filelink))

    def test_dir_fd_relative_operations(self):
        fd = os.open(self.config, os.O_RDONLY)
        try:
            rel = os.path.join(self.name, "probe")
            self.assertEqual(len(self.refused(lambda: os.mkdir(rel, dir_fd=fd))), 1)
            self.assertEqual(len(self.refused(lambda: os.open(rel, os.O_WRONLY | os.O_CREAT, 0o600, dir_fd=fd))), 1)
            self.assertEqual(len(self.refused(lambda: os.unlink(os.path.join(self.name, "github-token"),
                                                                dir_fd=fd))), 1)
        finally:
            os.close(fd)
        self.assertFalse(os.path.lexists(os.path.join(self.app, "probe")))
        self.assertTrue(os.path.exists(os.path.join(self.app, "github-token")))

    def test_reading_the_token_is_refused(self):
        self.assertEqual(len(self.refused(lambda: open(os.path.join(self.app, "github-token")).read())), 1)
        self.assertEqual(len(self.refused(lambda: open(os.path.join(self.app, ".github-token.x1"), "r"))), 1)
        self.assertEqual(len(self.refused(lambda: os.open(os.path.join(self.app, "github-credentials", "a" * 32),
                                                          os.O_RDONLY))), 1)
        link = os.path.join(self.outside, "tok")
        os.symlink(os.path.join(self.app, "github-token"), link)
        self.assertEqual(len(self.refused(lambda: open(link).read())), 1)
        # other files of the tree stay readable (settings, state)
        with open(os.path.join(self.app, "settings.json"), "w") as f:
            f.write("{}")
        self.assertEqual(self.allowed(lambda: open(os.path.join(self.app, "settings.json")).read()), "{}")

    def test_children(self):
        sandbox = {"PATH": "/usr/bin:/bin", "HOME": self.outside}
        self.assertEqual(len(self.refused(lambda: subprocess.run(["true"], env={"PATH": "/usr/bin:/bin",
                                                                                   "HOME": self.home}))), 1)
        self.assertEqual(len(self.refused(lambda: subprocess.run(["true", os.path.join(self.app, "x")],
                                                                 env=sandbox))), 1)
        self.assertEqual(len(self.refused(lambda: subprocess.run(["sh", "-c", "true " + self.app + "/x"],
                                                                 env=sandbox))), 1)
        self.assertEqual(len(self.refused(lambda: os.system("true " + os.path.join(self.app, "x")))), 1)
        self.assertEqual(self.allowed(lambda: subprocess.run(["true", self.outside], env=sandbox).returncode), 0)

    def test_sandbox_writes_and_reads_allowed(self):
        path = os.path.join(self.outside, "ok")
        self.allowed(lambda: open(path, "w").close())
        self.allowed(lambda: os.replace(path, path + "2"))
        self.allowed(lambda: os.unlink(path + "2"))
        self.assertEqual(self.policy.violations, [])


class TestSandboxPaths(unittest.TestCase):
    def test_module_paths_point_into_the_sandbox(self):
        home = os.path.expanduser("~")
        for name in ("CONFIG_DIR", "STATE_DIR", "TOKEN_FILE_PATH", "MACHINE_ID_PATH", "SYNC_STATE_PATH",
                     "SYNC_REMOTE_PATH", "CLAUDE_PROJECTS", "CLAUDE_CREDENTIALS", "CODEX_SESSIONS", "CODEX_AUTH",
                     "CLAUDE_JSON"):
            path = getattr(common, name)
            self.assertTrue(path.startswith(_isolate.ROOT), (name, path))
            self.assertFalse(path.startswith(os.path.join(home, ".config")), name)

    def test_v2_credential_and_writer_dirs_are_temporary(self):
        for root, leaf in ((common.CONFIG_DIR, "github-credentials"),
                           (common.STATE_DIR, "github-credential-writers")):
            path = os.path.realpath(os.path.join(root, leaf))
            self.assertTrue(path.startswith(os.path.realpath(_isolate.ROOT) + os.sep), path)
            self.assertTrue(path.startswith("/tmp/") or path.startswith("/private/tmp/"), path)


if __name__ == "__main__":
    unittest.main()
