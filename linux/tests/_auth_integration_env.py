"""Isolated actual sync integration; entry points MUST import _isolate first.

The explicit owner uses the real /tmp manifest, flock, form/user adapters and
sync pipeline. Only credential store, clock and lower HTTP boundary are fakes.
No TrayApp constructor, default auth-owner factory, provider fetch or usage scan.
"""
if __package__:
    from . import _isolate
    from ._auth_env import (AuthWorld, OwnerHarness, Fault, Reply, KnownNotSent,
                            OutcomeUnknown, assert_nonsecret, forbidden)
else:
    import _isolate
    from _auth_env import (AuthWorld, OwnerHarness, Fault, Reply, KnownNotSent,
                           OutcomeUnknown, assert_nonsecret, forbidden)

from contextlib import nullcontext
import json
import os
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import subprocess
from urllib.parse import parse_qs

from ccl import auth, common, limits, sync, usage, vault


class AuthorizedTransport:
    """Exact endpoints, issuer-authorized reads, complete schema-1 machine file.

    Payload marker survives the actual merge -> durable cache pipeline. A login
    string or owner ready result alone can never make this fixture succeed.
    """
    def __init__(self, world):
        self.world = world
        self.marker = 0
        self.user_id = "1001"
        self.fail_read = False
        self.fail_before_send = False
        self.patch_count = 0

    @staticmethod
    def response(reply):
        return common.Resp(reply.status, json.dumps(reply.payload).encode() if reply.payload is not None else None,
                           {str(k).lower(): v for k, v in reply.headers.items()})

    def gist(self):
        day = "2026-10-04"
        remote = dict(schema=1, machine=dict(id="fixture-remote", name="Fixture remote", os="Fixture", app="test"),
                      updated=common.iso_utc(self.world.clock()), tz="UTC",
                      days={"claude": {day: {"fixture-model": dict(input=self.marker, output=0, cacheRead=0,
                                                                  cacheWrite5m=0, cacheWrite1h=0, turns=1)}}})
        return dict(id="fixture-gist", public=False, created_at="2020-01-01T00:00:00Z",
                    files={sync.MANIFEST: {"content": "{}"}, sync.my_file_name(): {"content": "{}"},
                           "machine-fixture-remote.json": {"content": json.dumps(remote)}})

    def __call__(self, url, method, headers, body, timeout):
        if not isinstance(timeout, (int, float)) or not 0 < timeout <= 30:
            raise AssertionError("unbounded fixture transport deadline")
        if url == auth.REFRESH_URL:
            form = {key: values[0] for key, values in parse_qs(body, strict_parsing=True).items()}
            if self.fail_before_send:
                r = common.Resp(0)
                r.definitely_not_sent = True
                self.world.ledger.record("refresh.not_sent")
                return r
            try:
                reply = self.world.issuer.oauth_request(method, url, headers, form, follow_redirects=False)
            except KnownNotSent:
                r = common.Resp(0)
                r.definitely_not_sent = True
                return r
            except OutcomeUnknown:
                return common.Resp(0)
            return self.response(reply)
        if url not in (sync.API + "/user", sync.API + "/gists?per_page=100", sync.API + "/gists/fixture-gist"):
            raise AssertionError("unexpected fixture endpoint")
        bearer = headers.get("Authorization", "")
        if not bearer.startswith("Bearer "):
            raise AssertionError("protected request lacks bearer")
        access = bearer[len("Bearer "):]
        if url.endswith("/user"):
            if method != "GET":
                raise AssertionError("unexpected identity method")
            return self.response(self.world.issuer.user(access))
        if method not in ("GET", "PATCH"):
            raise AssertionError("fixture forbids unexpected gist mutation")
        self.world.ledger.record("pipeline.gist_request", method=method)
        issued = self.world.issuer.authorize(access)
        if issued is None or issued.user_id != self.user_id:
            return self.response(Reply(401, {"message": "fixture unauthorized"}))
        if self.fail_read:
            return self.response(Reply(503, {"message": "fixture unavailable"}))
        self.world.ledger.record("pipeline.gist_authorized", user_id=issued.user_id, marker=self.marker, method=method)
        if method == "PATCH":
            self.patch_count += 1
            assert_nonsecret(body)
        return self.response(Reply(200, [self.gist()] if url == sync.API + "/gists?per_page=100" else self.gist()))


class PipelineCase(unittest.TestCase):
    def patch(self, owner, name, value, **kwargs):
        guard = patch.object(owner, name, value, **kwargs)
        guard.start()
        self.addCleanup(guard.stop)
        return guard

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="ccl-auth-pipeline-", dir="/tmp")
        self.addCleanup(self.tmp.cleanup)
        # Redirect every known path first, before any owner or callback is built.
        original = {name: getattr(common, name) for name in ("CONFIG_DIR", "STATE_DIR")}
        for name, value in list(vars(common).items()):
            if not name.isupper() or not isinstance(value, str):
                continue
            for base, root in original.items():
                if value == root or value.startswith(root + os.sep):
                    target = os.path.join(self.tmp.name, base.lower(), os.path.relpath(value, root))
                    self.patch(common, name, os.path.normpath(target))
                    break
        for name in ("CLAUDE_PROJECTS", "CLAUDE_CREDENTIALS", "CODEX_SESSIONS", "CODEX_AUTH"):
            self.patch(common, name, os.path.join(self.tmp.name, "cli", name.lower()))
        self.patch(common, "_settings", None)
        self.patch(common, "_state", None)
        for module, names in ((common, ("http",)), (sync, ("transport", "auth_owner", "device_start", "device_poll")),
                              (vault, ("_ss", "_ss_v2", "_SecretService", "_file_get", "read", "store", "retire")),
                              (limits, ("fetch_claude", "fetch_codex")),
                              (usage, ("refresh", "load_index", "scan_activity"))):
            for name in names:
                if hasattr(module, name):
                    self.patch(module, name, forbidden)
        self.patch(vault.CredentialStore, "__init__", forbidden)
        self.patch(subprocess, "Popen", forbidden)
        self.patch(subprocess, "run", forbidden)
        def retire_empty(refs):
            if refs:
                raise AssertionError("unexpected legacy credential retirement")
            return True
        self.patch(vault, "retire", retire_empty)
        self.patch(sync, "_first_attempt_at", None)
        self.patch(sync, "REVOKE_RECHECK_DELAY", 0)
        self.patch(sync, "_sleep", forbidden)
        self.patch(sync, "LOGIN_LOCK_TIMEOUT", 0.2)
        self.patch(sync, "_login_current", None)
        self.patch(sync, "_login_counter", 0)
        browser_guard = patch("webbrowser.open", forbidden)
        browser_guard.start()
        self.addCleanup(browser_guard.stop)
        self.world = AuthWorld()
        self.adapter = OwnerHarness(auth, self.world)
        self.http = AuthorizedTransport(self.world)
        self.patch(sync, "transport", self.http)
        # time is a shared Python module: no real-time deadlines are used while
        # fixture clock is frozen; uncontended tmp flock is the only real lock.
        self.patch(sync.time, "time", self.world.clock)
        self.owner = self.make_owner()
        self.patch(sync, "auth_owner", lambda: self.owner)
        common.settings().update(lang="en", advanced=False, monitor_claude=False, monitor_codex=False)
        common.machine_id()
        sync.sync_state().update(tokenGeneration="", tokenDeletePending=None)

    def make_owner(self, legacy=None):
        store = SimpleNamespace(read=self.adapter.read_store, stage_refresh=self.adapter.stage_refresh,
                                delete=self.adapter.delete, write_settled=self.adapter.write_settled,
                                login_backend=lambda: "secret-service")
        def identity(access):
            reply = sync.gh("/user", access)
            return reply.status, reply.json(), reply.headers
        return auth.AuthOwner(auth.LinuxManifest(), store, sync._form_result, identity,
                              lambda: common.file_lock("sync", timeout=0.2), self.world.clock,
                              checkpoint=self.world.checkpoints, jitter=lambda: 0,
                              legacy=lambda: legacy or auth.AuthRead("signedOut"),
                              defer=lambda: nullcontext())

    def login(self, *, user_id="1001", login="fixture-user", legacy=False):
        issued = self.world.issuer.issue(legacy=legacy, user_id=user_id, login=login)
        self.world.ledger.record("device_flow")
        if legacy:
            self.owner = self.make_owner(auth.AuthRead("ready", dict(accessToken=issued.access, login=login,
                                       epoch="fixture-legacy", generation="fixture-legacy", obtainedAt=0),
                                       dict(generation="fixture-legacy", backend="secret-service")))
            sync.sync_state().update(login=login, tokenBackend="secret-service", tokenGeneration="fixture-legacy")
        else:
            # Actual login_finish owns locking, identity and public state projection.
            attempt = sync.begin_login()
            self.assertEqual(sync.login_finish(issued.wire(), attempt=attempt), login)
        self.http.user_id = str(user_id)
        return issued

    def cycle(self, *, allow_push=False):
        self.http.marker += 1
        result = sync.sync_cycle({}, auto=True, allow_push=allow_push)
        self.assertTrue(result.ok, "actual authorized sync failed")
        remote = sync.load_remote()
        self.assertEqual(remote["days"]["claude"]["2026-10-04"]["fixture-model"]["input"], self.http.marker)
        disk = common.read_json(common.SYNC_REMOTE_PATH)
        self.assertEqual(disk["days"], remote["days"])
        self.assertEqual(remote["machines"][0]["id"], "fixture-remote")
        assert_nonsecret(disk)
        assert_nonsecret(common.read_json(common.SYNC_STATE_PATH))
        return result, remote
