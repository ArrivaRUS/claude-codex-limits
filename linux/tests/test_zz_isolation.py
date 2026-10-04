"""Runs last under `unittest discover` (alphabetical): the user's real sync files were neither
created nor modified by the whole suite (lesson 006). Presence and mtime only — never contents."""

if __package__:
    from . import _isolate
else:
    import _isolate

import os
import unittest

from ccl import common


class TestRealFilesUntouched(unittest.TestCase):
    # Scenario 17
    def test_real_token_machine_id_and_state_unchanged(self):
        now = _isolate.real_files_state()
        changed = {p: (_isolate.REAL_BEFORE[p], now[p]) for p in now if now[p] != _isolate.REAL_BEFORE[p]}
        self.assertEqual(changed, {})

    def test_module_paths_point_into_the_sandbox(self):
        home = os.path.expanduser("~")
        for name in ("CONFIG_DIR", "STATE_DIR", "TOKEN_FILE_PATH", "MACHINE_ID_PATH", "SYNC_STATE_PATH",
                     "SYNC_REMOTE_PATH", "CLAUDE_PROJECTS", "CLAUDE_CREDENTIALS", "CODEX_SESSIONS", "CODEX_AUTH"):
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
