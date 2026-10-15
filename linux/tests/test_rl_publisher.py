"""REMOTE-LIMITS A3 — headless publisher pass and its deferred review items (synth v2 §C/§D/§B, T1 П2-в/П6-а/П7/П8-а,
docs/plans.md §A3 incl. «Из ревью A2» / «Из ревью A1»). Test-plan IDs A3-02…A3-19, A3-21, A3-22…A3-33.
Written BEFORE the code (red): every test fails on a missing name/behaviour, never on its own harness.

Harness (`_rl_env.PubEnv`): temp HOME/XDG, ~/.claude.json with account U_A, no Codex login, signed in to GitHub (gist g1),
settings of an installed publisher; FakeClock on time.time/time.sleep; FakeGist on sync.transport (revisions, Date header,
scripted failures, raw URLs, > 16 MiB mode); FakeProviders on limits.fetch_claude / limits.fetch_codex (local id captured
before the request); one Ledger (seq) of GET/PATCH/LIST/RAW, provider requests and state-file writes; Kill = SIGKILL.

Contract for the developer (names the synth leaves open are tester's choice — see the A3 report):
  publisher.run_pass(kind="auto"|"manual") — one pass, steps 0–8 of synth §C; returns normally on ANY Exception
      (BaseException is not swallowed); time only through time.time()/time.sleep(); providers only through
      limits.fetch_claude() / limits.fetch_codex(live=True) looked up at call time; usage through usage.refresh();
      takes common.file_lock("quota", timeout≤30) and sync.open_cycle → common.file_lock("sync", timeout≤60, blocking);
      calls limits.flush_pending() once at the end of every pass, outside a credential attempt.
  sync.open_cycle(auto=True) -> session | None  (None: signed out, sync lock not obtained within 60 s, gist unreadable);
      session.remote = merged other machines (as sync-remote.json); a partial read (one file skipped) still gives a session.
  sync.write(session, text) -> bool  — PATCH of this machine's file (text = full machine-file JSON); never without a GET
      of the same gist ≤ 120 s ago; 404 → gistId/pushHash cleared, no discovery inside write.
  sync_state(): clockSkew (= Date − now, seconds) and clockSkewAt after every GitHub answer.
  SyncResult.partial: True when the cycle merged but skipped a file (size/raw refusal); `ccl-sync push` exits 0 then
      and does not print «Sync failed / Ошибка синхронизации».
  sync-state.json rejectedRaw = {sha256(raw_url)[:16]: refusal ts}, 24 h, ≤ 64 (oldest evicted), no URL/gist id/sha (N9, Q4).
  Files: <STATE>/publisher.jsonl (O1, 0600, O_APPEND|O_CREAT, rotation > 1 MiB drops lines older than 45 days, atomic),
      <STATE>/publisher-state.json, state.json (autoPollState / quotaServerRetryAt — never a foreign deadline).
  O1 line = {"ev": <event>, "ts": ISO, scalar enumerated fields}; events — rl.O1_EVENTS, poll_skipped reasons —
      rl.SKIP_REASONS; caught exception → {"ev": "pass_failed", "class": <ExceptionClass>} (no text);
      clock_skew carries the seconds; token_refresh carries credentialWrite=1 and policy.
  accounts.build(...) never raises on counter overflow: every accounts[].days = {}, block["dropped"] = "counter_overflow"
      (never published); the publisher logs "accounts_days_dropped".
  CLI: `ccl-sync push --auto` with settings.publisher=true → publisher.run_pass("auto") instead of sync_cycle;
      `ccl-sync publisher --enable|--disable|--now|--status`; --now prints «можно с HH:MM» via cli._fmt_time.
  polling.normalize_interval(value) — moved from gui.panel.poll_interval; ccl.publisher imports without PyQt5.
Run: cd linux && python3 -m unittest tests.test_rl_publisher -v
"""

if __package__:
    from . import _rl_env as rl
    from . import test_rl_tokens as t
else:
    import _rl_env as rl
    import test_rl_tokens as t

import contextlib
import errno
import fcntl
import io
import json
import os
import re
import subprocess
import sys
import time
import unittest
from unittest import mock

from ccl import accounts, cli, common, limits, sync, usage

NOW = rl.NOW
DAY = 86400
MiB = 1024 * 1024
SAFE_VALUE = re.compile(r"^[A-Za-z0-9_.:+-]{0,64}\Z")
SYNC_FAILED = ("Sync failed", "Ошибка синхронизации")
TESTS_DIR = os.path.dirname(os.path.abspath(__file__))


def tearDownModule():
    rl.assert_real_files_untouched()


def ts(value):
    return common.parse_iso(value) if isinstance(value, str) else None


class Base(rl.PubEnv):
    def lock_calls(self):
        """Record every common.file_lock call (name, blocking, timeout); refuse an unbounded wait on quota/sync."""
        calls = []
        real = common.file_lock

        def file_lock(name, blocking=True, timeout=None):
            calls.append((name, blocking, timeout))
            if name in ("quota", "sync") and blocking and timeout is None:
                raise AssertionError("file_lock(%r) без предела ожидания (синтез: quota ≤ 30 с, sync ≤ 60 с)" % name)
            return real(name, blocking, timeout)
        self.patch(common, "file_lock", file_lock)
        return calls

    def due_state(self):
        return (self.state().get("autoPollState") or {}).get("claude")

    def claude_calls(self):
        return self.providers.calls("claude")

    def pubrec(self, product="claude", local_id=None):
        r = self.published(product, local_id)
        self.assertIsNotNone(r, "в gist нет записи своей метки (%s)" % product)
        return r

    def first_pass(self):
        self.tick()
        self.assertEqual(len(self.claude_calls()), 1, "предусловие: первый проход опрашивает Claude")


# ---- A3-02 order of the due pass: attempt saved → PATCH №1 (attemptAt) → provider → PATCH №2 ---------------------------
class TestA302Order(Base):
    def test_attempt_is_announced_before_the_provider_request(self):
        self.tick()
        ev = self.ledger.events
        gets, patches, calls = self.ledger.of("GET"), self.ledger.of("PATCH"), self.claude_calls()
        self.assertEqual(len(calls), 1, "due-продукт опрошен ровно один раз")
        self.assertEqual(len(gets), 1, "≤ 1 GET на проход")
        self.assertEqual(len(patches), 2, "due-тик: PATCH №1 (попытка) + PATCH №2 (результат)")
        p1, p2 = patches
        self.assertLess(gets[0].seq, p1.seq)
        self.assertLess(p1.seq, calls[0].seq, "PATCH с attemptAt раньше запроса к провайдеру (№5)")
        self.assertLess(calls[0].seq, p2.seq)
        saved = [e for e in ev if e.kind == "write" and e.name in rl.STATE_FILES and gets[0].seq < e.seq < p1.seq
                 and (str(int(NOW)) in e.data or rl.iso(NOW) in e.data)]
        self.assertTrue(saved, "B3 (synth §C, Q5): GET → попытка сохранена в state.json/publisher-state.json → PATCH №1")
        bodies = self.bodies()
        r1 = self.record(bodies[0][1], self.label())
        self.assertIsNotNone(r1, "PATCH №1 несёт запись своей метки")
        self.assertEqual(ts(r1.get("attemptAt")), NOW)
        self.assertNotIn("asOf", r1, "до первого успеха asOf нет (C3/C4)")
        r2 = self.record(bodies[1][1], self.label())
        self.assertIsNotNone(r2, "PATCH №2 несёт запись своей метки")
        self.assertEqual(r2.get("status"), "ok")
        self.assertEqual(ts(r2.get("asOf")), NOW)
        self.assertEqual(ts(r2.get("attemptAt")), NOW)
        self.assertEqual((r2.get("windows") or {}).get("session", {}).get("pct"), 40.0)

    def test_journal_records_attempt_and_result(self):
        self.tick()
        evs = [e.get("ev") for e in self.o1()]
        self.assertIn("poll_attempt", evs)
        self.assertIn("poll_result", evs)
        self.assertIn("publish", evs)
        self.assertLess(evs.index("poll_attempt"), evs.index("poll_result"))


# ---- A3-03 PATCH №1 fails → no provider request, last_attempt restored, next tick retries --------------------------------
class TestA303PublishFailed(Base):
    def failing(self, failure):
        self.first_pass()
        self.clock.advance(1800)                             # due again (default interval 1800 s)
        before = self.due_state()
        self.assertIsNotNone(before)
        mark = self.ledger.mark()
        o1_before = len(self.o1())
        self.gist.patch_script.append(failure)
        self.tick()
        new = self.ledger.since(mark)
        self.assertEqual([e for e in new if e.kind == "provider"], [], "PATCH №1 не прошёл → запроса нет")
        self.assertEqual(self.due_state(), before, "last_attempt в state.json возвращён к значению до прохода")
        events = self.o1()[o1_before:]
        self.assertTrue(self.skipped("publish_failed", "claude", events), "poll_skipped publish_failed")
        self.assertTrue(any(e.get("ev") == "publish" and "failed" in e.values() for e in events), "publish failed")
        self.clock.advance(300)
        self.tick()
        self.assertEqual(len(self.claude_calls()), 2, "следующий тик повторяет объявление и опрашивает")

    def test_http_500(self):
        self.failing(common.Resp(500))

    def test_network(self):
        self.failing(common.Resp(0, error="Network is unreachable"))

    def test_404(self):
        self.failing(common.Resp(404))

    def test_timeout_raised_by_transport(self):
        self.failing(TimeoutError("timed out"))


# ---- A3-04 no label → no request -------------------------------------------------------------------------------------
class TestA304NoLabel(Base):
    def test_unreadable_profile(self):
        self.write_claude_json(raw="{not json")
        self.tick()
        self.assertEqual(self.claude_calls(), [])
        self.assertTrue(self.skipped("no_label", "claude"))
        recs = [r for _e, b in self.bodies() for r in b.get("accounts") or [] if r.get("product") == "claude"]
        self.assertTrue(recs and all(r.get("label") is None and r.get("labelReason") == "unreadable"
                                     and r.get("status") == "error" for r in recs))

    def test_no_account_uuid(self):
        self.write_claude_json(None)
        self.tick()
        self.assertEqual(self.claude_calls(), [])
        self.assertTrue(self.skipped("no_label", "claude"))

    def test_no_login(self):
        os.unlink(common.CLAUDE_JSON)
        self.tick()
        self.assertEqual(self.claude_calls(), [])
        self.assertTrue(self.skipped("no_login", "claude"))
        recs = [r for _e, b in self.bodies() for r in b.get("accounts") or [] if r.get("product") == "claude"]
        self.assertTrue(recs and all(r.get("status") == "signed_out" for r in recs))

    def test_no_gist_id(self):
        sync.sync_state().update(gistId=None)
        self.gist.list_script.append(common.Resp(500))       # discovery fails → no gist id at all
        self.tick()
        self.assertEqual(self.claude_calls(), [], "нет gist id → no_gist, опроса нет (P6)")


# ---- A3-05 not signed in to GitHub ------------------------------------------------------------------------------------
class TestA305NoGithub(Base):
    CODEX = True

    def check(self):
        self.tick()
        self.assertEqual([e.kind for e in self.ledger.events if e.kind in ("GET", "PATCH", "LIST", "provider")], [],
                         "ни GET, ни PATCH, ни запросов к провайдерам")
        products = {e.get("product") for e in self.skipped("no_github")}
        self.assertTrue({"claude", "codex"} <= products, "poll_skipped no_github на каждый продукт: %r" % products)

    def test_signed_out(self):
        sync.sync_state().remove("login")
        self.check()

    def test_revoked(self):
        sync.sync_state().update(revoked=True)
        self.check()


# ---- A3-06 gist unavailable → own schedule, block goes out with the first good pass ------------------------------------
class TestA306GistUnavailable(Base):
    def check(self, failure):
        self.gist.get_script.append(failure)
        self.tick()
        self.assertEqual(len(self.claude_calls()), 1, "GET не прошёл → запрос по своему расписанию (B1)")
        self.assertEqual(self.ledger.of("PATCH"), [], "объявления нет")
        self.clock.advance(300)
        self.tick()
        self.assertEqual(len(self.claude_calls()), 1)
        r = self.published()
        self.assertIsNotNone(r, "блок ушёл первым удачным проходом")
        self.assertEqual(ts(r.get("asOf")), NOW)

    def test_get_500(self):
        self.check(common.Resp(500))

    def test_get_network(self):
        self.check(common.Resp(0, error="Network is unreachable"))


# ---- A3-07 not due after restart / reboot / timer tick (011: the ledger proves it, not `not_due`) ------------------------
class TestA307NotDue(Base):
    def test_restart_reboot_tick(self):
        self.first_pass()
        for what, step, restart in (("tick", 300, False), ("new process", 60, True), ("reboot OnBootSec", 120, True)):
            with self.subTest(what):
                self.clock.advance(step)
                if restart:
                    self.restart()
                mark = self.ledger.mark()
                self.tick()
                new = self.ledger.since(mark)
                self.assertTrue([e for e in new if e.kind == "GET"], "проход действительно шёл (GET)")
                self.assertEqual([e for e in new if e.kind == "provider"], [], what)


# ---- A3-08 429 Retry-After: own deadline kept whole and published -----------------------------------------------------
class TestA308RetryAfter(Base):
    def test_retry_after_3600(self):
        self.providers.replies["claude"].append(lambda p, now: rl.rate_limited(now, 3600))
        self.tick()
        r = self.pubrec()
        self.assertEqual(ts(r.get("retryUntil")), NOW + 3600, "свой retryUntil опубликован")
        self.assertEqual(r.get("status"), "rate_limited")
        for at in range(300, 3600, 300):
            self.clock.now = NOW + at
            self.tick("manual" if at == 1200 else "auto")
        self.clock.now = NOW + 3599
        self.tick()
        self.assertEqual(len(self.claude_calls()), 1, "до +3600 запросов нет (и --now тоже)")
        self.clock.now = NOW + 3600
        self.tick()
        self.assertEqual(len(self.claude_calls()), 2, "на +3600 — опрос")

    def test_retry_after_48h_not_cut(self):
        self.providers.replies["claude"].append(lambda p, now: rl.rate_limited(now, 48 * 3600))
        self.tick()
        self.assertEqual(ts(self.pubrec().get("retryUntil")), NOW + 48 * 3600, "свой Retry-After не режется до 24 ч")
        for at in (DAY + 300, 47 * 3600):
            self.clock.now = NOW + at
            self.tick()
        self.assertEqual(len(self.claude_calls()), 1)


# ---- A3-09 T31: foreign retryUntil = now + 10 y, re-read every 5 min, 3 restarts → cap at firstSeenAt + 24 h -----------
class TestA309ForeignRetryCap(Base):
    def test_cap_survives_restarts(self):
        restarts = {NOW + 3600, NOW + 8 * 3600, NOW + 20 * 3600}
        at = NOW
        while at <= NOW + DAY + 600:
            self.clock.now = at
            self.foreign("m-aaaa", [self.foreign_record(status="rate_limited", retryUntil=rl.iso(NOW + rl.TEN_YEARS),
                                                        attemptAt=rl.iso(NOW - 2 * DAY))])
            if at in restarts:
                self.restart()
            self.tick()
            if at < NOW + DAY:
                self.assertEqual(self.claude_calls(), [], "чужой дедлайн соблюдается до firstSeenAt + 24 ч (t=%d)" % (at - NOW))
            at += 300
        calls = self.claude_calls()
        self.assertTrue(calls, "после firstSeenAt + 24 ч — своё расписание")
        self.assertEqual(calls[0].t, NOW + DAY)
        capped = [e for e in self.o1() if e.get("ev") == "remote_retry_capped"]
        self.assertEqual(len(capped), 1)
        st = self.state()
        for key in ("quotaServerRetryAt", "autoPollState"):
            text = json.dumps(st.get(key))
            for n in re.findall(r"\d{10,}(?:\.\d+)?", text):
                self.assertLess(float(n), NOW + 300 * DAY, "%s: чужой дедлайн попал в своё хранилище" % key)


# ---- A3-10 B3: the attempt cannot be saved → no request ---------------------------------------------------------------
class TestA310StateUnsaved(Base):
    def test_disk_full(self):
        for name in rl.STATE_FILES:
            self.ledger.fail_paths[name] = OSError(errno.ENOSPC, "No space left on device")
        self.tick()
        self.assertEqual(self.claude_calls(), [])
        self.assertTrue(self.skipped("state_unsaved", "claude"))


# ---- A3-11 T34: killed after durable begin / after the request / before PATCH №2 ---------------------------------------
class TestA311Kill(Base):
    def after_kill(self, expect_as_of):
        self.restart()
        self.clock.now = NOW + 60
        n = len(self.claude_calls())
        self.tick()
        self.assertEqual(len(self.claude_calls()), n, "новый процесс через 60 с не повторяет запрос")
        sent = [b for e, b in self.bodies() if e.t == NOW + 60]
        self.assertTrue(sent, "блок уходит в первый удачный цикл")
        r = self.record(sent[-1], self.label())
        self.assertIsNotNone(r, "запись своей метки в блоке")
        self.assertEqual(ts(r.get("attemptAt")), NOW)
        if expect_as_of:
            self.assertEqual(ts(r.get("asOf")), NOW, "результат, полученный до kill, опубликован")
        self.clock.now = NOW + 899
        self.tick()
        self.assertEqual(len(self.claude_calls()), n, "и через 899 с — тоже")

    def test_kill_after_begin_before_patch1(self):
        self.ledger.kill_on["PATCH"] = 1
        self.tick()
        self.assertEqual(self.claude_calls(), [])
        self.after_kill(expect_as_of=False)

    def test_kill_after_request_sent(self):
        self.providers.kill_after = True
        self.tick()
        self.assertEqual(len(self.claude_calls()), 1)
        self.after_kill(expect_as_of=False)

    def test_kill_before_patch2(self):
        self.ledger.kill_on["PATCH"] = 2
        self.tick()
        self.assertEqual(len(self.claude_calls()), 1)
        self.after_kill(expect_as_of=True)


# ---- A3-12 401 after a success an hour ago → expired, values and asOf kept (C3) ----------------------------------------
class TestA312Expired(Base):
    def test_values_survive_401(self):
        self.first_pass()
        self.clock.now = NOW + 3600
        self.providers.replies["claude"].append(lambda p, now: rl.expired(now))
        self.tick()
        r = self.pubrec()
        self.assertEqual(r.get("status"), "expired")
        self.assertEqual(ts(r.get("asOf")), NOW, "asOf прежний")
        self.assertEqual((r.get("windows") or {}).get("session", {}).get("pct"), 40.0, "значения прежние")


# ---- A3-13 T29 / П2-в: identity A→B→A during the HTTP request ---------------------------------------------------------
class TestA313IdentityChanged(Base):
    def test_switch_during_request(self):
        self.first_pass()                                     # A: success at NOW, session 40
        self.clock.now = NOW + 1800

        def switch(product):
            if product == "claude":
                self.write_claude_json(rl.U_B)
        self.providers.on_call = switch
        self.providers.replies["claude"].append(lambda p, now: rl.rate_limited(now, 3600))
        self.tick()
        self.providers.on_call = None
        self.assertIn("identity_changed", [e.get("ev") for e in self.o1()])
        lab_b = self.label("claude", rl.U_B)
        for _e, body in self.bodies():
            rb = self.record(body, lab_b)
            if rb is not None:
                for key in ("asOf", "windows", "models", "plan"):
                    self.assertNotIn(key, rb, "ответ/значения A не применены к B (%s)" % key)
                self.assertIn(rb.get("retryUntil"), (None,), "429 A не ставит retryUntil B")
        cached = (common.read_json(common.CACHE_PATH, {}) or {}).get("claude") or {}
        if cached.get("accountId") == rl.U_B:
            self.assertFalse({"session", "weekly", "asOf"} & set(cached), "кэш B без значений до первого успеха")
        self.write_claude_json(rl.U_A)                        # back to A
        self.clock.now = NOW + 2100
        n = len(self.claude_calls())
        self.tick()
        self.assertEqual(len(self.claude_calls()), n, "попытка во время смены потрачена (бюджет A сохранён)")
        ra = self.pubrec("claude", rl.U_A)
        self.assertEqual(ts(ra.get("asOf")), NOW, "последнее хорошее показание A сохранено")
        self.assertEqual((ra.get("windows") or {}).get("session", {}).get("pct"), 40.0)

    def test_new_account_has_no_values_until_first_success(self):
        self.first_pass()
        self.write_claude_json(rl.U_B)
        self.clock.now = NOW + 120
        self.providers.replies["claude"].append(lambda p, now: rl.expired(now))
        self.tick()
        rb = self.pubrec("claude", rl.U_B)
        for key in ("asOf", "windows", "models"):
            self.assertNotIn(key, rb, "fallback между аккаунтами запрещён (№3): %s" % key)
        self.assertIn("label_changed", [e.get("ev") for e in self.o1()])


# ---- A3-14 write rule: three fingerprints ------------------------------------------------------------------------------
class TestA314WriteRule(Base):
    def setUp(self):
        super().setUp()
        self.days_input = 1
        test = self

        def refresh(blocking=True, progress=None):
            day = common.day_key(time.time())
            ix = {"v": 1, "files": {}, "seen": {},
                  "days": {"claude": {day: {"claude-opus-5-5": dict(input=test.days_input, output=1, cacheRead=0,
                                                                     cacheWrite5m=0, cacheWrite1h=0, turns=1)}}},
                  "accountByDay": {"claude": {day: rl.U_A}}}
            return ix, True, True
        self.patch(usage, "refresh", refresh)

    def patches_at(self, at):
        self.clock.now = NOW + at
        mark = self.ledger.mark()
        self.tick()
        new = self.ledger.since(mark)
        gets = [e for e in new if e.kind == "GET"]
        patches = [e for e in new if e.kind == "PATCH"]
        self.assertLessEqual(len(gets), 1, "≤ 1 GET на проход (t=%d)" % at)
        return patches

    def test_due_tick_budget(self):
        self.assertLessEqual(len(self.patches_at(0)), 2, "due-тик: ≤ 1 GET + 2 PATCH")
        self.assertLessEqual(len(self.patches_at(300)), 1, "не-due: ≤ 1 GET + ≤ 1 PATCH")

    def test_usage_change_waits_570s(self):
        self.patches_at(0)
        self.days_input = 2
        self.assertEqual(self.patches_at(300), [], "(a) расход изменился через 300 с → PATCH нет")
        p = self.patches_at(580)
        self.assertEqual(len(p), 1, "(a) ≥ 570 с → PATCH с расходом")
        body = self.bodies(p)[0][1]
        day = common.day_key(NOW + 580)
        self.assertEqual(body["days"]["claude"][day]["claude-opus-5-5"]["input"], 2)

    def test_metadata_goes_out_at_once(self):
        self.patches_at(0)
        os.unlink(common.CLAUDE_JSON)                         # status/label change, not due, < 570 s
        self.assertEqual(len(self.patches_at(120)), 1, "(b) метаданные → PATCH сразу")

    def test_heartbeat_changes_only_last_seen(self):
        self.patches_at(0)
        self.assertTrue(self.bodies(), "первый проход публикует")
        last = self.bodies()[-1][1]
        self.assertEqual(self.patches_at(300), [], "(c) 300 с без изменений → 0 PATCH")
        p = self.patches_at(600)
        self.assertEqual(len(p), 1, "(c) 600 с → heartbeat")
        hb = self.bodies(p)[0][1]
        self.assertEqual(ts(hb.get("lastSeenAt")), NOW + 600)
        strip = lambda b: {k: v for k, v in b.items() if k not in ("lastSeenAt", "updated")}  # noqa: E731
        self.assertEqual(strip(hb), strip(last), "heartbeat меняет только lastSeenAt/updated (не asOf, попытку, интервал)")

    def test_no_self_sustaining_writes(self):
        self.patches_at(0)
        self.assertEqual(self.patches_at(300) + self.patches_at(599), [], "(d) два не-due тика в 600 с → 0 PATCH")
        self.assertEqual(len(self.patches_at(600)), 1)
        self.assertEqual(self.patches_at(900), [], "(d) после heartbeat следующий тик снова без PATCH")


# ---- A3-15 manual `ccl-sync publisher --now` ---------------------------------------------------------------------------
class TestA315Manual(Base):
    def run_cli(self, argv):
        out = io.StringIO()
        try:
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out), \
                    mock.patch.object(cli, "_timer_status", return_value="test timer"):
                code = cli.main(argv)
        except SystemExit as e:
            code = e.code
        return code, out.getvalue()

    def test_own_floor_899_900(self):
        self.first_pass()
        self.clock.now = NOW + 899
        self.tick("manual")
        self.assertEqual(len(self.claude_calls()), 1, "своя попытка 899 с назад → только чтение gist")
        self.clock.now = NOW + 900
        self.tick("manual")
        self.assertEqual(len(self.claude_calls()), 2, "900 с → ровно один запрос")

    def test_foreign_attempt_959_960_via_cli(self):
        self.foreign("m-aaaa", [self.foreign_record(attemptAt=rl.iso(NOW - 959))])
        code, out = self.run_cli(["publisher", "--now"])
        self.assertEqual(code, 0, out)
        self.assertEqual(self.claude_calls(), [], "чужая попытка 959 с → запроса нет")
        self.assertIn(cli._fmt_time(NOW - 959 + 960), out, "«опрос можно с HH:MM» = чужая + 960")
        self.clock.now = NOW + 1
        self.foreign("m-aaaa", [self.foreign_record(attemptAt=rl.iso(NOW - 959))])
        self.tick("manual")
        self.assertEqual(len(self.claude_calls()), 1, "960 с → ровно один запрос")

    def test_retry_until_in_effect(self):
        self.foreign("m-aaaa", [self.foreign_record(status="rate_limited", retryUntil=rl.iso(NOW + 600))])
        code, out = self.run_cli(["publisher", "--now"])
        self.assertEqual(self.claude_calls(), [])
        self.assertIn(cli._fmt_time(NOW + 600), out)


# ---- A3-16 open_cycle / write -------------------------------------------------------------------------------------------
class TestA316OpenCycleWrite(Base):
    def text(self, n=1):
        return sync.machine_file({"claude": {"2026-10-12": {"m": dict(input=n, output=0, cacheRead=0, cacheWrite5m=0,
                                                                         cacheWrite1h=0, turns=1)}}})

    def assert_every_patch_has_fresh_get(self):
        last_get = None
        for e in self.ledger.events:
            if e.kind == "GET":
                last_get = e.t
            if e.kind == "PATCH":
                self.assertTrue(last_get is not None and e.t - last_get <= 120, "PATCH без GET ≤ 120 с")

    def test_one_get_serves_two_patches(self):
        self.need_sync("open_cycle", "write")
        s = sync.open_cycle(auto=True)
        self.assertIsNotNone(s)
        self.assertTrue(sync.write(s, self.text(1)))
        self.clock.advance(60)
        self.assertTrue(sync.write(s, self.text(2)))
        self.assertEqual((len(self.ledger.of("GET")), len(self.ledger.of("PATCH"))), (1, 2))
        self.assertEqual(json.loads(self.gist.current(self.my_file()))["days"]["claude"]["2026-10-12"]["m"]["input"], 2)

    def test_after_120s_a_new_get_is_needed(self):
        self.need_sync("open_cycle", "write")
        s = sync.open_cycle(auto=True)
        sync.write(s, self.text(1))
        self.clock.advance(121)
        sync.write(s, self.text(2))
        self.assert_every_patch_has_fresh_get()

    def test_patch_404_resets_without_discovery(self):
        self.need_sync("open_cycle", "write")
        s = sync.open_cycle(auto=True)
        mark = self.ledger.mark()
        self.gist.patch_script.append(common.Resp(404))
        self.assertFalse(sync.write(s, self.text(1)))
        st = sync.sync_state()
        self.assertIsNone(st.get("gistId"))
        self.assertIsNone(st.get("pushHash"))
        self.assertEqual([e.kind for e in self.ledger.since(mark) if e.kind in ("LIST", "POST")], [],
                         "write() discovery не делает")

    def test_public_gist_is_never_written(self):
        self.need_sync("open_cycle", "write")
        self.gist.public = True
        s = sync.open_cycle(auto=True)
        if s is not None:
            sync.write(s, self.text(1))
        self.assertEqual(self.ledger.of("PATCH"), [], "gist стал public → записи нет")

    def test_sync_lock_is_waited_for_not_skipped(self):
        self.need_sync("open_cycle")
        calls = self.lock_calls()
        sync.open_cycle(auto=True)
        waits = [c for c in calls if c[0] == "sync"]
        self.assertTrue(waits, "open_cycle берёт замок sync")
        for name, blocking, timeout in waits:
            self.assertTrue(blocking, "sync: блокирующе, не пропуск busy (П8-а)")
            self.assertTrue(timeout is not None and 0 < timeout <= 60, "sync: ожидание ≤ 60 с")


# ---- A3-17 O1 journal: 0600, O_APPEND|O_CREAT, rotation, allow-list, no text ---------------------------------------------
class TestA317Journal(Base):
    CODEX = True

    def path(self):
        return os.path.join(common.STATE_DIR, "publisher.jsonl")

    def text(self):
        self.assertTrue(os.path.exists(self.path()), "журнал O1 publisher.jsonl создан проходом")
        with open(self.path(), encoding="utf-8") as f:
            return f.read()

    def test_mode_under_umask_022(self):
        old = os.umask(0o022)
        try:
            with contextlib.suppress(FileNotFoundError):
                os.unlink(self.path())
            self.tick()
        finally:
            os.umask(old)
        self.assertTrue(self.text())
        self.assertEqual(os.stat(self.path()).st_mode & 0o777, 0o600)
        self.assertEqual(os.stat(common.STATE_DIR).st_mode & 0o077, 0, "каталог состояния 0700")

    def test_rotation_drops_old_lines_atomically(self):
        old = json.dumps({"ev": "poll_attempt", "ts": rl.iso(NOW - 50 * DAY), "product": "claude"}) + "\n"
        recent = json.dumps({"ev": "poll_attempt", "ts": rl.iso(NOW - DAY), "product": "claude"}) + "\n"
        with open(self.path(), "w", encoding="utf-8") as f:
            f.write(old * (1100 * 1024 // len(old)) + recent * 50)
        os.chmod(self.path(), 0o600)
        self.tick()
        size = os.path.getsize(self.path())
        self.assertLess(size, 1024 * 1024, "ротация > 1 МБ")
        lines = self.o1()                                       # every line still valid JSON
        self.assertFalse([e for e in lines if ts(e.get("ts")) is not None and ts(e["ts"]) < NOW - 45 * DAY],
                         "строки старше 45 дней отброшены")
        self.assertGreaterEqual(sum(1 for e in lines if ts(e.get("ts")) == NOW - DAY), 50, "свежие строки сохранены")
        self.assertEqual(os.stat(self.path()).st_mode & 0o777, 0o600)

    def test_allow_list_and_no_identity(self):
        self.gist.patch_script.append(common.Resp(500))         # publish failed path too
        self.tick()
        self.clock.advance(1800)
        self.tick()
        text = self.text()
        for e in self.o1():
            self.assertIn(e.get("ev"), rl.O1_EVENTS, e)
            if e.get("ev") in ("poll_skipped", "pass_skipped"):
                self.assertIn(e.get("reason"), rl.SKIP_REASONS, e)
            for k, v in e.items():
                self.assertRegex(k, r"^[A-Za-z][A-Za-z0-9_]{0,31}\Z")
                self.assertTrue(v is None or isinstance(v, (bool, int, float)) or
                                (isinstance(v, str) and SAFE_VALUE.match(v)), "O1 %s=%r — только перечислимое" % (k, v))
        for needle in (rl.U_A, rl.CODEX_ID, rl.U_A.upper()):
            self.assertNotIn(needle, text, "localId не покидает state-файлы — в журнале только метки")
        self.assert_no_sentinel(text, "publisher.jsonl")
        self.assert_no_sentinel(self.publisher_state_text(), "publisher-state.json")

    def test_transport_exception_logged_by_class_only(self):
        marker = "fixture-exception-text-" + "Zq7"
        self.gist.get_script.append(ConnectionResetError(marker))
        pub = self.pub()
        try:
            pub.run_pass("auto")
        except Exception as e:  # noqa: BLE001
            self.fail("run_pass выпустил %r" % e)
        text = self.text()
        self.assertNotIn(marker, text, "текст исключения в журнал не пишется")
        self.assertTrue(text.strip(), "событие прохода записано")
        self.assertFalse(t.quota_locked(), "замок quota снят")


# ---- A3-18 clockSkew from the Date header --------------------------------------------------------------------------------
class TestA318ClockSkew(Base):
    def test_skews(self):
        for skew, event in ((0, False), (59, False), (-59, False), (120, True), (-120, True)):
            with self.subTest(skew=skew):
                self.gist.skew = skew
                n = len(self.o1())
                self.clock.advance(300)
                self.tick()
                st = sync.sync_state()
                st.reload()
                self.assertIsNotNone(st.get("clockSkew"), "clockSkew сохранён в sync-state.json")
                self.assertAlmostEqual(float(st.get("clockSkew")), skew, delta=1.0)
                ev = [e for e in self.o1()[n:] if e.get("ev") == "clock_skew"]
                if event:
                    self.assertTrue(ev, "|skew| > 60 → clock_skew")
                    nums = [v for v in ev[0].values() if isinstance(v, (int, float)) and not isinstance(v, bool)]
                    self.assertTrue(any(abs(abs(v) - abs(skew)) <= 1 for v in nums), "секунды в событии: %r" % ev[0])
                else:
                    self.assertEqual(ev, [], "|skew| ≤ 60 → события нет")


# ---- A3-19 T27 / П8-а: wait for `sync` ≤ 60 s; busy `quota` → pass_skipped busy ----------------------------------------
class TestA319Locks(Base):
    def setUp(self):
        super().setUp()
        self.mono = rl.FakeClock(5000.0)
        self.release = {}
        self.holders = []
        self.patch(time, "monotonic", self.mono)
        self.patch(time, "sleep", self._lock_sleep)
        self.addCleanup(self._close_holders)

    def _lock_sleep(self, seconds):
        self._fake_sleep(seconds)
        self.mono.advance(max(0.0, float(seconds)))
        for fd, at in list(self.release.items()):
            if self.mono() - 5000.0 >= at:
                fcntl.flock(fd, fcntl.LOCK_UN)
                del self.release[fd]

    def hold(self, name, release_after=None):
        path = os.path.join(common.STATE_DIR, name + ".lock")
        fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)     # flock is per open file: conflicts in-process too
        self.holders.append(fd)
        if release_after is not None:
            self.release[fd] = release_after
        return fd

    def _close_holders(self):
        for fd in self.holders:
            with contextlib.suppress(OSError):
                os.close(fd)

    def test_lock_parameters(self):
        calls = self.lock_calls()
        self.tick()
        quota = [c for c in calls if c[0] == "quota"]
        syncs = [c for c in calls if c[0] == "sync"]
        self.assertTrue(quota and all(c[1] and c[2] is not None and 0 < c[2] <= 30 for c in quota), quota)
        self.assertTrue(syncs and all(c[1] and c[2] is not None and 0 < c[2] <= 60 for c in syncs), syncs)

    def test_sync_held_40s_is_waited_for(self):
        self.lock_calls()
        self.hold("sync", release_after=40)
        self.tick()
        self.assertTrue(self.ledger.of("GET"), "40 с: дождался sync и прочитал gist")
        self.assertTrue(self.ledger.of("PATCH"), "и опубликовал")

    def test_sync_held_70s_counts_as_unreadable_gist(self):
        self.lock_calls()
        self.hold("sync")
        self.tick()
        waited = self.mono() - 5000.0
        self.assertGreaterEqual(waited, 55, "ждал около 60 с, а не пропустил как busy")
        self.assertLessEqual(waited, 90)
        self.assertEqual(self.ledger.of("GET") + self.ledger.of("PATCH"), [])
        self.assertEqual(len(self.claude_calls()), 1, "как недоступный gist (P6): своё расписание")

    def test_quota_busy(self):
        self.lock_calls()
        self.hold("quota")
        self.tick()
        self.assertEqual([e.kind for e in self.ledger.events if e.kind in ("GET", "PATCH", "provider")], [])
        self.assertTrue(self.skipped("busy"), "pass_skipped busy")
        self.assertLessEqual(self.mono() - 5000.0, 35, "quota: ожидание ≤ 30 с")


# ---- A3-21 run_pass catches everything, releases the lock, next tick works --------------------------------------------------
class TestA321CatchAll(Base):
    def test_unexpected_exceptions(self):
        pub = self.pub()
        for i, exc in enumerate((KeyError("fixture-key-text"), ValueError("fixture-value-text"))):
            with self.subTest(exc=type(exc).__name__):
                self.clock.now = NOW + i * 7200
                self.providers.replies["claude"].append(exc)
                n = len(self.o1())
                try:
                    pub.run_pass("auto")
                except Exception as e:  # noqa: BLE001
                    self.fail("run_pass выпустил %r" % e)
                self.assertFalse(t.quota_locked(), "замок снят")
                failed = [e for e in self.o1()[n:] if type(exc).__name__ in e.values()]
                self.assertTrue(failed, "в O1 класс события (pass_failed/class)")
                with open(os.path.join(common.STATE_DIR, "publisher.jsonl"), encoding="utf-8") as f:
                    self.assertNotIn("fixture-", f.read(), "без текста исключения")
        self.clock.now = NOW + 3 * 7200
        n = len(self.claude_calls())
        pub.run_pass("auto")
        self.assertEqual(len(self.claude_calls()), n + 1, "следующий тик работает")
        self.assertEqual(ts(self.pubrec().get("asOf")), NOW + 3 * 7200)


# ---- A3-22 (A2 review N3): a successful token write under the old policy is journaled --------------------------------------
class TestA322TokenRefreshLogged(t.Base):
    def token_events(self):
        return [e for e in rl.read_o1() if e.get("ev") == "token_refresh"]

    def test_guarded_rotation_logs_one_event(self):
        for product in ("claude", "codex"):
            with self.subTest(product=product):
                self.reset_round()
                with contextlib.suppress(FileNotFoundError):
                    os.unlink(os.path.join(common.STATE_DIR, "publisher.jsonl"))
                self.set_policy("guarded")
                self.creds(product, "expiring")
                self.attempt(product)
                self.assertTrue(self.trap.posts(), "предусловие: guarded-ротация состоялась")
                ev = self.token_events()
                self.assertEqual(len(ev), 1, "ровно одно token_refresh")
                self.assertEqual(ev[0].get("credentialWrite"), 1)
                self.assertEqual(ev[0].get("policy"), "guarded")

    def test_flush_pending_replay_logs_one_event(self):
        self.need_limits("flush_pending")
        for product in ("claude", "codex"):
            with self.subTest(product=product):
                self.reset_round()
                original = self.make_pending(product)
                self.write_file(self.cred_path(product), original)   # the CLI file is readable again
                self.set_policy("never", reset=False)                 # settings changed by hand meanwhile
                with contextlib.suppress(FileNotFoundError):
                    os.unlink(os.path.join(common.STATE_DIR, "publisher.jsonl"))
                limits.flush_pending()
                with open(self.cred_path(product), "rb") as f:
                    self.assertNotEqual(f.read(), original, "предусловие: replay дописал пару")
                ev = self.token_events()
                self.assertEqual(len(ev), 1, "успешный replay по старой политике журналируется")
                self.assertEqual(ev[0].get("credentialWrite"), 1)
                self.assertEqual(ev[0].get("policy"), "guarded")


# ---- A3-23 (A2 review N4): policy_forced_never on change, not on every call -----------------------------------------------
class TestA323ForcedNeverDedup(t.Base):
    def count(self):
        return t.Base.o1_events(self).count("policy_forced_never")

    def test_thousand_calls_one_event(self):
        self.set_policy("guarded", publisher=True)
        for _ in range(1000):
            self.assertEqual(common.credential_write(), "never")
        self.assertEqual(self.count(), 1, "1000 вызовов → одно событие")
        self.set_policy("guarded", publisher=False)
        self.assertEqual(common.credential_write(), "guarded")
        self.set_policy("guarded", publisher=True)
        common.credential_write()
        common.credential_write()
        self.assertEqual(self.count(), 2, "новое событие только при смене")


# ---- A3-24 (A2 review N4 «O1 с ротацией»): every O1 writer rotates, not only the publisher ----------------------------------
class TestA324PolicyEventRotation(t.Base):
    def test_credential_policy_event_rotates(self):
        path = os.path.join(common.STATE_DIR, "publisher.jsonl")
        old = json.dumps({"ev": "policy_violation", "ts": rl.iso(NOW - 50 * DAY)}) + "\n"
        with open(path, "w", encoding="utf-8") as f:
            f.write(old * (1100 * 1024 // len(old)))
        os.chmod(path, 0o600)
        common.credential_policy_event("pending_rotation_lost", product="claude")
        self.assertLess(os.path.getsize(path), 1024 * 1024)
        events = rl.read_o1()
        self.assertEqual([e.get("ev") for e in events], ["pending_rotation_lost"])
        self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)


# ---- A3-25 (A2 review, П3-б.2): run_pass ends with limits.flush_pending() outside an attempt --------------------------------
class TestA325FlushPendingAtEnd(Base):
    def test_called_once_per_pass_outside_attempt(self):
        seen = []

        def flush_pending():
            seen.append((self.ledger.mark(), getattr(limits._ATTEMPT, "policy", None)))
        self.patch(limits, "flush_pending", flush_pending)
        self.tick()                                           # due pass
        self.assertEqual(len(seen), 1, "flush_pending ровно один раз в конце прохода")
        self.assertGreater(seen[0][0], self.claude_calls()[-1].seq, "после запроса к провайдеру")
        self.assertIsNone(seen[0][1], "вне попытки (_ATTEMPT.policy не выставлена)")
        self.clock.advance(300)
        self.tick()                                           # not due
        self.assertEqual(len(seen), 2)


# ---- A3-26 (A2 review): common.file_lock deadline on time.monotonic --------------------------------------------------------
class TestA326FileLockMonotonic(rl.RLEnv):
    def setUp(self):
        super().setUp()
        common.ensure_dirs()
        self.mono = rl.FakeClock(1000.0)
        self.sleeps = []
        self.wall = [NOW]
        p = mock.patch.object(time, "monotonic", self.mono)
        p.start()
        self.addCleanup(p.stop)
        p = mock.patch.object(time, "sleep", self._sleep)
        p.start()
        self.addCleanup(p.stop)
        self.fd = os.open(os.path.join(common.STATE_DIR, "probe.lock"), os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.addCleanup(os.close, self.fd)

    def _sleep(self, s):
        self.sleeps.append(s)
        if len(self.sleeps) > 200:
            raise AssertionError("дедлайн file_lock не наступает: он считается по стене (time.time), а не monotonic")
        self.mono.advance(s)

    def wall_clock(self, step):
        def now():
            self.wall[0] += step
            return self.wall[0]
        return now

    def test_wall_clock_going_back_does_not_extend_wait(self):
        with mock.patch.object(time, "time", self.wall_clock(-3600)):
            with common.file_lock("probe", timeout=1.0) as held:
                self.assertFalse(held)
        self.assertGreaterEqual(self.mono() - 1000.0, 0.99)
        self.assertLessEqual(self.mono() - 1000.0, 1.5)

    def test_wall_clock_jumping_forward_does_not_cut_wait(self):
        with mock.patch.object(time, "time", self.wall_clock(+3600)):
            with common.file_lock("probe", timeout=1.0) as held:
                self.assertFalse(held)
        self.assertGreaterEqual(self.mono() - 1000.0, 0.99, "прыжок стены вперёд не обрывает ожидание")


# ---- A3-27 (A1 review): accounts.build never raises on overflow; publish without accounts[].days + O1 ------------------------
def counts(n):
    return dict(input=n, output=0, cacheRead=0, cacheWrite5m=0, cacheWrite1h=0, turns=1)


class TestA327BuildOverflow(Base):
    def test_build_drops_days_instead_of_raising(self):
        day, model = "2026-10-12", "claude-opus-5-5"
        entries = [{"product": "claude", "localId": rl.U_A, "status": "ok", "days": {day: {model: counts(9 * 10 ** 14)}}}]
        try:
            block = accounts.build(gist_id=rl.GIST_ID, entries=entries,
                                   unattributed_days={"claude": {day: {model: counts(9 * 10 ** 14)}}}, captions={})
        except ValueError as e:
            self.fail("accounts.build бросил при переполнении: %r" % e)
        self.assertTrue(block["accounts"], "метаданные аккаунтов остаются")
        self.assertTrue(all(a.get("days") == {} for a in block["accounts"]), "accounts[].days отброшены")
        self.assertEqual(block.get("dropped"), "counter_overflow", "признак для журнала O1")

    def test_publisher_logs_and_publishes_without_days(self):
        real = accounts.build

        def overflowing(**kw):
            day, model = "2026-10-12", "claude-opus-5-5"
            kw["entries"] = [dict(e, days={day: {model: counts(1)}}) if isinstance(e, dict) and e.get("localId") else e
                             for e in kw.get("entries") or []]
            kw["unattributed_days"] = {"claude": {day: {model: counts(10 ** 15)}}}
            return real(**kw)
        self.patch(accounts, "build", overflowing)
        self.tick()
        bodies = self.bodies()
        self.assertTrue(bodies, "публикация не остановлена")
        for _e, body in bodies:
            self.assertNotIn("dropped", body, "служебный признак не публикуется")
            self.assertTrue(all(a.get("days") == {} for a in body.get("accounts") or []))
        self.assertIn("accounts_days_dropped", [e.get("ev") for e in self.o1()])


# ---- helpers for hostile big files (A1 review R1/m4, N8, N9) -----------------------------------------------------------------
class BigFiles(Base):
    BIG = "machine-zzzz-big.json"

    def big_raw(self, sha="aaaaaaaaaaaa"):
        url = rl.RAW_ROOT + "owner/g1/raw/" + sha + "/" + self.BIG
        self.gist.put(self.BIG, "{}")
        self.gist.truncated[self.BIG] = url
        self.gist.raw[url] = b"x" * (8 * MiB + 1)
        return url

    def other(self, mid="m-aaaa", **rec):
        return self.foreign(mid, [self.foreign_record(**rec)] if rec else [])


# ---- A3-28 (A1 review R1): coordination treats the gist as read by lastOkAt/res.remote, not res.ok --------------------------
class TestA328PartialReadCoordinates(BigFiles):
    def test_skipped_big_file_does_not_disable_b2(self):
        self.other(attemptAt=rl.iso(NOW - 100))
        self.big_raw()
        self.tick()
        self.assertEqual(self.claude_calls(), [], "gist прочитан частично — чужая попытка 100 с назад соблюдается")
        self.assertTrue(self.skipped("remote_attempt", "claude"))


# ---- A3-29 (A1 review m4): res.partial, `ccl-sync push` without «Sync failed» ------------------------------------------------
class TestA329PartialPush(BigFiles):
    def setUp(self):
        super().setUp()
        self.write_settings(publisher=False)
        self.other()
        self.big_raw()

    def test_result_is_partial(self):
        res = sync.sync_cycle({})
        self.assertTrue(getattr(res, "partial", None) is True, "SyncResult.partial при пропуске большого файла")
        self.assertIn("m-aaaa", [m["id"] for m in (res.remote or {}).get("machines", [])])

    def test_push_exit_code(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            code = cli.main(["push"])
        self.assertEqual(code, 0, out.getvalue())
        for phrase in SYNC_FAILED:
            self.assertNotIn(phrase, out.getvalue(), "частичный проход — не «ошибка синхронизации»")


# ---- A3-30 (A1 review N8): GET /gists/{id} > 16 MiB — own PATCH independent of reading, raw one by one ------------------------
class TestA330HugeGist(BigFiles):
    def test_sync_cycle_falls_back_to_listing_and_raw(self):
        self.write_settings(publisher=False)
        self.other()
        self.gist.too_large = True
        res = sync.sync_cycle({})
        self.assertTrue(self.ledger.of("PATCH"), "собственный PATCH не зависит от чтения чужих файлов")
        self.assertTrue(self.ledger.of("RAW"), "чужие файлы читаются по raw_url по одному")
        self.assertIn("m-aaaa", [m["id"] for m in (res.remote or {}).get("machines", [])])

    def test_open_cycle_still_gives_a_session(self):
        self.need_sync("open_cycle")
        self.other()
        self.gist.too_large = True
        self.assertIsNotNone(sync.open_cycle(auto=True), "сессия есть — публикация возможна")


# ---- A3-31 (A1 review N9, decision Q4): rejected raw_url cache ON DISK (sync-state.json rejectedRaw) -----------------------
class TestA331RejectedRawCache(BigFiles):
    """rejectedRaw = {sha256(raw_url)[:16]: ts of the refusal}; no URL / gist id / revision sha stored (A1-25);
    lifetime 24 h; ≤ 64 entries, the oldest evicted. A VPS timer tick is a new process: only the disk counts."""

    def setUp(self):
        super().setUp()
        self.write_settings(publisher=False)

    @staticmethod
    def key(url):
        import hashlib
        return hashlib.sha256(url.encode("utf-8")).hexdigest()[:16]

    def new_process_cycle(self, auto=True):
        common._state = common._settings = None
        sync._first_attempt_at = None
        return sync.sync_cycle({}, auto=auto)

    def rejected(self):
        st = sync.sync_state()
        st.reload()
        value = st.get("rejectedRaw")
        return value if isinstance(value, dict) else {}

    def test_second_process_does_not_download_again(self):
        url = self.big_raw()
        self.new_process_cycle(auto=False)
        self.assertEqual(len(self.ledger.of("RAW", url=url)), 1)
        self.assertEqual(self.rejected().get(self.key(url)), NOW, "отказ записан в sync-state.json: ключ → ts")
        self.clock.advance(600)
        self.new_process_cycle()
        self.assertEqual(len(self.ledger.of("RAW", url=url)), 1, "новый процесс не качает отвергнутый raw_url")

    def test_cache_lives_on_disk_not_in_memory(self):
        url = self.big_raw()
        self.new_process_cycle(auto=False)
        sync.sync_state().remove("rejectedRaw")               # the disk forgot it → a new process must download again
        self.clock.advance(600)
        self.new_process_cycle()
        self.assertEqual(len(self.ledger.of("RAW", url=url)), 2, "кеш только в памяти процесса не годится (VPS)")

    def test_expires_after_24h(self):
        url = self.big_raw()
        self.new_process_cycle(auto=False)
        self.clock.now = NOW + DAY
        self.new_process_cycle()
        self.assertEqual(len(self.ledger.of("RAW", url=url)), 1, "ровно 24 ч — ещё в кеше")
        self.clock.now = NOW + DAY + 1
        self.new_process_cycle()
        self.assertEqual(len(self.ledger.of("RAW", url=url)), 2, "24 ч + 1 с — качается снова")

    def test_new_revision_is_read(self):
        self.big_raw()
        self.new_process_cycle(auto=False)
        url2 = self.big_raw(sha="bbbbbbbbbbbb")               # a new revision = a new raw_url
        self.clock.advance(600)
        self.new_process_cycle()
        self.assertEqual(len(self.ledger.of("RAW", url=url2)), 1)

    def test_no_url_gist_or_sha_on_disk(self):
        url = self.big_raw()
        self.new_process_cycle(auto=False)
        with open(common.SYNC_STATE_PATH, encoding="utf-8") as f:
            text = f.read()
        self.assertIn(self.key(url), text)
        for needle in (url, "gist.githubusercontent.com", "aaaaaaaaaaaa", "/raw/", self.BIG):
            self.assertNotIn(needle, text, "в sync-state.json не хранится URL/gist id/sha (A1-25)")
        for k, v in self.rejected().items():
            self.assertRegex(k, r"^[0-9a-f]{16}\Z")
            self.assertTrue(isinstance(v, (int, float)) and not isinstance(v, bool))

    def test_at_most_64_entries_oldest_evicted(self):
        old = {"%016x" % i: NOW - 3600 + i for i in range(64)}
        sync.sync_state().update(rejectedRaw=old)
        url = self.big_raw()
        self.new_process_cycle(auto=False)
        got = self.rejected()
        self.assertLessEqual(len(got), 64)
        self.assertIn(self.key(url), got, "новый отказ записан")
        self.assertNotIn("%016x" % 0, got, "вытеснена самая старая запись")


# ---- A3-32 CLI: `push --auto` hook and `publisher` subcommands ------------------------------------------------------------------
class TestA332Cli(Base):
    def run_cli(self, argv):
        out = io.StringIO()
        try:
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out), \
                    mock.patch.object(cli, "_timer_status", return_value="test timer"):
                code = cli.main(argv)
        except SystemExit as e:
            code = e.code
        return code, out.getvalue()

    def recorder(self):
        pub = self.pub()
        calls = []
        self.patch(pub, "run_pass", lambda kind="auto": calls.append(kind))
        return calls

    def test_push_auto_runs_the_pass_when_publisher(self):
        calls = self.recorder()
        with mock.patch.object(sync, "sync_cycle", side_effect=AssertionError("cmd_push не должен гонять sync_cycle")):
            code, out = self.run_cli(["push", "--auto", "--quiet"])
        self.assertEqual(code, 0, out)
        self.assertEqual(calls, ["auto"])

    def test_push_without_publisher_keeps_sync_cycle(self):
        calls = self.recorder()
        self.write_settings(publisher=False)
        code, out = self.run_cli(["push", "--auto", "--quiet"])
        self.assertEqual(calls, [])

    def test_publisher_subcommands(self):
        calls = self.recorder()
        self.assertEqual(self.run_cli(["publisher", "--disable"])[0], 0)
        self.assertIs(common.read_json(common.SETTINGS_PATH, {}).get("publisher"), False)
        self.assertEqual(self.run_cli(["publisher", "--enable"])[0], 0)
        self.assertIs(common.read_json(common.SETTINGS_PATH, {}).get("publisher"), True)
        self.assertEqual(self.run_cli(["publisher", "--now"])[0], 0)
        self.assertEqual(calls, ["manual"])
        code, out = self.run_cli(["publisher", "--status"])
        self.assertEqual(code, 0, out)
        self.assertNotIn(rl.U_A, out)
        self.assert_no_sentinel(out, "publisher --status")


# ---- A3-33 polling.normalize_interval; the publisher imports without PyQt5 ------------------------------------------------------
class TestA333HeadlessImports(unittest.TestCase):
    def test_normalize_interval_moved_to_polling(self):
        from ccl import polling
        fn = getattr(polling, "normalize_interval", None)
        self.assertTrue(callable(fn), "contract: ccl.polling.normalize_interval отсутствует")
        for value, want in ((900, 900), (1800, 1800), (3600, 3600), (14400, 14400), (60, 1800), (300, 1800),
                            ("900", 900), (900.0, 900), ("junk", 1800), (None, 1800), (True, 1800), (10 ** 400, 1800)):
            with self.subTest(value=repr(value)[:20]):
                self.assertEqual(fn(value), want)

    def test_publisher_without_pyqt(self):
        code = ("import sys; sys.path.insert(0, %r); sys.modules['PyQt5'] = None\n"
                "import ccl.publisher, ccl.coordination\nprint('ok')\n") % os.path.dirname(TESTS_DIR)
        env = dict(os.environ, HOME=rl.SANDBOX_HOME)
        for k in ("CONFIG", "STATE", "CACHE", "DATA"):
            env["XDG_%s_HOME" % k] = os.path.join(rl._isolate.ROOT, k.lower())
        r = subprocess.run([sys.executable, "-I", "-c", code], env=env, capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr[-800:])
        self.assertIn("ok", r.stdout)


if __name__ == "__main__":
    unittest.main()
