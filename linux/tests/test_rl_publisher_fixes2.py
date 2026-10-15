"""REMOTE-LIMITS A3 — fix cycle 2, the last one (docs/plans.md §A3 «Цикл правок A3 №2»). Test-plan IDs A3-43…A3-48.
Sources: docs/security-remote-limits-a3-t2-r2.md (N1–N3, §5 A3-43…A3-45), docs/review-remote-limits-a3-r2.md (R2-m1,
R2-m1b, R2-m2, R2-n1). Written BEFORE the fix (red): every test fails on a missing behaviour, never on its own harness.
Tests marked GUARD are green now on purpose: they pin what the fix must keep.

IDs:
  A3-43 N1   publish_failed series and the «now − last_attempt ≥ max(I, 24 h)» branch are decided BEFORE the session
             reopen: a pass killed in the middle of the reopen (open_cycle or PATCH №1 of the reopened session) still
             grows `_publishFailures` on disk and the 3rd failed tick polls; the 24 h branch polls in the same tick;
             the 1xx (`100 Continue`) phase is bounded by time (default call: `timeout`; sync read: read deadline).
  A3-44 N2/R2-m1  the shared body deadline only for sync reads (explicit `deadline=`, here: the sync read budget);
             OAuth token POST, GitHub refresh (inside or outside the read budget) and updater downloads keep the
             per-operation timeout: a slow but alive body longer than `timeout` is read successfully.
  A3-45 N3/R2-m2  malformed `_rollback` marker → the pass does not fail, the marker is removed, an O1 event is written,
             the due product is polled in the same tick.
  A3-46 reserved for N4 (T2 §5; debt of A4, not in this cycle).
  A3-47 R2-m1b  a body cut short of its Content-Length with max_body=None → error, never 200.
  A3-48 R2-n1  `never` + empty accessToken / no expiresAt → `poll_skipped token_policy`, no provider call.

Contract choices made by the tester where the sources are silent:
  - Time in common.http is measured with `time.monotonic` of the module (injectable; the local server moves a fake
    monotonic clock, real sleeps ≤ 0.01 s). A watchdog on real time would not satisfy these tests.
  - The body/1xx clock jumps happen only after the client has asked for body bytes (socket-level gate), so a bounded
    header phase never sees a jump meant for the body.
  - The sync read deadline is the existing `sync._read_budget()` (60 s); how it reaches `common.http` (`deadline=`) is
    not fixed by the tests. GitHub refresh POST inside the read budget keeps the per-operation semantics (T2 N2: a lost
    one-time refresh token is the harm).
  - N1 «24 h» branch: when the decision is fallback, the pass polls WITHOUT reopening (like an unavailable gist), so a
    kill of the reopen cannot take the request away; same for the 3rd tick of the series.
  - N3 O1 event name (not in O1_EVENTS yet): proposed `rollback_invalid`; the test accepts any event whose name
    contains "rollback". Non-dict `_rollback` values (5, "x", []) are malformed too and are removed.
  - N3 valid form: `{"saved": dict, "autoPollState": dict|None, "quotaServerRetryAt": dict|None}`, all three keys.
Run: cd linux && python3 -m unittest tests.test_rl_publisher_fixes2 -v
"""

if __package__:
    from . import _rl_env as rl
    from . import test_rl_publisher_fixes as fx
else:
    import _rl_env as rl
    import test_rl_publisher_fixes as fx

import importlib.util
import json
import os
import socket
import tempfile
import threading
import time
import unittest
from unittest import mock

from ccl import common, limits, sync, update

NOW = rl.NOW
DAY = 86400
I = 1800
MiB = 1024 * 1024
TOKEN = b'{"access_token":"fixture-at","refresh_token":"fixture-rt","expires_in":3600,"token_type":"bearer"}'


def tearDownModule():
    rl.assert_real_files_untouched()


def PS():
    return os.path.join(common.STATE_DIR, "publisher-state.json")


# ==================================================================================================================
# Part 1 — real common.http (a private copy: _isolate replaced the module's http with a guard) against a loopback
# server, with an injected monotonic clock.
# ==================================================================================================================

class FakeMono(object):
    def __init__(self):
        self.now = 1000.0
        self.lock = threading.Lock()

    def advance(self, s):
        with self.lock:
            self.now += s


class TimeProxy(object):
    """The `time` module with an injected monotonic clock (everything else is the real module)."""
    def __init__(self, mono):
        self._mono = mono

    def monotonic(self):
        return self._mono.now

    def __getattr__(self, name):
        return getattr(time, name)


class Gate(object):
    """Client-side socket gate: `body_wanted` is set when the client asks for bytes after the full header block.
    The server moves the fake clock only after that, so the jump is seen by the body phase only."""
    def __init__(self):
        self.header_len = 0
        self.total = 0
        self.body_wanted = threading.Event()


class LoopServer(object):
    def __init__(self, handler):
        self.handler = handler
        self.errors = []
        self.srv = socket.socket()
        self.srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.srv.bind(("127.0.0.1", 0))
        self.srv.listen(4)
        self.srv.settimeout(0.05)
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self._loop, daemon=True)
        self.thread.start()

    @property
    def port(self):
        return self.srv.getsockname()[1]

    def url(self, path="/x"):
        return "http://127.0.0.1:%d%s" % (self.port, path)

    def _loop(self):
        while not self.stop.is_set():
            try:
                c, _ = self.srv.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            try:
                c.settimeout(5)
                buf = b""
                while b"\r\n\r\n" not in buf:
                    got = c.recv(65536)
                    if not got:
                        break
                    buf += got
                head, _, rest = buf.partition(b"\r\n\r\n")
                cl = 0
                for ln in head.split(b"\r\n"):
                    if ln.lower().startswith(b"content-length:"):
                        cl = int(ln.split(b":")[1])
                while len(rest) < cl:
                    got = c.recv(65536)
                    if not got:
                        break
                    rest += got
                self.handler(c)
            except OSError:
                pass                          # the client gave up (deadline) — expected in bounded cases
            except Exception as e:            # harness bug: surface it
                self.errors.append(repr(e))
            finally:
                c.close()

    def close(self):
        self.stop.set()
        self.srv.close()
        self.thread.join(2)


class HttpBase(unittest.TestCase):
    def setUp(self):
        path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "ccl", "common.py")
        spec = importlib.util.spec_from_file_location("ccl_common_http_copy_fix2", path)
        self.mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.mod)
        self.mono = FakeMono()
        for owner in (self.mod, sync):
            p = mock.patch.object(owner, "time", TimeProxy(self.mono))
            p.start()
            self.addCleanup(p.stop)
        env = {"no_proxy": "*", "NO_PROXY": "*"}
        p = mock.patch.dict(os.environ, env)
        p.start()
        self.addCleanup(p.stop)
        for k in ("http_proxy", "HTTP_PROXY", "https_proxy", "HTTPS_PROXY"):
            if k in os.environ:
                v = os.environ.pop(k)
                self.addCleanup(os.environ.__setitem__, k, v)
        self.gate = Gate()
        real = socket.SocketIO.readinto
        gate = self.gate

        def readinto(sio, b):
            if gate.header_len and gate.total >= gate.header_len:
                gate.body_wanted.set()
            n = real(sio, b)
            gate.total += n or 0
            return n
        p = mock.patch.object(socket.SocketIO, "readinto", readinto)
        p.start()
        self.addCleanup(p.stop)
        self.servers = []

    def tearDown(self):
        for s in self.servers:
            s.close()
            self.assertEqual(s.errors, [], "ошибка самого стенда (сервер)")

    def serve(self, handler):
        s = LoopServer(handler)
        self.servers.append(s)
        return s

    # ---- scenarios ----
    def late_body(self, body, late, status=200, chunks=1, ctype=b"application/json"):
        """Headers at once; after the client asks for the body the fake clock jumps `late` seconds (spread over
        `chunks` pieces), then the body arrives. Every socket operation is fast; only the total exceeds `timeout`."""
        head = (b"HTTP/1.1 %d X\r\nContent-Type: %s\r\nContent-Length: %d\r\nConnection: close\r\n\r\n"
                % (status, ctype, len(body)))
        gate = self.gate
        mono = self.mono
        size = -(-len(body) // chunks)

        def handler(c):
            gate.header_len = len(head)
            c.sendall(head)
            if not gate.body_wanted.wait(5):
                raise AssertionError("клиент не запросил тело")
            for i in range(0, len(body), size):
                mono.advance(late / chunks)
                c.sendall(body[i:i + size])
        return self.serve(handler)

    def continue_flood(self, step=1.0, count=200):
        """Endless-looking `100 Continue` phase: each interim response «takes» `step` seconds of the fake clock."""
        mono = self.mono

        def handler(c):
            for _ in range(count):
                mono.advance(step)
                c.sendall(b"HTTP/1.1 100 Continue\r\n\r\n")
                time.sleep(0.005)
            c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}")
        return self.serve(handler)


# ==== A3-43 (N1): the 1xx phase is bounded ===========================================================================
class TestA343ContinueBounded(HttpBase):
    def test_default_call_1xx_flood_bounded_by_timeout(self):
        srv = self.continue_flood()
        t0 = self.mono.now
        r = self.mod.http(srv.url(), "POST", {"Content-Type": "application/json"}, {"a": 1}, timeout=15,
                          follow_redirects=False, max_body=65536)
        elapsed = self.mono.now - t0
        self.assertNotEqual(r.status, 200, "фаза 100 Continue без конца не ограничена сроком (ответ пришёл через %.0f с "
                                           "при timeout 15)" % elapsed)
        self.assertLessEqual(elapsed, 15 + 2, "фаза 1xx обрывается по сроку timeout")

    def test_sync_read_1xx_flood_bounded_by_read_deadline(self):
        srv = self.continue_flood()
        with mock.patch.object(common, "http", self.mod.http):
            t0 = self.mono.now
            with sync._read_budget():
                r = sync._transport(srv.url(), "GET", {"User-Agent": "t"}, None, sync._read_timeout(30))
            elapsed = self.mono.now - t0
        self.assertNotEqual(r.status, 200, "чтение sync: фаза 1xx не ограничена (%.0f с)" % elapsed)
        self.assertLessEqual(elapsed, 30 + 2, "≤ одного таймаута чтения (30 с) и ≤ срока чтения 60 с")


# ==== A3-44 (N2/R2-m1): shared body deadline only for sync reads =====================================================
class TestA344DefaultSemantics(HttpBase):
    def test_oauth_token_post_slow_body_is_accepted(self):
        # limits.py:367 / :789 call shape: POST JSON, follow_redirects=False, max_body=PROVIDER_MAX_BODY, timeout 15.
        srv = self.late_body(TOKEN, late=20)
        r = self.mod.http(srv.url("/oauth/token"), "POST", {"Content-Type": "application/json"},
                          {"grant_type": "refresh_token", "refresh_token": "fixture-rt"},
                          follow_redirects=False, max_body=limits.PROVIDER_MAX_BODY)
        self.assertEqual((r.status, r.error), (200, None),
                         "ответ /oauth/token с живым, но медленным телом (> timeout от начала) потерян: "
                         "одноразовый refresh-токен истрачен (N2)")
        self.assertEqual(json.loads(r.data)["access_token"], "fixture-at")

    def test_github_refresh_slow_body_is_accepted(self):
        srv = self.late_body(TOKEN, late=20)
        fields = {"grant_type": "refresh_token", "refresh_token": "fixture-rt", "client_id": "fixture-client"}
        with mock.patch.object(common, "http", self.mod.http), \
                mock.patch.object(sync, "transport",
                                  lambda url, m, h, b, t: sync._transport(srv.url("/login/oauth/access_token"),
                                                                          m, h, b, t)):
            for budget in (False, True):
                with self.subTest(inside_read_budget=budget):
                    self.gate.body_wanted.clear()
                    self.gate.total = 0
                    self.gate.header_len = 0
                    if budget:
                        with sync._read_budget():
                            status, body, _h = sync._form_result(sync.auth.REFRESH_URL, fields)
                    else:
                        status, body, _h = sync._form_result(sync.auth.REFRESH_URL, fields)
                    self.assertEqual(status, 200, "refresh GitHub (VPS-издатель): медленное живое тело потеряно (N2)")
                    self.assertEqual((body or {}).get("access_token"), "fixture-at")

    def test_updater_8mib_at_50kib_s_is_not_cut_at_120s(self):
        body = b"!<arch>\ndebian-binary   " + b"\0" * (8 * MiB - 24)
        srv = self.late_body(body, late=len(body) / (50 * 1024), chunks=128, ctype=b"application/octet-stream")
        out = tempfile.mkdtemp(prefix="ccl-fix2-deb-")
        self.addCleanup(lambda: __import__("shutil").rmtree(out, ignore_errors=True))
        st = common.state()
        st.update(updateAvailable="999.0.0", updateDebUrl=srv.url("/pkg_all.deb"))
        self.addCleanup(lambda: common.state().update(updateAvailable=None, updateDebUrl=None))
        with mock.patch.object(common, "http", self.mod.http), mock.patch.object(update, "download_dir", lambda: out):
            try:
                ver, path = update.fetch_deb()
            except RuntimeError as e:
                self.fail("загрузка .deb 8 МиБ на 50 КиБ/с (≈ 164 с) оборвана общим сроком 120 с: %s (R2-m1)" % e)
        self.assertEqual(ver, "999.0.0")
        self.assertEqual(os.path.getsize(path), len(body))


class TestA344SyncReadDeadlineGuard(HttpBase):
    def test_sync_raw_read_still_bounded_by_60s(self):  # GUARD: green now, must stay green after the fix
        srv = self.late_body(b'{"x":1}', late=61)
        with mock.patch.object(common, "http", self.mod.http):
            with sync._read_budget():
                r = sync._transport(srv.url(), "GET", {"User-Agent": "t"}, None, sync._read_timeout(30))
        self.assertNotEqual(r.status, 200, "чтение sync по-прежнему ограничено общим сроком (≤ 60 с)")
        self.assertIn(r.error, (common.HTTP_DEADLINE, sync._READ_TIMEOUT))


# ==== A3-47 (R2-m1b): a truncated Content-Length body is an error, not 200 ===========================================
class TestA347TruncatedBody(HttpBase):
    def test_content_length_5_body_2_then_eof(self):
        def handler(c):
            c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\n{}")
        srv = self.serve(handler)
        for max_body in (None, 65536):
            with self.subTest(max_body=max_body):
                r = self.mod.http(srv.url(), timeout=15, max_body=max_body)
                self.assertNotEqual(r.status, 200, "оборванное тело (2 из 5 байт) принято как 200 (R2-m1b)")
                self.assertTrue(r.error, "ошибка транспорта видна")


# ==================================================================================================================
# Part 2 — the publisher in the offline PubEnv sandbox (virtual clock, FakeGist, Kill = SIGKILL).
# ==================================================================================================================

class PubBase(fx.Base):
    def failures_on_disk(self):
        saved = common.read_json(PS(), {})
        return saved.get("_publishFailures") if isinstance(saved, dict) else None

    def slow_merge(self, first_only=False):
        """Every (or the first per tick) merge «takes» 130 s → the session is stale at PATCH №1 → reopen."""
        real = sync.merge
        self.merges = 0

        def merge(*a, **kw):
            self.merges += 1
            if not first_only or self.merges == 1:
                self.clock.advance(130)
            return real(*a, **kw)
        self.patch(sync, "merge", merge)

    def kill_on_reopen(self):
        """SIGKILL while the reopened session reads (2nd open_cycle of a tick)."""
        real = sync.open_cycle
        self.opens = 0

        def open_cycle(*a, **kw):
            self.opens += 1
            if self.opens == 2:
                self.ledger.dead = True
                raise rl.Kill()
            return real(*a, **kw)
        self.patch(sync, "open_cycle", open_cycle)

    def killed_tick(self):
        """One pass in a fresh process; killed passes end like SIGKILL (the ledger is revived for the next one)."""
        self.opens = self.merges = 0
        t0 = self.clock.now
        self.tick()
        self.restart()
        return t0

    def run_ticks(self, until, every=300):
        at = self.clock.now
        while at <= until:
            self.clock.now = at
            self.killed_tick()
            at = max(at + every, self.clock.now)


# ==== A3-43 (N1): a kill in the middle of the reopen does not reset the series ======================================
class TestA343KillDuringReopen(PubBase):
    def test_series_grows_and_third_tick_polls(self):
        self.follow_monotonic()
        self.slow_merge()
        self.kill_on_reopen()
        counts = []
        polled_at = None
        at = self.clock.now
        for n in range(1, 4):
            self.clock.now = at
            self.killed_tick()
            counts.append(self.failures_on_disk())
            if polled_at is None and self.claude_calls():
                polled_at = n
            at = max(at + 300, self.clock.now)
        self.assertIsInstance(counts[0], int, "после 1-го убитого тика серия publish_failed не на диске: %r" % counts)
        self.assertGreaterEqual(counts[0], 1, counts)
        self.assertIsInstance(counts[1], int, counts)
        self.assertGreater(counts[1], counts[0], "серия растёт с каждым убитым тиком: %r" % counts)
        self.assertIsNotNone(polled_at, "обрыв посреди переоткрытия на каждом тике: опроса нет (N1, P5f), "
                                        "_publishFailures на диске: %r" % counts)
        self.assertLessEqual(polled_at, 3, "3-й тик серии опрашивает сам")

    def test_two_days_of_killed_reopens_keep_polling(self):
        self.follow_monotonic()
        self.slow_merge()
        self.kill_on_reopen()
        self.run_ticks(NOW + DAY)
        calls = [e.t for e in self.claude_calls()]
        self.assertTrue(calls, "сутки убитых переоткрытий: 0 запросов (N1)")
        self.assertLessEqual(calls[0], NOW + 3 * (300 + 130 + 60), "первый запрос не позже 3-го тика")
        gaps = [b - a for a, b in zip(calls, calls[1:])]
        self.assertTrue(gaps and max(gaps) <= I + 600, "дальше интервалы ≤ I + тик + проход: %r" % gaps[:8])

    def test_24h_branch_decided_before_the_reopen(self):
        self.follow_monotonic()
        self.first_pass()
        self.slow_merge()
        self.kill_on_reopen()
        self.clock.now = NOW + DAY + 1                       # now − last_attempt ≥ max(I, 24 h)
        self.killed_tick()
        self.assertEqual(len(self.claude_calls()), 2,
                         "ветка «≥ max(I, 24 ч) с последней попытки» срабатывает до переоткрытия: опрос в том же тике, "
                         "убитое переоткрытие запрос не отнимает (N1)")


class TestA343KillDuringReopenedPatch(PubBase):
    def test_kill_on_patch1_of_reopened_session(self):
        """First read of each tick is slow (stale → reopen); the reopened session's PATCH №1 carrying the new
        attemptAt is killed. Before the fix: a conservative attempt without a request every I, forever."""
        self.follow_monotonic()
        self.slow_merge(first_only=True)
        lab = self.label()
        mine = self.my_file()
        tick = {"t0": None}

        def kill_attempt_patch(rec):
            f = ((rec.body or {}).get("files") or {}).get(mine)
            body = json.loads(f["content"]) if isinstance(f, dict) and isinstance(f.get("content"), str) else {}
            r = self.record(body, lab) or {}
            at = fx.ts(r.get("attemptAt"))
            asof = fx.ts(r.get("asOf"))
            if at is not None and at >= tick["t0"] and (asof is None or asof < tick["t0"]):
                self.ledger.dead = True
                raise rl.Kill()
            return None
        counts = []
        at = self.clock.now
        while at <= NOW + 4 * I:
            self.clock.now = tick["t0"] = at
            self.gist.patch_script[:] = [kill_attempt_patch] * 4
            n_patch = len(self.ledger.of("PATCH"))
            self.killed_tick()
            self.gist.patch_script[:] = []
            if len(self.ledger.of("PATCH")) > n_patch or self.claude_calls():
                counts.append(self.failures_on_disk())
            if self.claude_calls():
                break
            at = max(at + 300, self.clock.now)
        calls = [e.t for e in self.claude_calls()]
        self.assertTrue(calls, "PATCH №1 переоткрытой сессии убит на каждом due-тике: опроса нет за 4·I "
                               "(_publishFailures по due-тикам: %r)" % counts)
        self.assertLessEqual(calls[0], NOW + 2 * I + 600, "запрос не позже 3-го due-тика: %r" % counts)


# ==== A3-45 (N3/R2-m2): malformed `_rollback` marker =================================================================
class TestA345MalformedRollback(PubBase):
    SHAPES = {
        "empty": {},
        "saved_only": {"saved": {}},
        "saved_int": {"saved": 5, "autoPollState": {}, "quotaServerRetryAt": {}},
        "saved_list": {"saved": [], "autoPollState": [], "quotaServerRetryAt": "x"},
        "auto_list": {"autoPollState": []},
        "mirrors_garbage": {"saved": {}, "autoPollState": "x", "quotaServerRetryAt": 5},
        "not_dict_int": 5,
        "not_dict_str": "x",
        "not_dict_list": [],
    }

    def check(self, value, kind="auto"):
        self.first_pass()
        saved = common.read_json(PS(), {})
        saved["_rollback"] = value
        common.write_json(PS(), saved)
        self.clock.advance(I)
        n = len(self.o1())
        self.tick(kind)
        new = self.o1()[n:]
        failed = [e for e in new if e.get("ev") == "pass_failed"]
        self.assertEqual(failed, [], "битый маркер _rollback роняет проход: %r" % failed)
        after = common.read_json(PS(), {})
        self.assertIsInstance(after, dict)
        self.assertNotIn("_rollback", after, "битый маркер снят с диска")
        self.assertTrue([e for e in new if "rollback" in str(e.get("ev"))],
                        "событие O1 о снятом маркере (предложено имя rollback_invalid): %r"
                        % sorted({e.get("ev") for e in new}))
        self.assertEqual(len(self.claude_calls()), 2, "due-продукт опрошен в этом же тике")
        self.clock.advance(I)
        n = len(self.o1())
        self.tick()
        self.assertEqual([e for e in self.o1()[n:] if e.get("ev") == "pass_failed"], [], "следующий тик тоже цел")
        self.assertEqual(len(self.claude_calls()), 3, "следующий due-тик опрашивает")

    def test_manual_push_survives_empty_marker(self):
        self.check({}, kind="manual")


def _shape_test(value):
    def test(self):
        self.check(value)
    return test


for _name, _value in TestA345MalformedRollback.SHAPES.items():
    setattr(TestA345MalformedRollback, "test_marker_" + _name, _shape_test(_value))


# ==== A3-48 (R2-n1): never + empty accessToken / no expiresAt → token_policy ========================================
class TestA348TokenPolicyEdges(PubBase):
    def creds(self, **oauth):
        obj = {"claudeAiOauth": dict({"refreshToken": "fixture-refresh-x", "scopes": ["user:inference"],
                                      "subscriptionType": "max"}, **oauth)}
        self.write_file(common.CLAUDE_CREDENTIALS, json.dumps(obj))

    CASES = {
        "empty_access": dict(accessToken="", expiresAt=int((NOW + 3600) * 1000)),
        "no_access": dict(expiresAt=int((NOW + 3600) * 1000)),
        "no_expires": dict(accessToken="fixture-access-x"),
        "null_expires": dict(accessToken="fixture-access-x", expiresAt=None),
    }

    def test_preflight_blocks(self):
        self.assertEqual(common.credential_write(), "never")
        for name, oauth in self.CASES.items():
            with self.subTest(name):
                self.creds(**oauth)
                self.assertTrue(limits.claude_token_policy_blocks(NOW),
                                "never: истраченный токен (%s) — пропуск token_policy" % name)

    def test_valid_token_not_blocked_control(self):  # GUARD
        self.creds(accessToken="fixture-access-x", expiresAt=int((NOW + 3600) * 1000))
        self.assertFalse(limits.claude_token_policy_blocks(NOW))

    def test_pass_skips_without_begin(self):
        for name, oauth in self.CASES.items():
            with self.subTest(name):
                self.creds(**oauth)
                n, mark = len(self.o1()), self.ledger.mark()
                self.tick()
                self.clock.advance(I)
                self.assertTrue(self.skipped("token_policy", "claude", self.o1()[n:]), "poll_skipped token_policy")
                self.assertEqual(self.claude_calls(), [], "без begin и без вызова провайдера")
                for _e, body in self.bodies(self.ledger.since(mark)):
                    r = self.record(body, self.label())
                    self.assertFalse(r and r.get("attemptAt"), "ложного attemptAt нет в gist: %r" % r)


if __name__ == "__main__":
    unittest.main()
