"""REMOTE-LIMITS — first fix of A4 = closing condition of A3 (docs/plans.md §A4 «Первым в A4»). Test-plan IDs A3-49…A3-51.
Sources: docs/security-remote-limits-a3-t2-r3.md (N5, N6, §4), docs/review-remote-limits-a3-r3.md (P1), lesson
.patches/015-kill-mid-pass-durable-counters.md (kill the pass at EVERY blocking point, not at one).
Written BEFORE the fix (red): every red test fails on a missing behaviour, never on its own harness (each kill hook
checks that it fired). Tests marked GUARD are green now on purpose: they pin what the fix must keep.

Blocking points of publisher.run_pass (code at 4fe990e, linux/ccl/publisher.py), in pass order:
  get              sync.open_cycle of the first session (:278) — GET /gists/{id} + raw reads (≤ 60 s, DNS unbounded)
  reserve          _save of the reservation (:330) — state.json mirror, then publisher-state.json
  patch1           PATCH №1 of the first session, the record with the new attemptAt (:335 → sync.write)
  reopen           session reopen after a stale/busy PATCH №1 (:347 → :278 sync.open_cycle again)
  patch1_reopened  PATCH №1 of the reopened session (:335 inside the recursive pass)
  provider         limits.fetch_* request (:388)
  state_write      _save of the provider result (:411)
  patch2           PATCH №2 — result announcement / heartbeat (:421)
  flush_pending    limits.flush_pending() (:464, finally, still under quota)
  provider_first   (two products, fix cycle 2 of A4) the request of the FIRST product of a pass, killed on EVERY pass
                   → the other product is still requested (C1) — A4-22 in test_rl_a4_fix2.py (this harness is
                   Claude-only); provider after a slow first request / slow PATCH №1 → the attempt is journalled at the
                   moment of each provider call (N1) — A4-21 there.
Not points: file_lock("quota", 30 s) and usage.refresh() precede every durable step of the pass (a kill there is a tick
that did not happen, nothing to journal); the identity-change _save (:382) and the _save after PATCH №2 (:428) are local
writes after the last network step of their branch (a kill there leaves `attemptPublished=False` → the next tick echoes).

IDs:
  A3-49 N5  kill at each point on EVERY tick, 2 days, ticks 300 s, I = 1800:
            points before a confirmed publication (get, patch1, reopen, patch1_reopened): first request ≤ NOW + 2·I + 600
            (3rd due tick), then ≥ 1 request per 3 due ticks (gap ≤ 3·I + 600, hence ≤ max(I, 24 h)); `_publishFailures`
            on disk ≥ 1 after the first killed due tick and never decreases except in a tick with a confirmed (200) PATCH;
            reserve: the pass never requests without a durable reservation (state.json/publisher-state.json attempt ≥ tick
            start at the moment of the request — the invariant holds at every point), the counter never decreases, one
            killed tick → the next tick polls;
            points after a confirmed PATCH №1 (provider, state_write, patch2, flush_pending), `_publishFailures=2` on disk
            before: 0 on disk after the first due tick (reset right after the confirmed success), a request every due tick;
            counter ≥ 3 or now − last_attempt ≥ max(I, 24 h) → the request is made BEFORE the blocking PATCH №1 (and before
            the GET, see choices).
  A3-50 N6  header deadline of a default call (no `deadline=`) does not include DNS/connect: DNS 1.2 s (or connect 1.2 s)
            + answer after 1.0 s with timeout 2 → POST /oauth/token accepted; GitHub refresh (`sync._form_result`, timeout
            15) with DNS 9 s + answer 9 s → accepted. GUARD: fast DNS control; the header phase is still bounded
            (DNS 1.2 + answer 2.5 at timeout 2 → not 200); an explicit sync `deadline=` still includes DNS (DNS 40 +
            answer 25 under the 60 s read budget → not 200).
  A3-51 P1  2 confirmed publish_failed ticks → a tick with a successful heartbeat (skip fresh_remote) → 1 failed tick:
            no fallback request, counter on disk 1; a kill during the provider request after a confirmed PATCH №1 keeps
            the reset (0 on disk).

Contract choices made by the tester where the sources are silent:
  - Point `get` (Yurka's brief lists it): a pass killed in the first GET on every tick must still poll ≥ 1 per 3 due ticks.
    That requires the +1 of the series to be journalled before the GET when a product is locally due, and the
    «counter ≥ 3» fallback request to be made before the GET (like an unavailable gist) — wider than fix (a) of T2-r3.
  - Point `patch1` kills exactly what T2-r3 P5g killed: PATCH №1 with the new attemptAt and no fresh asOf. The next tick's
    late echo of that interrupted attempt succeeds; per T2-r3 §4 (counter 1 → 2 → 3) such an echo does NOT break the
    series, while a plain heartbeat (A3-51, no pending attempt) does.
  - Point `reserve` cannot satisfy «≥ 1 request per 3 ticks» when killed on every tick: no request may precede a durable
    reservation (publisher.py:89–91). Expectation for it: the invariant + counter monotonic + recovery after one kill.
  - Times are virtual (FakeClock, injected monotonic); no real sleep > 0.1 s.
Run: cd linux && python3 -m unittest tests.test_rl_publisher_fixes3 -v
"""

if __package__:
    from . import _rl_env as rl
    from . import test_rl_publisher_fixes as fx
    from . import test_rl_publisher_fixes2 as fx2
else:
    import _rl_env as rl
    import test_rl_publisher_fixes as fx
    import test_rl_publisher_fixes2 as fx2

import json
import os
import socket
import unittest
from types import SimpleNamespace
from unittest import mock

from ccl import common, limits, sync

NOW = rl.NOW
DAY = 86400
I = 1800
TICK = 300
SLACK = 600
TOKEN = fx2.TOKEN


def tearDownModule():
    rl.assert_real_files_untouched()


def PS():
    return os.path.join(common.STATE_DIR, "publisher-state.json")


def _num(v):
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) else None


# ==================================================================================================================
# A3-49 / A3-51 — the publisher in the offline PubEnv sandbox (virtual clock, FakeGist, Kill = SIGKILL, fresh process
# per tick).
# ==================================================================================================================

class KillBase(fx2.PubBase):
    def setUp(self):
        super().setUp()
        self.follow_monotonic()
        # Kill is simulated at the granularity of a whole write_atomic call; fsync only costs wall time here
        # (≈ 10 000 fsyncs per 2-day series).
        self.patch(os, "fsync", lambda fd: None)
        self.t0 = NOW
        self.killed_this = False
        self.kill_info = []
        self.calls0 = 0
        self.ok_patches = 0
        self.violations = []
        self.opens = self.merges = 0
        gist = sync.transport

        def transport(url, method, headers, body, timeout):
            r = gist(url, method, headers, body, timeout)
            if method == "PATCH" and getattr(r, "status", 0) == 200:
                self.ok_patches += 1
            return r
        sync.transport = transport                       # SyncEnv.tearDown restores the original
        fetch = limits.fetch_claude

        self.call_times = []

        def fetch_claude():
            # Recorded, not asserted: the pass swallows ordinary exceptions of the provider.
            if not self.ledger.dead:
                self.call_times.append(self.clock.now)    # = the ledger «provider» event (logged before kill_after)
                if self.reserved_on_disk() < self.t0:
                    self.violations.append(self.clock.now)
                if getattr(self, "point", None) == "provider":
                    self.die("provider")                # killed while the request is in flight
            return fetch()
        self.patch(limits, "fetch_claude", fetch_claude)

    # ---- disk observations ----
    def counter(self):
        v = self.failures_on_disk()
        return v if type(v) is int else 0

    def seed_counter(self, n):
        saved = common.read_json(PS(), {})
        saved = saved if isinstance(saved, dict) else {}
        saved["_publishFailures"] = n
        common.write_json(PS(), saved)

    def reserved_on_disk(self):
        st = common.read_json(common.STATE_PATH, {}) or {}
        a = _num(((st.get("autoPollState") or {}).get("claude") or {}).get("last_attempt"))
        ps = common.read_json(PS(), {}) or {}
        b = _num((((ps.get("claude") or {}).get("accounts") or {}).get(self.CLAUDE_ID) or {}).get("attemptAt"))
        return max(x for x in (a, b, 0.0) if x is not None)

    def provider_this_tick(self):
        return len(self.call_times) > self.calls0

    # ---- the kill ----
    def die(self, where):
        self.killed_this = True
        self.kill_info.append(SimpleNamespace(t0=self.t0, where=where, opens=self.opens))
        self.ledger.dead = True
        raise rl.Kill()

    def attempt_patch(self, rec):
        """PATCH carrying this tick's new attemptAt without a fresh asOf (T2-r3 P5g)."""
        f = ((rec.body or {}).get("files") or {}).get(self.my_file())
        body = json.loads(f["content"]) if isinstance(f, dict) and isinstance(f.get("content"), str) else {}
        r = self.record(body, self.label()) or {}
        at, asof = fx.ts(r.get("attemptAt")), fx.ts(r.get("asOf"))
        return at is not None and at >= self.t0 and (asof is None or asof < self.t0)

    def arm(self, point):
        self.point = point
        if point == "get":
            real = sync.open_cycle

            def open_cycle(*a, **kw):
                self.opens += 1
                if self.opens == 1:
                    self.die("get")
                return real(*a, **kw)
            self.patch(sync, "open_cycle", open_cycle)
        elif point == "reopen":
            self.slow_merge()
            real = sync.open_cycle

            def open_cycle(*a, **kw):
                self.opens += 1
                if self.opens == 2:
                    self.die("reopen")
                return real(*a, **kw)
            self.patch(sync, "open_cycle", open_cycle)
        elif point in ("patch1", "patch1_reopened"):
            if point == "patch1_reopened":
                self.slow_merge(first_only=True)
            real = sync.open_cycle

            def open_cycle(*a, **kw):
                self.opens += 1
                return real(*a, **kw)
            self.patch(sync, "open_cycle", open_cycle)
        elif point in ("reserve", "state_write"):
            real = common.write_atomic

            def write_atomic(path, data, mode=0o600):
                name = os.path.basename(path)
                if name in rl.STATE_FILES and not self.killed_this and not self.ledger.dead:
                    if point == "state_write" and self.provider_this_tick():
                        self.die("state_write")
                    if point == "reserve" and self.once_ok() and not self.provider_this_tick() \
                            and self.carries_reservation(name, data):
                        self.die("reserve")
                return real(path, data, mode)
            self.patch(common, "write_atomic", write_atomic)
        elif point == "flush_pending":
            real = limits.flush_pending

            def flush_pending(*a, **kw):
                if not self.ledger.dead:
                    self.die("flush_pending")
                return real(*a, **kw)
            self.patch(limits, "flush_pending", flush_pending)
        self.kill_once = None

    def once_ok(self):
        return self.kill_once is None or self.kill_once == self.t0

    def carries_reservation(self, name, data):
        try:
            obj = json.loads(data if isinstance(data, str) else bytes(data).decode("utf-8"))
        except ValueError:
            return False
        if name == "state.json":
            v = ((obj.get("autoPollState") or {}).get("claude") or {}).get("last_attempt")
        else:
            v = (((obj.get("claude") or {}).get("accounts") or {}).get(self.CLAUDE_ID) or {}).get("attemptAt")
        return _num(v) is not None and v >= self.t0

    def patch_hook(self, rec):
        if self.ledger.dead:
            raise rl.Kill()
        if self.point in ("patch1", "patch1_reopened") and self.attempt_patch(rec):
            self.die(self.point)
        if self.point == "patch2" and self.provider_this_tick():
            self.die("patch2")
        if self.point == "any_patch":
            self.die("any_patch")
        return None

    def one_tick(self, at):
        self.clock.now = self.t0 = at
        self.killed_this = False
        self.calls0 = len(self.call_times)
        before, ok0 = self.counter(), self.ok_patches
        if self.point in ("patch1", "patch1_reopened", "patch2", "any_patch"):
            self.gist.patch_script[:] = [self.patch_hook] * 8
        self.killed_tick()
        self.gist.patch_script[:] = []
        return SimpleNamespace(t0=at, before=before, after=self.counter(), confirmed=self.ok_patches > ok0,
                               killed=self.killed_this, polled=self.provider_this_tick())

    def series(self, point, days=2, seed=None):
        self.arm(point)
        if seed is not None:
            self.seed_counter(seed)
        rows, at, end = [], NOW, NOW + days * DAY
        while at <= end:
            rows.append(self.one_tick(at))
            at = max(at + TICK, self.clock.now)
        self.end = end
        return rows

    # ---- shared assertions ----
    def assert_fired(self, rows):
        self.assertTrue(any(r.killed for r in rows), "стенд: точка убийства %r ни разу не сработала" % self.point)

    def assert_reservation_invariant(self):
        self.assertEqual(self.violations, [], "запрос к провайдеру без резерва на диске (attempt ≥ начала тика): %r"
                         % self.violations[:3])

    def assert_monotonic(self, rows):
        bad = [(r.t0 - NOW, r.before, r.after) for r in rows if r.after < r.before and not r.confirmed]
        self.assertEqual(bad, [], "счётчик серии на диске уменьшился без подтверждённого PATCH (t−NOW, до, после): %r"
                         % bad[:5])

    def assert_polls_every_third_due_tick(self, rows):
        calls = list(self.call_times)
        series = [r.after for r in rows[:8]]
        self.assertTrue(calls, "точка %s на каждом тике, 2 суток: 0 запросов (N5); _publishFailures по тикам: %r"
                        % (self.point, series))
        self.assertLessEqual(calls[0], NOW + 2 * I + SLACK,
                             "первый запрос не позже 3-го due-тика серии; _publishFailures: %r" % series)
        gaps = [b - a for a, b in zip(calls, calls[1:])] + [self.end - calls[-1]]
        self.assertLessEqual(max(gaps), 3 * I + SLACK,
                             "≥ 1 запрос на каждые 3 due-тика (зазор ≤ 3·I + 600, а значит ≤ max(I, 24 ч)): max %.0f с, "
                             "всего %d запросов" % (max(gaps), len(calls)))


# ==== A3-49 (N5): points before a confirmed publication — the series is journalled before the blocking step ==========
class TestA349SeriesBeforePublication(KillBase):
    def check(self, point):
        rows = self.series(point)
        self.assert_fired(rows)
        self.assert_reservation_invariant()
        first_due = rows[0]
        self.assertGreaterEqual(first_due.after, 1, "после 1-го убитого due-тика (точка %s) +1 серии не на диске: "
                                "журнал-до-действия (урок 015); _publishFailures: %r"
                                % (point, [r.after for r in rows[:6]]))
        self.assert_monotonic(rows)
        self.assert_polls_every_third_due_tick(rows)
        return rows

    def test_get(self):
        self.check("get")

    def test_patch1_first_session(self):
        self.check("patch1")

    def test_reopen(self):  # GUARD (A3-43, N1 closed): must stay green
        self.check("reopen")
        self.assertTrue(any(k.opens == 2 for k in self.kill_info), "стенд: убито именно переоткрытие")

    def test_patch1_of_reopened_session(self):  # GUARD (A3-43): must stay green
        self.check("patch1_reopened")
        self.assertTrue(any(k.opens == 2 for k in self.kill_info), "стенд: убит PATCH №1 переоткрытой сессии")


# ==== A3-49 (N5): the reservation write — no request without it =======================================================
class TestA349ReservationWrite(KillBase):
    def test_every_tick(self):  # GUARD
        rows = self.series("reserve")
        self.assert_fired(rows)
        self.assert_reservation_invariant()
        self.assert_monotonic(rows)

    def test_one_kill_then_next_tick_polls(self):  # GUARD
        self.arm("reserve")
        self.kill_once = NOW
        r0 = self.one_tick(NOW)
        self.assertTrue(r0.killed, "стенд: запись резерва убита")
        r1 = self.one_tick(NOW + TICK)
        self.assertTrue(r1.polled, "после одного убитого резерва следующий тик опрашивает")
        self.assert_reservation_invariant()


# ==== A3-49 (N5) + P1: points after a confirmed PATCH №1 — the reset is durable at once =============================
class TestA349AfterConfirmedPublication(KillBase):
    def check(self, point):
        rows = self.series(point, days=1, seed=2)          # every due tick polls: one day shows it
        self.assert_fired(rows)
        self.assert_reservation_invariant()
        self.assertTrue(rows[0].confirmed and rows[0].polled, "предусловие: PATCH №1 подтверждён, запрос был")
        self.assertEqual(rows[0].after, 0, "точка %s после подтверждённого PATCH №1: на диске _publishFailures=%r, "
                         "сброс серии потерян (P1; сбрасывать сразу после успеха)" % (point, rows[0].after))
        self.assert_monotonic(rows)
        calls = list(self.call_times)
        gaps = [b - a for a, b in zip(calls, calls[1:])] + [self.end - calls[-1]]
        self.assertLessEqual(max(gaps), I + SLACK, "запрос на каждом due-тике (зазор ≤ I + 600)")

    def test_provider(self):
        self.check("provider")

    def test_state_write(self):
        self.check("state_write")

    def test_patch2(self):  # GUARD
        self.check("patch2")

    def test_flush_pending(self):  # GUARD
        self.check("flush_pending")


# ==== A3-49 (N5 fix b): fallback decided before the blocking publication ==============================================
class TestA349FallbackBeforePublication(KillBase):
    def due_tick_killed(self, point):
        self.arm(point)
        mark = self.ledger.mark()
        row = self.one_tick(self.clock.now)
        self.assertTrue(row.killed, "стенд: проход убит в точке %s" % point)
        ev = self.ledger.since(mark)
        calls = [e for e in ev if e.kind == "provider" and e.product == "claude"]
        return ev, calls

    def test_counter_3_polls_before_patch1(self):
        self.first_pass()
        self.seed_counter(3)
        self.clock.advance(I)
        ev, calls = self.due_tick_killed("any_patch")
        self.assertEqual(len(calls), 1, "_publishFailures=3 на диске, PATCH №1 зависает: запрос до блокирующей "
                                        "публикации (N5 б)")
        patches = [e for e in ev if e.kind == "PATCH"]
        self.assertTrue(not patches or calls[0].seq < patches[0].seq, "запрос раньше PATCH №1")
        self.assert_reservation_invariant()

    def test_24h_branch_polls_before_patch1(self):
        self.first_pass()
        self.clock.now = NOW + DAY + 1                       # now − last_attempt ≥ max(I, 24 h)
        ev, calls = self.due_tick_killed("any_patch")
        self.assertEqual(len(calls), 1, "ветка «≥ max(I, 24 ч)»: запрос до блокирующего PATCH №1 первой сессии (N5 б)")
        self.assert_reservation_invariant()

    def test_counter_3_polls_before_get(self):
        self.first_pass()
        self.seed_counter(3)
        self.clock.advance(I)
        _ev, calls = self.due_tick_killed("get")
        self.assertEqual(len(calls), 1, "_publishFailures=3, первый GET зависает: запрос по своему расписанию до GET "
                                        "(как при недоступном gist; выбор tester-а, см. шапку)")
        self.assert_reservation_invariant()


# ==== A3-51 (P1): a successful heartbeat breaks the series ===========================================================
class TestA351HeartbeatBreaksSeries(KillBase):
    def setUp(self):
        super().setUp()
        self.point = None

    def failed_tick(self, at):
        self.clock.now = self.t0 = at
        self.calls0 = len(self.call_times)
        self.gist.patch_script[:] = [common.Resp(500)] * 4
        self.killed_tick()
        self.gist.patch_script[:] = []

    def test_two_failures_heartbeat_one_failure_no_fallback(self):
        self.first_pass()
        t = NOW + I
        self.failed_tick(t)
        self.failed_tick(t + TICK)
        self.assertEqual(self.counter(), 2, "предусловие: 2 тика publish_failed подряд")
        self.assertEqual(len(self.claude_calls()), 1, "предусловие: без запросов")
        # Tick 3: a neighbour has a fresh reading → skip fresh_remote, heartbeat PATCH succeeds.
        t3 = t + 2 * TICK
        self.clock.now = self.t0 = t3
        self.foreign("m-peer", [self.foreign_record(asOf=rl.iso(t3))])
        ok0 = self.ok_patches
        self.killed_tick()
        self.assertGreater(self.ok_patches, ok0, "предусловие: успешный heartbeat в 3-м тике")
        self.assertEqual(len(self.claude_calls()), 1, "предусловие: 3-й тик пропущен (fresh_remote)")
        # Tick 4: the neighbour is gone, the announcement fails once.
        self.foreign("m-peer", [])
        self.failed_tick(t3 + TICK)
        self.assertEqual(len(self.claude_calls()), 1, "2 неудачи → успешный heartbeat → 1 неудача: запасного опроса нет, "
                         "серия оборвана (P1, sync-protocol «3rd consecutive»)")
        self.assertEqual(self.counter(), 1, "серия после heartbeat начинается заново")

    def test_kill_during_provider_keeps_reset(self):
        self.first_pass()
        self.seed_counter(2)
        self.clock.advance(I)
        self.clock.now = self.t0 = self.clock.now
        self.calls0 = len(self.call_times)
        self.providers.kill_after = True
        self.killed_tick()
        self.assertEqual(len(self.claude_calls()), 2, "предусловие: запрос был (и убит)")
        self.assertEqual(self.counter(), 0, "PATCH №1 подтверждён, проход убит во время запроса к провайдеру: "
                                            "сброс серии на диске потерян (P1)")


# ==================================================================================================================
# A3-50 (N6) — real common.http (private copy) against a loopback server, injected monotonic clock; DNS/connect «take»
# virtual seconds, no real sleeps.
# ==================================================================================================================

class TestA350HeaderDeadline(fx2.HttpBase):
    def slow(self, dns=0.0, connect=0.0):
        mono = self.mono
        real_gai = socket.getaddrinfo
        real_connect = socket.socket.connect

        def slow_gai(*a, **kw):
            mono.advance(dns)
            return real_gai(*a, **kw)

        def slow_connect(sock, address):
            mono.advance(connect)
            return real_connect(sock, address)
        for owner, name, value in ((socket, "getaddrinfo", slow_gai), (socket.socket, "connect", slow_connect)):
            p = mock.patch.object(owner, name, value)
            p.start()
            self.addCleanup(p.stop)

    def answer_after(self, seconds, body=TOKEN):
        """The server «thinks» `seconds` (virtual) after the full request, then sends the whole response."""
        mono = self.mono

        def handler(c):
            mono.advance(seconds)
            c.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\n"
                      b"Connection: close\r\n\r\n%s" % (len(body), body))
        return self.serve(handler)

    def token_post(self, srv, timeout=2):
        # limits.py token refresh call shape: POST JSON, no redirects, provider body cap.
        return self.mod.http(srv.url("/oauth/token"), "POST", {"Content-Type": "application/json"},
                             {"grant_type": "refresh_token", "refresh_token": "fixture-rt"}, timeout=timeout,
                             follow_redirects=False, max_body=limits.PROVIDER_MAX_BODY)

    def test_slow_dns_oauth_post_accepted(self):
        srv = self.answer_after(1.0)
        self.slow(dns=1.2)
        r = self.token_post(srv)
        self.assertEqual((r.status, r.error), (200, None), "DNS 1,2 с + ответ через 1,0 с при timeout 2: срок заголовков "
                         "включает DNS, ответ /oauth/token потерян — одноразовый refresh истрачен (N6)")
        self.assertEqual(json.loads(r.data)["access_token"], "fixture-at")

    def test_slow_connect_oauth_post_accepted(self):
        srv = self.answer_after(1.0)
        self.slow(connect=1.2)
        r = self.token_post(srv)
        self.assertEqual((r.status, r.error), (200, None), "connect 1,2 с + ответ через 1,0 с при timeout 2: срок "
                         "заголовков включает установку соединения (N6)")

    def test_slow_dns_github_refresh_accepted(self):
        srv = self.answer_after(9.0)
        self.slow(dns=9.0)
        fields = {"grant_type": "refresh_token", "refresh_token": "fixture-rt", "client_id": "fixture-client"}
        with mock.patch.object(common, "http", self.mod.http), \
                mock.patch.object(sync, "transport",
                                  lambda url, m, h, b, t: sync._transport(srv.url("/login/oauth/access_token"),
                                                                          m, h, b, t)):
            status, body, _h = sync._form_result(sync.auth.REFRESH_URL, fields)
        self.assertEqual(status, 200, "refresh GitHub (timeout 15): DNS 9 с + ответ через 9 с потерян (N6, VPS)")
        self.assertEqual((body or {}).get("access_token"), "fixture-at")

    def test_fast_dns_control(self):  # GUARD
        srv = self.answer_after(1.0)
        self.slow()
        self.assertEqual(self.token_post(srv).status, 200)

    def test_header_phase_still_bounded(self):  # GUARD: the fix must not drop the header bound
        srv = self.answer_after(2.5)
        self.slow(dns=1.2)
        self.assertNotEqual(self.token_post(srv).status, 200, "заголовки через 2,5 с после отправки при timeout 2")

    def test_explicit_sync_deadline_still_includes_dns(self):  # GUARD: «явный срок sync оставить как есть»
        srv = self.answer_after(25.0, body=b"{}")
        self.slow(dns=40.0)
        with mock.patch.object(common, "http", self.mod.http):
            with sync._read_budget():
                r = sync._transport(srv.url(), "GET", {"User-Agent": "t"}, None, sync._read_timeout(30))
        self.assertNotEqual(r.status, 200, "чтение sync под сроком 60 с: DNS 40 с + ответ 25 с — за сроком")


if __name__ == "__main__":
    unittest.main(verbosity=2)
