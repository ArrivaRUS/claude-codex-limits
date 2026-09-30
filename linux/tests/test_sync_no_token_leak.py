"""The token never leaves the token store except in the Authorization header
(docs/sync-protocol.md → Transport): not in sync-state.json, lastError, the remote cache, the
gist file, or `ccl-sync push --quiet` / `status` output. Offline, fake keyring."""

if __package__:
    from . import _sync_env as env
else:
    import _sync_env as env

import contextlib
import io
import json
import os
import unittest

from ccl import cli, common, sync

T = env.resp


def tearDownModule():
    env.assert_real_files_untouched()


class TestNoTokenLeak(env.SyncEnv):
    # Scenario 16
    def setUp(self):
        super().setUp()
        self.sign_in()
        self._saved_timer = cli._timer_status
        cli._timer_status = lambda: "stub"          # no systemctl / crontab in tests

    def tearDown(self):
        cli._timer_status = self._saved_timer
        super().tearDown()

    def run_cli(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = cli.main(list(argv))
        return rc, out.getvalue() + err.getvalue()

    def assertClean(self, where, text):
        self.assertTrue(self.token, "token fixture")
        self.assertNotIn(self.token, text, where)
        self.assertNotIn(self.token[4:], text, where + " (without prefix)")
        self.assertNotIn(self.token[-16:], text, where + " (tail)")

    def files_text(self):
        out = []
        for p in (common.SYNC_STATE_PATH, common.SYNC_REMOTE_PATH, common.USAGE_INDEX_PATH, common.SETTINGS_PATH):
            if os.path.exists(p):
                with open(p, encoding="utf-8") as f:
                    out.append(f.read())
        return "\n".join(out)

    def test_nowhere_but_the_header(self):
        others = {"machine-aa.json": env.machine_json("aa")}
        # 1) successful cycle with a write: the gist file must not carry the token
        self.gh.on("GET", "/gists/g1", self.ok_gist(others))
        self.gh.on("PATCH", "/gists/g1", T(200, {}))
        rc, text = self.run_cli("push", "--quiet")
        self.assertEqual(rc, 0, text)
        self.assertClean("push --quiet (ok)", text)
        patch = next(c for c in self.gh.calls if c.method == "PATCH")
        self.assertClean("PATCH body", json.dumps(patch.body))
        # 2) status reads the token and the gist
        self.gh.on("GET", "/gists/g1", self.ok_gist(others))
        rc, text = self.run_cli("status")
        self.assertEqual(rc, 0, text)
        self.assertIn("GitHub: me", text)
        self.assertClean("status", text)
        # 3) inconclusive 401 → error text in state and in output
        self.gh.on("GET", "/gists/g1", T(401, {"message": "Bad credentials"}))
        self.gh.on("GET", "/user", T(500, {"message": "x"}))
        rc, text = self.run_cli("push", "--quiet")
        self.assertEqual(rc, 1)
        self.assertIn("проверка входа не прошла", text)
        self.assertClean("push --quiet (401)", text)
        self.assertClean("lastError", str(self.st().get("lastError")))
        # 4) confirmed revocation
        self.gh.on("GET", "/gists/g1", T(401))
        self.gh.on("GET", "/user", T(401), T(401))
        rc, text = self.run_cli("push", "--quiet")
        self.assertEqual(rc, 2)
        self.assertClean("push --quiet (revoked)", text)
        rc, text = self.run_cli("status")
        self.assertClean("status (revoked)", text)
        # 5) every request carried the token only in Authorization, never in the URL
        for c in self.gh.calls:
            self.assertClean("URL", c.url)
            others_h = {k: v for k, v in c.headers.items() if k.lower() != "authorization"}
            self.assertClean("headers", json.dumps(others_h))
        self.assertClean("state/remote/index files", self.files_text())

    def test_file_backend_token_file_only(self):
        """The 0600 fallback file is the one place the token may be written."""
        vault_ss = sync.vault._ss
        sync.vault._ss = lambda: None
        try:
            with common.file_lock("sync"):
                self.assertEqual(sync.vault.write(self.token), "file")
        finally:
            sync.vault._ss = vault_ss
        self.assertEqual(os.stat(common.TOKEN_FILE_PATH).st_mode & 0o777, 0o600)
        self.assertClean("state", self.files_text())


if __name__ == "__main__":
    unittest.main()
