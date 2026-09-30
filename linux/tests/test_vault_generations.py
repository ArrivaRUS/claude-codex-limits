"""Token generations in the Linux keyring (docs/sync-protocol.md → Linux token generations):
late («zombie») keyring operations, legacy migration, honest sign-out. Offline, fake keyring."""

if __package__:
    from . import _sync_env as env
else:
    import _sync_env as env

import contextlib
import io
import os
import time
import threading
import unittest

from ccl import cli, common, sync, vault

T = env.resp


def tearDownModule():
    env.assert_real_files_untouched()


class TestZombies(env.SyncEnv):
    # Scenario 5
    def test_zombie_write_after_logout_is_never_used(self):
        self.ss.hang_set = self.ss.event()
        self.gh.on("GET", "/user", T(200, {"login": "me"}))
        login = sync.login_finish(self.token)
        self.assertEqual(login, "me")
        st = self.st()
        self.assertEqual(st.get("tokenBackend"), "file", "timed-out keyring write falls back to the file")
        self.assertTrue(sync.logout())
        self.assertFalse(os.path.exists(common.TOKEN_FILE_PATH))
        # A late CreateItem cleans itself on the same connection, even after sign-out.
        cleaned = threading.Event()
        original_delete = self.ss.delete
        def delete_and_signal(generation):
            result = original_delete(generation)
            cleaned.set()
            return result
        self.ss.delete = delete_and_signal
        self.ss.hang_set.set()
        self.assertTrue(cleaned.wait(5))
        self.assertEqual(self.ss.items, {})
        self.assertFalse(os.path.exists(common.TOKEN_FILE_PATH))
        self.assertEqual(vault.read(), (None, None))
        self.gh.calls.clear()
        res = self.cycle()
        self.assertEqual(res.skipped, "signed-out")
        self.assertEqual(self.gh.calls, [], "the deleted token is never sent anywhere")
        out = io.StringIO()
        cli._timer_status, saved = (lambda: "stub"), cli._timer_status
        try:
            with contextlib.redirect_stdout(out):
                cli.main(["status"])
        finally:
            cli._timer_status = saved
        self.assertEqual(self.gh.calls, [])
        self.assertIn("вход не выполнен", out.getvalue())

    # Scenario 6
    def test_zombie_delete_after_fresh_login_spares_new_token(self):
        old_generation, _ = self.sign_in()
        self.ss.hang_delete = self.ss.event()
        self.assertFalse(sync.logout(), "keyring didn't answer → honest False")
        new = env.make_token()
        self.ss.hang_delete = None            # the new session's keyring calls answer normally
        self.gh.on("GET", "/user", T(200, {"login": "me"}))
        sync.login_finish(new)
        new_generation = self.st().get("tokenGeneration")
        self.assertNotEqual(new_generation, old_generation)
        # the late DeleteItem of the old sign-out finally runs
        self.ss._events[0].set()
        self.assertTrue(self.ss.zombie_done.wait(5))
        self.assertEqual(self.ss.deleted, ["legacy", old_generation, old_generation],
                         "publication retries pending deletion; the late delete is still addressed")
        self.assertEqual(vault.read(), (new, "secret-service"))
        self.st().update(gistId=env.GIST, discoveredAt=time.time())
        self.mark_pushed()
        self.gh.calls.clear()
        self.gh.on("GET", "/gists/g1", self.ok_gist())
        res = self.cycle()
        self.assertTrue(res.ok, res.error)
        self.assertEqual(self.gh.calls[0].auth, "Bearer " + new)


class TestLegacy(env.SyncEnv):
    # Scenario 7
    def test_legacy_keyring_item_without_generation(self):
        self.ss.items["legacy"] = self.token
        self.st().update(login="me", gistId=env.GIST, discoveredAt=time.time())    # 0.3.1 state
        self.assertFalse(self.st().has("tokenGeneration"))
        self.assertEqual(vault.read(), (self.token, "secret-service"))
        self.mark_pushed()
        self.gh.on("GET", "/gists/g1", self.ok_gist())
        res = self.cycle()
        self.assertTrue(res.ok, res.error)
        self.assertEqual(self.gh.calls[0].auth, "Bearer " + self.token)

    def test_legacy_file_without_generation(self):
        vault._ss = lambda: None                     # no Secret Service at all
        common.ensure_dirs()
        with open(common.TOKEN_FILE_PATH, "w") as f:
            f.write(self.token + "\n")               # one line: pre-generation format
        self.st().update(login="me")
        self.assertEqual(vault.read(), (self.token, "file"))
        self.st().update(tokenBackend="file")        # legacy state that knows its backend
        self.assertEqual(vault.read(), (self.token, "file"))

    def test_real_secret_service_class_filters_generations(self):
        """vault._SecretService over a fake D-Bus: SearchItems matches attribute SUBSETS, so the
        legacy lookup must drop items that carry any generation; delete touches one generation."""
        new, old = env.make_token(), self.token
        bus = FakeBus({"/i/legacy": dict(vault.ATTRS), "/i/g1": dict(vault.ATTRS, generation="g1"),
                       "/i/g2": dict(vault.ATTRS, generation="g2")},
                      {"/i/legacy": old, "/i/g1": new, "/i/g2": env.make_token()})
        ss = object.__new__(vault._SecretService)
        ss.dbus, ss.bus, ss.service, ss.session = FakeDbusModule, bus, bus.service, "/s/1"
        self.assertEqual(ss.get("legacy"), old)
        self.assertEqual(ss.get("g1"), new)
        self.assertIsNone(ss.get("g3"))
        self.assertTrue(ss.delete("legacy"))
        self.assertEqual(sorted(bus.items), ["/i/g1", "/i/g2"], "legacy delete spares new generations")
        self.assertTrue(ss.delete("g1"))
        self.assertEqual(sorted(bus.items), ["/i/g2"])
        self.assertIsNone(ss.get("legacy"))

    def test_explicit_empty_generation_disables_reads(self):
        self.ss.items["legacy"] = self.token
        self.st().update(login="me", tokenGeneration="")
        self.assertEqual(vault.read(), (None, None))


class FakeDbusModule(object):
    """The few python-dbus names _SecretService uses."""
    @staticmethod
    def Array(values, signature=None):
        return list(values)

    @staticmethod
    def Interface(obj, iface):
        return obj


class FakeBus(object):
    def __init__(self, attrs, secrets_):
        self.items = dict(attrs)
        self.secrets = dict(secrets_)
        bus = self

        class Service(object):
            def SearchItems(self, attrs):
                hits = [p for p, a in bus.items.items() if all(a.get(k) == v for k, v in attrs.items())]
                return hits, []

            def Unlock(self, paths):
                return list(paths), "/"
        self.service = Service()

    def get_object(self, name, path):
        bus = self

        class Item(object):
            def Get(self, iface, prop):
                return bus.items[path]

            def GetSecret(self, session):
                return (session, b"", bus.secrets[path].encode("utf-8"), "text/plain")

            def Delete(self):
                bus.items.pop(path, None)
                return "/"
        return Item()


class TestHonestLogout(env.SyncEnv):
    # Scenario 8
    def test_logout_when_keyring_hangs_then_retry_cleans_up(self):
        generation, backend = self.sign_in()
        self.ss.hang_delete = self.ss.event()
        self.ss.zombie_effective = False             # the hung call never completes
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = cli.main(["logout"])
        self.assertEqual(rc, 1)
        self.assertIn("Выход не завершён", out.getvalue())
        st = self.st()
        self.assertIsNone(st.get("login"))
        self.assertIs(st.get("revoked"), True)
        self.assertEqual(st.get("tokenGeneration"), "")
        self.assertEqual(st.get("tokenDeletePending"), [[generation, backend]])
        self.assertIn("Выход не завершён", st.get("lastError"))
        self.assertIn(generation, self.ss.items, "token still stored — and the user was told so")
        self.assertEqual(vault.read(), (None, None), "the retained token is never used")
        # keyring unlocked: a second sign-out finishes the job
        self.ss.hang_delete = None
        self.assertTrue(sync.logout())
        st = self.st()
        self.assertIsNone(st.get("tokenDeletePending"))
        self.assertIsNone(st.get("lastError"))
        self.assertNotIn(generation, self.ss.items)


if __name__ == "__main__":
    unittest.main()
