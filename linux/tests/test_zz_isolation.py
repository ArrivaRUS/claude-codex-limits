"""Runs last under `unittest discover` (alphabetical): the whole suite neither created nor modified the owner's
real files (lesson 006). Since A5 an installed publisher on this machine rewrites its state files every 5 minutes,
so the signal is not mtime but `_real_guard`: every write-like operation of the test process on a real path was
refused and recorded, and so was a child process whose app directories were the real ones. Contents are never read."""

if __package__:
    from . import _isolate
else:
    import _isolate

import os
import secrets
import subprocess
import unittest

from ccl import common


class TestRealFilesUntouched(unittest.TestCase):
    # Scenario 17
    def test_no_write_reached_real_files(self):
        self.assertEqual(_isolate._real_guard.VIOLATIONS, [])

    def guarded(self, action):
        """Run an action the guard must refuse; drop only the violations it recorded itself."""
        start = len(_isolate._real_guard.VIOLATIONS)
        try:
            with self.assertRaises(PermissionError):
                action()
            return _isolate._real_guard.VIOLATIONS[start:]
        finally:
            del _isolate._real_guard.VIOLATIONS[start:]

    def test_guard_refuses_writes_before_the_syscall(self):
        g = _isolate._real_guard
        state = os.path.join(sorted(g.REAL_DIRS["state"])[0], g.APP)
        probe = os.path.join(state, ".ccl-guard-probe-" + secrets.token_hex(8))
        actions = {
            "open": lambda: open(probe, "w"),
            "os.open": lambda: os.open(probe, os.O_WRONLY | os.O_CREAT, 0o600),
            "os.rename": lambda: os.replace(os.path.join(_isolate.ROOT, "nothing"), probe),
            "os.remove": lambda: os.unlink(probe),
            "os.mkdir": lambda: os.mkdir(probe),
            "claude.json": lambda: open(os.path.join(g.REAL_HOME, ".claude.json"), "a"),
        }
        for name, action in actions.items():
            with self.subTest(name):
                self.assertEqual(len(self.guarded(action)), 1)
        self.assertFalse(os.path.lexists(probe), "the guard ran before the operation")

    def test_guard_allows_reads_and_sandbox_writes(self):
        g = _isolate._real_guard
        start = len(g.VIOLATIONS)
        path = os.path.join(_isolate.ROOT, "guard-ok")
        with open(path, "w") as f:
            f.write("x")
        os.unlink(path)
        self.assertFalse(g.protected(path))
        self.assertEqual(len(g.VIOLATIONS), start)

    def test_guard_refuses_child_with_real_app_dirs(self):
        g = _isolate._real_guard
        for env in ({"PATH": "/usr/bin:/bin"}, {"PATH": "/usr/bin:/bin", "HOME": g.REAL_HOME},
                    {"PATH": "/usr/bin:/bin", "HOME": _isolate.ROOT, "XDG_STATE_HOME": sorted(g.REAL_DIRS["state"])[0]}):
            with self.subTest(env=sorted(env)):
                self.assertEqual(len(self.guarded(lambda: subprocess.run(["true"], env=env))), 1)
        sandbox = {"PATH": "/usr/bin:/bin", "HOME": _isolate.ROOT}
        self.assertEqual(subprocess.run(["true"], env=sandbox).returncode, 0)
        self.assertEqual(g.child_env_is_real(sandbox), [])

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
