"""REMOTE-LIMITS A4 — debt of A2/A3 (docs/plans.md §A4 «Долг A3 → A4», «Из ревью A2»). Test-plan IDs A4-09…A4-15.
Sources: docs/security-remote-limits-a3-t2-r3.md (N7, N8, §4 A4-x/A4-y), docs/review-remote-limits-a3-r3.md (P2, n3),
docs/review-remote-limits-a3-r2.md (R2-n2, R2-n3), docs/security-remote-limits-a3-t2-r2.md (N4, §5 A3-46),
docs/review-remote-limits-a2.md / T2 A2 (N8: updater max_body and the intermediate 302 body).
Not here (already in test_rl_publisher_fixes3.py): N5, P1, N6/n2, n1.
Written BEFORE the fix (red): every test fails on a missing behaviour, never on its harness. GUARD = green on purpose.

IDs:
  A4-09 N7/N8(A2)  updater (`update.check`, `update.fetch_deb`): a 302 with a 1 MiB body is not read (≤ 64 KiB taken from
                   the socket in total) and its `http://` target is not followed; a direct 200 still works (GUARD).
  A4-10 N8-test    shared loopback-only guard `tests/_net_guard.py` for tests that run a fresh copy of ccl/common.py:
                   a non-loopback connect/resolve raises `ForeignConnect` (BaseException) through `common.http`, and is
                   recorded for cleanup. Mutation check inside: the old AssertionError guard IS swallowed (Resp(0)).
                   Test infrastructure (tester's zone) — green by construction.
  A4-11 n3         `_HTTPDeadlineStream.fileno()` delegates to the wrapped stream.
  A4-12 P2         PATCH answered 2xx with an echo cut short of Content-Length: `common.http` → status 0 with
                   `original_status` = 2xx; `sync.gh` PATCH treats it as a confirmed write (GET stays an error);
                   publisher: PATCH №1 confirmed → no rollback, the provider is asked in the same tick.
  A4-13 N4         PATCH №1 succeeded on the network but the local `sync-state.json` write failed (ENOSPC) → the
                   announced attempt is not rolled back: the provider is asked in the same tick, no `publish_failed`.
                   (Closes the A3-46 reservation of T2-r2 §5; the strict variant of its acceptance.)
  A4-14 R2-n2      the session reopen inside one pass does not get a new 60 s read budget: a GET of the reopened
                   session has timeout ≤ what is left of the pass budget (60 s from the start of the first read).
  A4-15 R2-n3      `sync.write` on a busy `sync` lock → `write_error = "busy"`, `lastError`/`lastErrorAt` untouched.
  A4-19 minor      (fix cycle 1, docs/review-remote-limits-a4.md) `attemptPending` does not hang: (a) the identity
                   changes after PATCH №1 and before the request (branch `continue` of _poll_products) → the bucket of
                   the reserved account is not left pending; (b) an interrupted attempt of a product then held by
                   `token_policy` for several ticks → not pending once it is not polled. In both, the next successful
                   plain heartbeat breaks the series (`_publishFailures` 2 → 0), as A3-51 (P1).

Contract chosen by the tester where the sources are silent:
  * Updater redirects: a handler of its own (as `_GistRawRedirect`): 3xx body closed unread, bounded hops, target only
    `https://` on an allow-list. The allow-list applies to redirect TARGETS; the first URL is the module constant
    (tests point it at a loopback server, so the first hop must not be filtered by scheme/host).
  * P2: the error text of the truncated echo is free (tests take it from a real exchange with the fresh copy of
    common.py); only `status == 0`, `original_status == 200` and a non-empty `error` are fixed.
  * R2-n2: the whole pass shares one read budget (e.g. `run_pass` inside `sync._read_budget()`); time is
    `time.monotonic` (faked here, shares the wall clock).
Run: cd linux && python3 -m unittest tests.test_rl_a4_debt -v
"""

if __package__:
    from . import _rl_env as rl
    from . import _net_guard
    from .test_rl_install import A4Env
    from .test_rl_publisher_fixes3 import KillBase, PS
else:
    import _rl_env as rl
    import _net_guard
    from test_rl_install import A4Env
    from test_rl_publisher_fixes3 import KillBase, PS

import errno
import json
import os
import socket
import threading
import time
import unittest
from unittest import mock

from ccl import common, limits, sync, update

NOW = rl.NOW
KiB, MiB = 1024, 1024 * 1024


def tearDownModule():
    rl.assert_real_files_untouched()


def PS():
    return os.path.join(common.STATE_DIR, "publisher-state.json")


# ==== loopback HTTP server ============================================================================================
class Server(object):
    """Tiny HTTP/1.1 server on 127.0.0.1; `routes[path](conn)` writes the raw answer. Records request paths.
    A client that hangs up early (broken pipe/reset) is expected, not a harness error."""

    def __init__(self, routes):
        self.routes, self.paths, self.errors = routes, [], []
        self.srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.srv.bind(("127.0.0.1", 0))
        self.srv.listen(4)
        self.srv.settimeout(0.05)
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self._loop, daemon=True)
        self.thread.start()

    def url(self, path):
        return "http://127.0.0.1:%d%s" % (self.srv.getsockname()[1], path)

    def _loop(self):
        while not self.stop.is_set():
            try:
                c, _ = self.srv.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            try:
                c.settimeout(3)
                buf = b""
                while b"\r\n\r\n" not in buf:
                    got = c.recv(65536)
                    if not got:
                        break
                    buf += got
                head, _, rest = buf.partition(b"\r\n\r\n")
                lines = head.split(b"\r\n")
                path = lines[0].split(b" ")[1].decode() if lines and len(lines[0].split(b" ")) > 1 else "?"
                cl = 0
                for ln in lines[1:]:
                    if ln.lower().startswith(b"content-length:"):
                        cl = int(ln.split(b":")[1])
                while len(rest) < cl:
                    got = c.recv(65536)
                    if not got:
                        break
                    rest += got
                self.paths.append(path)
                route = self.routes.get(path)
                if route is None:
                    c.sendall(b"HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                else:
                    route(c)
            except (BrokenPipeError, ConnectionResetError, socket.timeout):
                pass
            except Exception as e:
                self.errors.append(repr(e))
            finally:
                c.close()

    def close(self):
        self.stop.set()
        self.srv.close()
        self.thread.join(1)


def answer(status, body, headers=b""):
    def route(c):
        c.sendall(b"HTTP/1.1 %s\r\nContent-Length: %d\r\nConnection: close\r\n%s\r\n" % (status, len(body), headers)
                  + body)
    return route


def truncated(status=b"200 OK", declared=1000, sent=b'{"id":"g1","fi'):
    def route(c):
        c.sendall(b"HTTP/1.1 %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n"
                  % (status, declared) + sent)
    return route


class WireCounter(object):
    """Client-side bytes taken from sockets (the server writes with sendall, not SocketIO)."""

    def __init__(self, testcase):
        self.total = 0
        real = socket.SocketIO.readinto
        counter = self

        def readinto(sio, b):
            n = real(sio, b)
            counter.total += n or 0
            return n
        p = mock.patch.object(socket.SocketIO, "readinto", readinto)
        p.start()
        testcase.addCleanup(p.stop)


class HttpCase(rl.RLEnv):
    """RLEnv sandbox + a fresh copy of common.py under the shared loopback-only guard (A4-10)."""

    def setUp(self):
        super().setUp()
        self.probe = _net_guard.fresh_common(self)
        self.servers = []

    def tearDown(self):
        for s in self.servers:
            s.close()
            self.assertEqual(s.errors, [], "ошибка самого стенда (сервер)")
        super().tearDown()

    def serve(self, routes):
        s = Server(routes)
        self.servers.append(s)
        return s


# ==== A4-09 (N7 + N8 of A2): updater redirects ========================================================================
class TestA409UpdaterRedirect(HttpCase):
    VERSION = b'"""x"""\nAPP_VERSION = "99.0"\n'

    def redirecting(self):
        holder = {}

        def big_302(c):
            body = b"x" * MiB
            c.sendall(b"HTTP/1.1 302 Found\r\nLocation: %s\r\nContent-Type: text/html\r\nContent-Length: %d\r\n"
                      b"Connection: close\r\n\r\n" % (holder["srv"].url("/b").encode(), len(body)))
            for i in range(0, len(body), 64 * KiB):
                c.sendall(body[i:i + 64 * KiB])
        srv = holder["srv"] = self.serve({"/a": big_302, "/b": answer(b"200 OK", self.VERSION),
                                          "/ok": answer(b"200 OK", self.VERSION)})
        return srv

    def test_check_302_body_unread_http_target_refused(self):
        srv = self.redirecting()
        wire = WireCounter(self)
        with mock.patch.object(update, "VERSION_URL", srv.url("/a")), mock.patch.object(common, "http", self.probe.http):
            latest, err = update.check()
        self.assertLessEqual(wire.total, 64 * KiB, "тело 302 не читается: с провода взято %d байт" % wire.total)
        self.assertEqual(srv.paths, ["/a"], "цель редиректа http:// не запрашивается (только https из белого списка)")
        self.assertIsNone(latest, "редирект на http:// не даёт версию")

    def test_fetch_deb_302_body_unread_http_target_refused(self):
        srv = self.redirecting()
        common.state().update(updateAvailable="99.0", updateDebUrl=srv.url("/a"))
        wire = WireCounter(self)
        with mock.patch.object(common, "http", self.probe.http), \
                mock.patch.object(update, "download_dir", return_value=self.tmp):
            with self.assertRaises(RuntimeError):
                update.fetch_deb()
        self.assertLessEqual(wire.total, 64 * KiB, "тело 302 не читается: с провода взято %d байт" % wire.total)
        self.assertEqual(srv.paths, ["/a"], "цель редиректа http:// не запрашивается")

    def test_direct_200_still_works(self):
        """GUARD: the stand is live and a plain answer is accepted."""
        srv = self.serve({"/ok": answer(b"200 OK", self.VERSION)})
        with mock.patch.object(update, "VERSION_URL", srv.url("/ok")), mock.patch.object(common, "http", self.probe.http):
            latest, err = update.check()
        self.assertEqual((latest, err), ("99.0", None))
        self.assertEqual(srv.paths, ["/ok"])


# ==== A4-10 (N8-test): the shared guard cannot be swallowed ===========================================================
class TestA410SharedNetGuard(HttpCase):
    FOREIGN = "http://192.0.2.1:9/x"          # TEST-NET-1: never routed; the guard stops it before connect

    def test_foreign_connect_escapes_common_http(self):
        with self.assertRaises(_net_guard.ForeignConnect):
            self.probe.http(self.FOREIGN, timeout=2)
        self.assertEqual(len(self.net_guard.take()), 1)

    def test_foreign_name_is_not_resolved(self):
        with self.assertRaises(_net_guard.ForeignConnect):
            self.probe.http("http://example.invalid/x", timeout=2)
        self.assertIn([w for w, _ in self.net_guard.take()], (["getaddrinfo"], ["create_connection"]),
                      "имя не резолвится: остановлено до DNS")

    def test_mutation_old_guard_is_swallowed_but_recorded(self):
        """Mutation: an AssertionError guard (the old `_no_socket` style) is swallowed by `except Exception` in
        common.http — the caller only sees Resp(0). The record still catches it in cleanup."""
        weak = _net_guard.install(self, exc=AssertionError)
        r = self.probe.http(self.FOREIGN, timeout=2)
        self.assertEqual(r.status, 0, "старый сторож поглощён common.http → «сеть недоступна»")
        self.assertEqual(len(weak.take()), 1, "попытка записана, хотя исключение поглощено")

    def test_loopback_allowed(self):
        srv = self.serve({"/x": answer(b"200 OK", b"{}")})
        r = self.probe.http(srv.url("/x"), timeout=5)
        self.assertEqual((r.status, r.data), (200, b"{}"))

    def test_guard_is_not_an_exception(self):
        self.assertFalse(issubclass(_net_guard.ForeignConnect, Exception))


# ==== A4-11 (n3) ======================================================================================================
class TestA411DeadlineStreamFileno(unittest.TestCase):
    def test_fileno_delegates(self):
        a, b = socket.socketpair()
        self.addCleanup(a.close)
        self.addCleanup(b.close)
        source = a.makefile("rb")
        self.addCleanup(source.close)
        stream = common._HTTPDeadlineStream(source, None)
        try:
            got = stream.fileno()
        except (OSError, ValueError) as e:      # io.UnsupportedOperation is both
            self.fail("_HTTPDeadlineStream.fileno() не делегирует: %s" % type(e).__name__)
        self.assertEqual(got, source.fileno())


# ==== A4-12 (P2): a confirmed PATCH with a truncated echo =============================================================
class TestA412TruncatedEcho(HttpCase):
    def exchange(self, method):
        srv = self.serve({"/gists/g1": truncated()})
        return self.probe.http(srv.url("/gists/g1"), method, {"Content-Type": "application/json"},
                               {"files": {}} if method == "PATCH" else None, timeout=5,
                               follow_redirects=False, max_body=16 * MiB)

    def test_http_keeps_original_status(self):
        r = self.exchange("PATCH")
        self.assertEqual(r.status, 0, "оборванное тело — не 200")
        self.assertTrue(isinstance(r.error, str) and r.error)
        self.assertEqual(r.original_status, 200, "статус ответа сохраняется (как у BODY_TOO_LARGE)")

    def test_gh_patch_confirmed_get_still_error(self):
        patch_resp, get_resp = self.exchange("PATCH"), self.exchange("GET")
        replies = {"PATCH": patch_resp, "GET": get_resp}
        sync.transport = lambda url, method, headers, body, timeout: replies[method]
        r = sync.gh("/gists/g1", "fixture-token", "PATCH", {"files": {}})
        self.assertTrue(200 <= r.status < 300, "PATCH 2xx с оборванным эхом — запись подтверждена (status %r)" % r.status)
        r = sync.gh("/gists/g1", "fixture-token", "GET")
        self.assertEqual(r.status, 0, "GET с оборванным телом остаётся ошибкой")


class PassCase(A4Env):
    def one_tick_poll_expected(self, why):
        res = self.tick()
        calls = self.providers.calls("claude")
        self.assertEqual(len(calls), 1, "%s: объявленная попытка не откатывается — запрос в том же тике "
                         "(запросов: %d, пропуски: %r)" % (why, len(calls), [e.get("reason") for e in self.skipped(
                             "publish_failed")]))
        self.assertEqual(self.skipped("publish_failed"), [])
        saved = common.read_json(PS(), {}) or {}
        self.assertIn(saved.get("_publishFailures"), (0, None), "PATCH №1 подтверждён — серия неудач обнулена")
        return res


class TestA412PublisherTruncatedEcho(PassCase):
    def test_patch1_confirmed_by_status_no_rollback(self):
        # loopback-only guard above PubEnv's blanket socket ban (patches stack; cleanup restores in order)
        probe = _net_guard.fresh_common(self, name="ccl_common_fresh_a4_p2")
        srv = Server({"/gists/g1": truncated()})
        self.addCleanup(srv.close)
        echo = probe.http(srv.url("/gists/g1"), "PATCH", {}, {"files": {}}, timeout=5, follow_redirects=False,
                          max_body=16 * MiB)
        self.assertEqual(srv.errors, [])
        gist = self.gist

        def accepted_but_cut(rec):
            for name, f in ((rec.body or {}).get("files") or {}).items():
                if isinstance(f, dict) and isinstance(f.get("content"), str):
                    gist.revs.setdefault(name, []).append((rec.t, rec.reader, f["content"]))
            return echo
        self.gist.patch_script = [accepted_but_cut]
        self.one_tick_poll_expected("P2: PATCH №1 2xx, эхо оборвано")


# ==== A4-13 (N4): PATCH ok, local fingerprint write failed ============================================================
class TestA413LocalWriteAfterPatch(PassCase):
    def test_patch1_ok_sync_state_enospc_no_rollback(self):
        ledger = self.ledger

        def fail_local_after(rec):
            ledger.fail_paths["sync-state.json"] = OSError(errno.ENOSPC, "No space left on device")
            return None                          # the gist applies the PATCH and answers 200
        self.gist.patch_script = [fail_local_after]
        self.providers.on_call = lambda product: ledger.fail_paths.pop("sync-state.json", None)
        self.one_tick_poll_expected("N4: PATCH №1 прошёл, sync-state.json не записался")
        self.assertTrue(self.bodies(), "PATCH №1 дошёл до gist")


# ==== A4-14 (R2-n2): reopen shares the pass read budget ===============================================================
class TestA414ReopenBudget(A4Env):
    def test_reopened_get_gets_only_the_rest_of_the_budget(self):
        clock, gets, phase, opens = self.clock, [], {"reopen": False}, []
        inner = sync.transport

        def transport(url, method, headers, body, timeout):
            if method == "GET" and phase["reopen"]:
                gets.append((url, timeout))
            return inner(url, method, headers, body, timeout)
        sync.transport = transport

        def slow_first_get(rec):
            clock.advance(50)                    # the first read of the pass takes 50 s (wall and monotonic)
            return None
        self.gist.get_script = [slow_first_get]
        real_open = sync.open_cycle

        def open_cycle(*a, **kw):
            session = real_open(*a, **kw)
            opens.append(session is not None)
            if len(opens) == 1:
                self.wall_only(125)              # the session is now stale for write() → the publisher reopens
                phase["reopen"] = True
            return session
        self.patch(sync, "open_cycle", open_cycle)
        self.tick()
        self.assertGreaterEqual(len(opens), 2, "предусловие: проход переоткрыл сессию (stale)")
        self.assertTrue(gets, "переоткрытая сессия читает gist (бюджет ещё не исчерпан)")
        for url, timeout in gets:
            self.assertLessEqual(timeout, 60 - 50 + 0.5, "переоткрытие получило новый бюджет: GET %s с timeout %r "
                                 "(осталось ≤ 10 с из общих 60)" % (url, timeout))


# ==== A4-15 (R2-n3) ===================================================================================================
class TestA415BusyIsNotAnError(A4Env):
    def test_busy_write_keeps_last_error(self):
        session = sync.open_cycle(auto=True)
        self.assertIsNotNone(session, "предусловие: сессия открыта")
        st = sync.sync_state()
        st.reload()
        before = (st.get("lastError"), st.get("lastErrorAt"))
        self.hold("sync")
        ok = sync.write(session, json.dumps({"schema": 1}))
        self.assertFalse(ok)
        self.assertEqual(session.write_error, "busy")
        st.reload()
        self.assertEqual((st.get("lastError"), st.get("lastErrorAt")), before,
                         "занятый sync — пропуск, не ошибка (протокол): lastError не пишется")



# ==== A4-19 (red, fix cycle 1): attemptPending does not hang ==========================================================
I19 = 1800


class TestA419AttemptPendingNotStuck(KillBase):
    def setUp(self):
        super().setUp()
        self.point = None

    def bucket(self, local_id=rl.U_A):
        ps = common.read_json(PS(), {}) or {}
        return (((ps.get("claude") or {}).get("accounts") or {}).get(local_id)) or {}

    def heartbeat_tick(self, at):
        """A tick that is not locally due for Claude; ≥ 600 s since the last write → plain heartbeat PATCH."""
        self.clock.now = self.t0 = at
        self.calls0 = len(self.call_times)
        ok0, n = self.ok_patches, len(self.claude_calls())
        self.killed_tick()
        self.assertGreater(self.ok_patches, ok0, "стенд: в тике %+d с был успешный heartbeat" % (at - rl.NOW))
        self.assertEqual(len(self.claude_calls()), n, "стенд: тик без запроса к провайдеру")

    def test_identity_changed_before_request(self):
        self.first_pass()
        t1 = rl.NOW + I19
        switched = []

        def hook(rec):
            if not switched and self.attempt_patch(rec):
                self.write_claude_json(rl.U_B)          # CLI sign-in changes while PATCH №1 is in flight
                switched.append(True)
            return None
        self.clock.now = self.t0 = t1
        n = len(self.claude_calls())
        self.gist.patch_script[:] = [hook] * 8
        self.killed_tick()
        self.gist.patch_script[:] = []
        self.write_claude_json(rl.U_A)                  # … and back: the reserved account is current again
        self.assertTrue(switched, "стенд: смена identity во время PATCH №1 не сработала")
        self.assertIn("identity_changed", [e.get("ev") for e in self.o1()], "стенд: ветка «identity сменилась»")
        self.assertEqual(len(self.claude_calls()), n, "стенд: запроса к провайдеру в этом тике не было")
        self.assertIsNot(self.bucket().get("attemptPending"), True,
                         "ветка «identity сменилась до запроса» оставила attemptPending=true (запроса не было — "
                         "попытка не висит): %r" % {k: self.bucket().get(k) for k in ("attemptPending", "attemptPublished")})
        self.seed_counter(2)
        self.heartbeat_tick(t1 + 660)
        self.assertEqual(self.counter(), 0, "успешный heartbeat после ветки identity обрывает серию (P1); "
                                            "attemptPending=%r" % self.bucket().get("attemptPending"))

    def test_long_token_policy_block(self):
        self.first_pass()
        t1 = rl.NOW + I19
        self.clock.now = self.t0 = t1
        self.calls0 = len(self.call_times)
        self.providers.kill_after = True                # killed with the provider request in flight
        self.killed_tick()
        self.assertEqual(len(self.claude_calls()), 2, "стенд: запрос был и убит")
        self.assertIs(self.bucket().get("attemptPending"), True, "стенд: прерванная попытка висит после убийства")
        self.patch(limits, "claude_token_policy_blocks", lambda now: True)   # spent token, policy never: long block
        self.heartbeat_tick(t1 + 660)                   # echo of the interrupted attempt (does not break the series)
        self.assertTrue(self.skipped("token_policy", "claude"), "стенд: пропуск token_policy")
        self.seed_counter(2)
        self.heartbeat_tick(t1 + 1320)                  # Claude still blocked: a plain heartbeat
        self.assertIsNot(self.bucket().get("attemptPending"), True,
                         "продукт под долгим token_policy не опрашивается, а attemptPending висит")
        self.assertEqual(self.counter(), 0, "успешный heartbeat при долгом token_policy обрывает серию (P1)")

if __name__ == "__main__":
    unittest.main()
