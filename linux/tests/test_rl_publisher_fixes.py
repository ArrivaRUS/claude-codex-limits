"""REMOTE-LIMITS A3 — fix cycle 1 (docs/plans.md §A3 «Цикл правок A3 №1»). Test-plan IDs A3-34…A3-42.
Sources: docs/review-remote-limits-a3.md (M1, m1–m5), docs/security-remote-limits-a3-t2.md (S1–S5, §6 A3-34…A3-38).
Written BEFORE the fix (red): every test fails on a missing behaviour, never on its own harness.

IDs (A3-34…A3-38 keep the numbering proposed in T2 §6):
  A3-34 S1  foreign lastSeenAt > now + 60 → record not alive (vectors s1_*; publisher: static +10 y file never delays me).
  A3-35 S2  read phase ≤ 60 s (rest skipped, session partial, PATCH №1 passes); one session reopen when PATCH №1 is
            refused as stale; ≥ 3 publish_failed ticks in a row or now − last_attempt ≥ max(I, 24 h) → own schedule;
            failure visible: `publisher --now` exit ≠ 0, sync-state lastError.
  A3-36 S3  O1 rotation compacts to ≤ 512 KiB (hysteresis: later appends do not rewrite); clock_skew ≤ 1 per pass,
            sync-state.json written for the skew ≤ 1 per pass.
  A3-37 S4/m5  `publisher --now` with publisher != true → refusal, rc ≠ 0; manual `push` on a publisher machine →
            run_pass("manual"), the accounts block survives.
  A3-38 S5  a foreign machine.id outside the id form never lands in tie_wait / publisher-state.json.
  A3-39 M1  published schedule.nextAt = attemptAt + interval, own deadline only in retryUntil (vectors m1_*; round trip
            through the neighbour's reader).
  A3-40 m3  `never` + expired Claude access token → poll_skipped token_policy, no begin, no attemptAt, no backoff.
  A3-41 m1  failure between state.json and publisher-state.json after a 429 → own Retry-After kept (max of both).
  A3-42 m2  kill in the middle of the publish_failed rollback → no «attempt without a request», next tick polls.

Contract choices made by the tester where the sources are silent (see the A3 fix-cycle report):
  - S2 counter: ticks 1–2 of a publish_failed series must not poll (A3-03 stays), the request comes no later than
    tick 4 (both «3rd tick polls» and «4th tick polls» satisfy it).
  - S2 deadline: measured on the injected clock (time.time and time.monotonic move together); read phase ≤ 60 s + one
    raw timeout (30 s).
  - S3: «sync-state.json for the skew ≤ 1 per pass» = the same pass with 10 raw files writes sync-state.json at most once
    more than with the same files inline (no raw answers).
  - S5: the invalid ids are invalid under every candidate form (`^[0-9a-z-]{8,64}$` from the brief, `[A-Za-z0-9-]{1,64}`
    from T2): '@', '/', 65 characters. A valid lowercase UUID still wins the tie (control).
  - m3: the expired token is the real ~/.claude/.credentials.json (expiresAt one hour ago); the pre-check must not call
    limits.fetch_claude (FakeProviders answer like the real `never` path: CLI credentials expired, no HTTP).
Run: cd linux && python3 -m unittest tests.test_rl_publisher_fixes -v
"""

if __package__:
    from . import _rl_env as rl
    from . import test_rl_coordination as co
    from . import test_rl_publisher as tp
else:
    import _rl_env as rl
    import test_rl_coordination as co
    import test_rl_publisher as tp

import contextlib
import errno
import io
import json
import os
import time
from types import SimpleNamespace
from unittest import mock

from ccl import accounts, cli, common, limits, sync

NOW = rl.NOW
DAY = 86400
KiB = 1024
MiB = 1024 * KiB
ts = tp.ts


def tearDownModule():
    rl.assert_real_files_untouched()


def vectors(prefix):
    doc = rl.fixture("decide-vectors.json")
    return doc, [v for v in doc["vectors"] if v["id"].startswith(prefix)]


class VectorBase(co.Base):
    def run_vectors(self, prefix, minimum):
        doc, vs = vectors(prefix)
        self.assertGreaterEqual(len(vs), minimum, "в decide-vectors.json нет векторов %s*" % prefix)
        for v in vs:
            with self.subTest(v["id"]):
                tw = v.get("tie_wait")
                d = self.decide(v.get("now", doc["now"]), v["mine"], v["remote"], v["my_id"], tuple(tw) if tw else None)
                exp = v["expect"]
                self.assertEqual((co.field(d, "action"), co.field(d, "reason")), (exp["action"], exp["reason"]))
                if "tie_wait" in exp:
                    self.assertEqual(co.norm_pair(co.field(d, "tie_wait")), exp["tie_wait"])
                if "remote_retry" in exp:
                    rr = co.field(d, "remote_retry")
                    if exp["remote_retry"] is None:
                        self.assertFalse(rr, "чужой retryUntil неживой записи не принимается")
                    else:
                        rr = rr or {}
                        self.assertEqual({k: rr.get(k) for k in ("until", "firstSeenAt")}, exp["remote_retry"])
                self.assertEqual(list(co.field(d, "events") or ()), exp.get("events", []))


class Base(tp.Base):
    def follow_monotonic(self):
        """time.monotonic moves with the fake wall clock (raw answers / merge 'take' seconds on both clocks)."""
        self.patch(time, "monotonic", lambda: self.clock.now - NOW + 10000.0)

    def raw_files(self, n, seconds=0.0, prefix="m-r"):
        """n foreign files served only through raw_url; each raw answer advances both clocks by `seconds`."""
        for i in range(n):
            mid = "%s%03d" % (prefix, i)
            self.foreign(mid, [])
            name = "machine-%s.json" % mid
            url = rl.RAW_ROOT + "owner/%s/raw/%040d/%s" % (rl.GIST_ID, i + 1, name)
            content = self.gist.current(name).encode("utf-8")
            self.gist.truncated[name] = url

            def serve(content=content):
                self.clock.advance(seconds)
                return content
            self.gist.raw[url] = serve if seconds else content

    def run_cli(self, argv):
        out = io.StringIO()
        try:
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out), \
                    mock.patch.object(cli, "_timer_status", return_value="test timer"):
                code = cli.main(argv)
        except SystemExit as e:
            code = e.code
        return code, out.getvalue()

    def coord_skips(self, events=None):
        return [e for e in (self.o1() if events is None else events) if e.get("ev") == "poll_skipped"
                and e.get("reason") in ("retry_after", "remote_attempt", "fresh_remote", "tie_break")]


# ==== A3-34 (S1): a future lastSeenAt makes a foreign record not alive ===============================================
class TestA334FutureLastSeenVectors(VectorBase):
    def test_s1_vectors(self):
        self.run_vectors("s1_", 6)

    def test_vectors_encode_the_60s_boundary(self):
        _doc, vs = vectors("s1_")
        by = {v["id"]: v for v in vs}
        n = rl.fixture("decide-vectors.json")["now"]
        self.assertEqual(by["s1_lastseen_plus60_alive_boundary"]["remote"][0]["lastSeenAt"], n + 60)
        self.assertEqual(by["s1_lastseen_plus61_retry_not_alive"]["remote"][0]["lastSeenAt"], n + 61)
        self.assertEqual(by["s1_lastseen_plus60_alive_boundary"]["expect"]["action"], "skip")


class TestA334StaticFutureFile(Base):
    def test_static_file_10y_never_delays_my_polls(self):
        far = NOW + rl.TEN_YEARS
        self.foreign("m-aaaa", [self.foreign_record(status="rate_limited", retryUntil=rl.iso(far),
                                                    attemptAt=rl.iso(NOW - 2 * DAY))], last_seen=far)
        at = NOW
        while at <= NOW + 3 * DAY:
            self.clock.now = at
            self.tick()
            at += 300
        calls = [e.t for e in self.claude_calls()]
        self.assertTrue(calls, "ни одного опроса за 3 суток")
        self.assertEqual(calls[0], NOW, "неживая запись (lastSeenAt +10 лет) не откладывает первый опрос")
        self.assertEqual(self.coord_skips(), [], "ни одного пропуска из-за чужой записи")
        self.assertEqual([e for e in self.o1() if e.get("ev") == "remote_retry_capped"], [],
                         "чужой срок неживой записи не принимался — и потолка нет")
        self.assertLessEqual(max(b - a for a, b in zip(calls, calls[1:])), 14400 + 300,
                             "интервалы — только своё расписание (≤ 4 ч + тик)")


# ==== A3-35 (S2): the read phase cannot starve the publisher ===========================================================
class TestA335ReadDeadline(Base):
    def test_open_cycle_stops_reading_after_60s(self):
        self.follow_monotonic()
        self.raw_files(5, seconds=25)
        t0 = self.clock()
        session = sync.open_cycle(auto=True)
        elapsed = self.clock() - t0
        self.assertIsNotNone(session, "медленное чтение — всё ещё прочитанный gist (частично)")
        self.assertLessEqual(elapsed, 60 + 30, "фаза чтения ≤ 60 с + один таймаут raw (было %.0f с)" % elapsed)
        self.assertLess(len(self.ledger.of("RAW")), 5, "остаток файлов пропущен")
        self.assertTrue(session.result.partial, "пропуск по дедлайну = частичный проход (partial)")
        self.assertTrue(sync.write(session, sync.machine_file({})), "PATCH №1 той же сессией проходит (≤ 120 с)")

    def test_slow_raw_pass_still_polls(self):
        self.follow_monotonic()
        self.raw_files(5, seconds=25)
        self.tick()
        self.assertEqual(len(self.claude_calls()), 1, "5 raw × 25 с: запрос есть в том же тике")
        self.assertFalse(self.skipped("publish_failed"), "PATCH №1 не отклонён как устаревший")
        self.assertEqual(len(self.ledger.of("PATCH")), 2, "PATCH №1 + PATCH №2")

    def test_24h_of_slow_reads_gives_requests(self):
        self.follow_monotonic()
        self.raw_files(5, seconds=25)
        at = NOW
        while at <= NOW + DAY:
            self.clock.now = at
            self.tick()
            at += 300
        self.assertTrue(self.claude_calls(), "≥ 1 запрос за max(I, 24 ч) при медленной сети")
        self.assertLess(len(self.skipped("publish_failed")), 3, "нет серии publish_failed")


class TestA335Reopen(Base):
    def slow_merge(self, times):
        real = sync.merge
        left = [times]

        def merge(*a, **kw):
            if left[0]:
                left[0] -= 1
                self.clock.advance(130)
            return real(*a, **kw)
        self.patch(sync, "merge", merge)

    def test_stale_session_reopened_once(self):
        self.follow_monotonic()
        self.slow_merge(1)                                  # first read: merge "takes" 130 s → session stale
        self.tick()
        self.assertEqual(len(self.claude_calls()), 1, "PATCH №1 отклонён как устаревший → одно переоткрытие → запрос")
        self.assertEqual(len(self.ledger.of("GET")), 2, "ровно одно переоткрытие сессии (второй GET)")
        self.assertFalse(self.skipped("publish_failed"))


class TestA335PublishFailedFallback(Base):
    def test_three_failed_ticks_then_own_schedule(self):
        self.gist.patch_script.extend(common.Resp(500) for _ in range(200))
        polled_at = None
        for n in range(1, 9):
            self.tick()
            if self.claude_calls() and polled_at is None:
                polled_at = n
            self.clock.advance(300)
        self.assertIsNotNone(polled_at, "PATCH всегда 500: опроса нет вообще (S2)")
        self.assertGreaterEqual(polled_at, 3, "1-й и 2-й publish_failed не опрашивают (A3-03)")
        self.assertLessEqual(polled_at, 4, "после 3 тиков publish_failed подряд — опрос по своему расписанию")

    def test_failed_for_24h_polls_on_the_first_failure(self):
        self.first_pass()
        self.clock.now = NOW + DAY + 1                       # now − last_attempt ≥ max(I = 1800, 24 h)
        self.gist.patch_script.append(common.Resp(500))
        self.tick()
        self.assertEqual(len(self.claude_calls()), 2, "now − last_attempt ≥ max(I, 24 ч) → опрос, как при недоступном gist")


class TestA335Visible(Base):
    def test_now_exit_code_on_publish_failed(self):
        self.gist.patch_script.append(common.Resp(500))
        code, out = self.run_cli(["publisher", "--now"])
        self.assertTrue(self.skipped("publish_failed"), "предусловие: publish_failed")
        self.assertNotEqual(code, 0, "publish_failed виден в коде выхода --now: %r" % out)

    def test_stale_session_failure_sets_last_error(self):
        self.follow_monotonic()
        real = sync.merge

        def merge(*a, **kw):
            self.clock.advance(130)                          # every read is too slow → PATCH №1 refused every time
            return real(*a, **kw)
        self.patch(sync, "merge", merge)
        code, out = self.run_cli(["publisher", "--now"])
        self.assertTrue(self.skipped("publish_failed"), "предусловие: publish_failed")
        self.assertEqual(self.claude_calls(), [])
        st = sync.sync_state()
        st.reload()
        self.assertTrue(st.get("lastError"), "отказ PATCH по возрасту сессии виден в lastError")
        self.assertNotEqual(code, 0, out)


# ==== A3-36 (S3): bounded O1 journal, clock_skew once per pass =========================================================
class TestA336JournalCompaction(Base):
    def path(self):
        return os.path.join(common.STATE_DIR, "publisher.jsonl")

    def fill_recent(self, size):
        line = json.dumps({"ev": "poll_skipped", "product": "claude", "reason": "not_due",
                           "ts": rl.iso(NOW - 3600)}, separators=(",", ":")) + "\n"
        with open(self.path(), "w", encoding="utf-8") as f:
            f.write(line * (size // len(line)))
        os.chmod(self.path(), 0o600)

    def test_recent_3mib_compacted_to_512kib(self):
        self.fill_recent(3 * MiB)
        self.assertTrue(common.o1_event("poll_skipped", product="codex", reason="busy"))
        size = os.path.getsize(self.path())
        self.assertLessEqual(size, 512 * KiB, "ротация сжимает до ≤ 512 КиБ независимо от возраста строк (%d)" % size)
        self.assertEqual(os.stat(self.path()).st_mode & 0o777, 0o600)
        lines = self.o1()                                      # every line is whole JSON (cut on a line boundary)
        self.assertEqual((lines[-1].get("product"), lines[-1].get("reason")), ("codex", "busy"), "последняя строка цела")

    def test_later_appends_do_not_rewrite(self):
        self.fill_recent(3 * MiB)
        common.o1_event("poll_skipped", product="claude", reason="busy")
        st = os.stat(self.path())
        size = st.st_size
        for _ in range(20):
            common.o1_event("poll_skipped", product="claude", reason="busy")
        after = os.stat(self.path())
        self.assertEqual(after.st_ino, st.st_ino, "гистерезис: после сжатия запись — только O_APPEND, без переписывания")
        self.assertGreater(after.st_size, size)
        self.assertLessEqual(after.st_size, 512 * KiB + 20 * 256)


class TestA336ClockSkewOncePerPass(Base):
    def sync_writes(self, mark):
        return [e for e in self.ledger.since(mark) if e.kind == "write" and e.name == "sync-state.json"]

    def test_skew_120_and_10_raw_files(self):
        self.first_pass()
        self.gist.skew = 120.0
        self.raw_files(10)
        counts = []
        for _ in range(2):
            self.clock.advance(60)                             # not due, no heartbeat yet
            n, mark = len(self.o1()), self.ledger.mark()
            self.tick()
            self.assertEqual(len(self.ledger.of("RAW")) % 10, 0, "предусловие: файлы читаются через raw")
            counts.append((len([e for e in self.o1()[n:] if e.get("ev") == "clock_skew"]), len(self.sync_writes(mark))))
        for events, _writes in counts:
            self.assertLessEqual(events, 1, "clock_skew не чаще раза за проход: %r" % counts)
        # The same pass with the same files inline (no raw answers): the difference is the per-answer skew writes.
        self.gist.truncated.clear()
        self.clock.advance(60)
        mark = self.ledger.mark()
        self.tick()
        inline = len(self.sync_writes(mark))
        self.assertLessEqual(counts[-1][1] - inline, 1,
                             "clockSkew в sync-state.json — раз за проход, не на каждый ответ raw (%d против %d)"
                             % (counts[-1][1], inline))


# ==== A3-37 (S4/m5): --now only on a publisher; manual push goes through the pass ======================================
class TestA337PublisherOnly(Base):
    def recorder(self):
        calls = []
        self.patch(self.pub(), "run_pass", lambda kind="auto": calls.append(kind) or
                   dict(polled=[], skipped={}, next_at={}, error=None))
        return calls

    def test_now_refused_without_publisher(self):
        calls = self.recorder()
        self.write_settings(publisher=False, credential_write="guarded")
        code, out = self.run_cli(["publisher", "--now"])
        self.assertNotEqual(code, 0, "--now без publisher:true — отказ: %r" % out)
        self.assertEqual(calls, [], "проход не запускается")
        self.assertEqual(self.claude_calls(), [])

    def test_manual_push_on_publisher_goes_through_the_pass(self):
        for argv in (["push"], ["push", "--force"], ["push", "--quiet"]):
            with self.subTest(argv=argv):
                calls = self.recorder()
                with mock.patch.object(sync, "sync_cycle",
                                       side_effect=AssertionError("ручной push издателя не должен гонять sync_cycle")):
                    code, out = self.run_cli(argv)
                self.assertEqual(calls, ["manual"], out)
                self.assertEqual(code, 0, out)

    def test_forced_push_keeps_the_accounts_block(self):
        self.first_pass()
        self.assertIsNotNone(self.published(), "предусловие: блок accounts в gist")
        self.clock.advance(60)
        code, out = self.run_cli(["push", "--force"])
        mine = self.gist.machine_file(self.my_file())
        self.assertIsNotNone(mine)
        self.assertIsNotNone(self.record(mine, self.label()),
                             "после ручного push файл машины всё ещё несёт запись своей метки (rc=%r)" % code)


# ==== A3-38 (S5): malformed foreign machine.id never reaches tie_wait ==================================================
class TestA338ForeignMachineIdForm(Base):
    MY_ID = "ffffffff-ffff-4fff-bfff-ffffffffffff"
    VALID = "00000000-0000-4000-8000-000000000000"

    def setUp(self):
        super().setUp()
        os.makedirs(os.path.dirname(common.MACHINE_ID_PATH), exist_ok=True)
        with open(common.MACHINE_ID_PATH, "w", encoding="utf-8") as f:
            f.write(self.MY_ID + "\n")
        self.assertEqual(common.machine_id(), self.MY_ID)

    def tie(self, mid):
        self.first_pass()                                     # due = NOW + 1800
        self.clock.now = NOW + 1800
        rec = self.foreign_record(attemptAt=rl.iso(NOW), schedule={"mode": "auto", "interval": 1800,
                                                                   "backoff": False, "nextAt": rl.iso(NOW + 1800)})
        self.foreign(mid, [rec], last_seen=NOW + 1790)
        n = len(self.o1())
        self.tick()
        return self.o1()[n:]

    def test_valid_id_wins_the_tie_control(self):
        events = self.tie(self.VALID)
        self.assertTrue(self.skipped("tie_break", "claude", events), "контроль: сценарий действительно тай-брейк")
        self.assertIn(self.VALID, self.publisher_state_text())

    def test_malformed_id_with_at(self):
        mid = "0a@review.invalid"
        events = self.tie(mid)
        self.assertFalse(self.skipped("tie_break", "claude", events), "чужой id вне формы не даёт тай-брейк")
        self.assertNotIn(mid, self.publisher_state_text(), "id вне формы не сохранён в publisher-state.json")
        self.assertEqual(len(self.claude_calls()), 2, "опрос по своему сроку")

    def test_malformed_id_with_slash(self):
        events = self.tie("0a/../x")
        self.assertFalse(self.skipped("tie_break", "claude", events))
        self.assertNotIn("0a/../x", self.publisher_state_text())

    def test_malformed_id_65_chars(self):
        mid = "0" * 65
        events = self.tie(mid)
        self.assertFalse(self.skipped("tie_break", "claude", events))
        self.assertNotIn(mid, self.publisher_state_text())


# ==== A3-39 (M1): nextAt is the own cadence, Retry-After only in retryUntil ============================================
class TestA339NextAtVectors(VectorBase):
    def test_m1_vectors(self):
        self.run_vectors("m1_", 2)


class TestA339PublishedNextAt(Base):
    def test_429_ra_2h_nextat_is_own_cadence(self):
        self.providers.replies["claude"].append(lambda p, now: rl.rate_limited(now, 7200))
        self.tick()
        r = self.pubrec()
        sched = r.get("schedule") or {}
        self.assertEqual(ts(r.get("retryUntil")), NOW + 7200, "свой Retry-After — в retryUntil")
        self.assertEqual(ts(sched.get("nextAt")), ts(r.get("attemptAt")) + sched.get("interval"),
                         "schedule.nextAt = attemptAt + interval (без retryUntil)")
        self.assertLess(ts(sched.get("nextAt")), NOW + 7200)

    def test_neighbour_reader_honours_the_published_429(self):
        self.providers.replies["claude"].append(lambda p, now: rl.rate_limited(now, 7200))
        self.tick()
        text = self.gist.current(self.my_file())
        self.assertIsNotNone(text)
        other = "zzzzzzzz-0000-4000-8000-000000000000"
        remote = sync.merge({self.my_file(): text}, other, now=NOW + 1000)
        pub = self.pub()
        recs = pub._remote(SimpleNamespace(remote=remote), "claude", self.label())
        self.assertTrue(recs, "сосед видит запись моей метки")
        from ccl import coordination
        d = coordination.decide(NOW + 1000, dict(interval=1800, last_attempt=NOW - 4000, server_until=None,
                                                 remote_retry=None), recs, other, None)
        self.assertEqual((d.action, d.reason), ("skip", "retry_after"),
                         "сосед после моего 429 (RA 2 ч) ждёт retryUntil, а не опрашивает (B2/B6)")


# ==== A3-40 (m3): never + expired access token → token_policy, no begin ================================================
class TestA340TokenPolicy(Base):
    def setUp(self):
        super().setUp()
        obj = {"claudeAiOauth": {"accessToken": "fixture-access-x", "refreshToken": "fixture-refresh-x",
                                 "expiresAt": int((NOW - 3600) * 1000),
                                 "refreshTokenExpiresAt": int((NOW + 30 * DAY) * 1000),
                                 "scopes": ["user:inference"], "subscriptionType": "max"}}
        self.write_file(common.CLAUDE_CREDENTIALS, json.dumps(obj))

        def cli_expired(product, now):
            d = limits.LimitData()                              # what the real `never` path returns, without HTTP
            d.auth, d.error, d.failure_kind, d.poll_failed = limits.EXPIRED, "CLI credentials expired", "auth", True
            d.expired_reason = "cli_refresh_pending"
            return d
        self.providers.default = cli_expired

    def test_skip_without_attempt(self):
        self.assertEqual(common.credential_write(), "never", "предусловие: издатель — never")
        for _ in range(4):
            self.tick()
            self.clock.advance(1800)
        self.assertTrue(self.skipped("token_policy", "claude"), "poll_skipped token_policy (§C шаг 5)")
        self.assertEqual(self.claude_calls(), [], "без begin и без вызова провайдера")
        for _e, body in self.bodies():
            r = self.record(body, self.label())
            self.assertFalse(r and r.get("attemptAt"), "ложного attemptAt нет в gist: %r" % r)
        poll = (self.state().get("autoPollState") or {}).get("claude") or {}
        self.assertFalse(poll.get("last_attempt"), "попытка не записана")
        self.assertFalse(poll.get("failed"), "Auto не уходит в backoff")


# ==== A3-41 (m1): own Retry-After survives a failure between the two state files =======================================
class TestA341RetryAfterMirror(Base):
    def test_publisher_state_write_fails_after_429(self):
        self.providers.replies["claude"].append(lambda p, now: rl.rate_limited(now, 3600))

        def fail_next_publisher_state(product):
            self.ledger.fail_paths["publisher-state.json"] = OSError(errno.ENOSPC, "No space left on device")
        self.providers.on_call = fail_next_publisher_state
        self.tick()
        self.providers.on_call = None
        self.ledger.fail_paths.clear()
        self.assertEqual(len(self.claude_calls()), 1)
        self.assertEqual((self.state().get("quotaServerRetryAt") or {}).get("claude"), NOW + 3600,
                         "предусловие: state.json записан, publisher-state.json — нет")
        self.restart()
        for at in range(300, 3600, 300):
            self.clock.now = NOW + at
            self.tick()
        self.clock.now = NOW + 3599
        self.tick()
        self.assertEqual(len(self.claude_calls()), 1, "свой Retry-After (зеркало state.json) соблюдён до +3600")
        self.clock.now = NOW + 3600
        self.tick()
        self.assertEqual(len(self.claude_calls()), 2)


# ==== A3-42 (m2): kill in the middle of the publish_failed rollback =====================================================
class TestA342RollbackKill(Base):
    def test_kill_between_rollback_writes(self):
        self.first_pass()
        self.clock.advance(1800)
        armed = {"n": None}
        inner = common.write_atomic

        def write_atomic(path, data, mode=0o600):
            if armed["n"] is not None and os.path.basename(path) in rl.STATE_FILES:
                armed["n"] += 1
                if armed["n"] == 2:                             # SIGKILL before the 2nd state write of the rollback
                    self.ledger.dead = True
                    raise rl.Kill()
            return inner(path, data, mode)
        self.patch(common, "write_atomic", write_atomic)

        def fail(rec):
            armed["n"] = 0
            return common.Resp(500)
        self.gist.patch_script.append(fail)
        self.tick()
        armed["n"] = None
        self.assertEqual(len(self.claude_calls()), 1, "PATCH №1 не прошёл — запроса нет")
        self.restart()
        self.clock.advance(300)
        self.tick()
        self.assertEqual(len(self.claude_calls()), 2,
                         "обрыв посреди отката: попытка без запроса не засчитана, следующий тик опрашивает")


if __name__ == "__main__":
    import unittest
    unittest.main()
