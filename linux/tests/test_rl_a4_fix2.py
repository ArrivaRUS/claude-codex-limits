"""REMOTE-LIMITS A4 — fix cycle 2 (the last one; docs/plans.md §A4 «Цикл правок A4 №2»). Test-plan IDs A4-21…A4-26.
Sources: docs/security-remote-limits-a4-t2.md (N1, H1, F2, F7, §3 A4-T2-1/A4-T2-2), docs/review-remote-limits-a4.md
r3 (C1, C2, C3), lesson .patches/015 (journal-before-action, kill at EVERY blocking point, the points are listed).
Written BEFORE the fix (red): every red test fails on a missing behaviour, never on its harness (each kill hook checks
that it fired). Tests marked GUARD are green now on purpose: they pin what the fix must keep.

IDs (A4-T2-n = the line of the T2 report §3):
  A4-21 N1 (= A4-T2-1)  two due products, a pass killed INSIDE a provider request after the clock moved by δ (a slow
        first request or a slow PATCH №1). Kill points: (a) the request of the 2nd product after a slow 1st request,
        δ ∈ {300, 600, 1000}; (b) the same on the early path (`_publishFailures = 3`, before GET); (c) the request of the
        2nd product after a slow PATCH №1; (d) the request of the 1st product after a slow PATCH №1. Fixed 900 s
        (`publisher --mode fixed 900`, I = the floor). Expectation: at the moment each provider is CALLED its attempt
        time on disk (state.json mirror / publisher-state.json bucket, the larger one — what a restart loads) equals
        the clock at that call, not the pass reservation; O1 `poll_attempt.attemptAt` of that call = the same time;
        consecutive ACTUAL request starts of a product (ledger time of the call, not `attemptAt`) ≥ max(900, I); the
        killed product is requested again (no starvation by the fix).
  A4-22 C1  every pass is killed during the request of its FIRST product (the request hangs until TimeoutStartSec =
        20 min, then SIGKILL): the other product is still requested — the product with the oldest attempt goes
        first. Variants: healthy gist (normal path), publication always failing (early path after the series).
        This is the kill point «provider request of the first product of a multi-product pass» of the A3-49 list
        (lesson 015); it lives here because the A3-49 harness (KillBase) is Claude-only.
  A4-23 H1 (= A4-T2-2)  the «≥ max(I, 24 h) since the last attempt» branch with a HEALTHY publication: a live
        neighbour keeps a fresh `ok` (fresh_remote) or an attempt in flight (remote_attempt) for my label → 0 requests
        over 25 h (the neighbour checks are not bypassed, sync-protocol «Series limit» belongs to a FAILING
        announcement, T1 П7). GUARD: an unhealthy publication (series `_publishFailures = 1`, PATCH 500) with the same
        neighbour → the 24 h branch still polls before GET, as today. GUARD (existing): A3-49
        `test_24h_branch_polls_before_patch1` (no neighbours, PATCH №1 hangs) stays green.
  A4-24 C2  ordinary install `install.sh --no-tray` (no `--publisher`) → `ccl-sync update` passes `--no-tray`, no
        publisher flags; no menu entry/autostart after the update.
  A4-25 C3/F7  `ccl-sync status` with `machine-id` missing, the config filesystem full (creating machine-id → ENOSPC
        at `os.link`) and the gist read (200): rc 0, no traceback/errno text, the machine list from the gist is
        printed. (When every state write fails too, status degrades before the GET and the crash is unreachable —
        that variant is A4-03 `test_disk_full`; ~/.config and ~/.local/state may live on different filesystems.)
  A4-26 F2  `DEST` (from XDG_DATA_HOME) with a space, `%`, `'`, `$VAR`, `${VAR}`, `$(…)`, backquotes: the tray/ccl-sync
        wrapper, the cron line (cron mode) and `ExecStart` (systemd mode) run exactly `<python> <DEST>/ccl-sync …`
        (one argument, byte-exact path), and nothing is executed from the path. Space and `'` are GUARD in systemd
        mode (green now). Cron mode is red for every vector for one more reason found here (A4-26b, not in T2/r3):
        with no prior crontab install.sh writes an EMPTY crontab (`set -e` + `grep -v` exit 1 in the subshell), see
        `test_cron_line_written_without_prior_crontab_and_kept_once_on_reinstall`.

Contract choices (tester, the sources are silent):
  * A4-21: «attempt time on disk» = max(state.json `autoPollState.<p>.last_attempt`, publisher-state.json
    `<p>.accounts.<id>.poll.last_attempt`) — the value `_load_product` restores. The gist `attemptAt` (announcement) is
    not checked: T2 leaves it as the reservation time until C4.
  * A4-22: the fake clock moves 10 ms per state-file write (a real clock always moves between the reservation and a
    request), so equal timestamps are not a fake-clock artefact either way. Bound: each product requested at least
    once per 3·(I + 1200 + 300) s.
  * A4-26: `ExecStart` is read the way systemd reads it — specifiers first (`%%` → `%`, any other `%x` changes the
    path), then words with "…"/'…' quoting and C escapes, then `$$` → `$`, `${VAR}`/`$VAR` → environment. DEST must be
    literal in ExecStart (no Environment= indirection). The cron line is read the way cron reads it (`\\%` → `%`, an
    unescaped `%` ends the command) and run by `sh -c` with the python path replaced by an argv recorder. Escaping, not
    refusal: install.sh must accept these paths (rc 0).
Run: cd linux && python3 -m unittest tests.test_rl_a4_fix2 -v   (≈ 30 s; no network, no real systemctl, no sleeps)
"""

if __package__:
    from . import _rl_env as rl
    from . import test_rl_install as ti
else:
    import _rl_env as rl
    import test_rl_install as ti

import json
import os
import re
import shutil
import subprocess
import tempfile
import time
import unittest

from ccl import common

NOW = rl.NOW
DAY = 86400
TICK = 300
FLOOR = 900
HANG = 1200                       # TimeoutStartSec=20min: a hung request is killed after it


def tearDownModule():
    rl.assert_real_files_untouched()


def PS():
    return os.path.join(common.STATE_DIR, "publisher-state.json")


def _num(v):
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) else None


# ==================================================================================================================
# Publisher harness: PubEnv with Claude + Codex, fake monotonic following the wall clock, provider hooks.
# ==================================================================================================================
class TwoProducts(rl.PubEnv):
    CODEX = True

    def setUp(self):
        super().setUp()
        self.patch(time, "monotonic", lambda: self.clock.now - NOW + 10000.0)
        self.patch(os, "fsync", lambda fd: None)                 # kills are simulated per write_atomic call
        self.write_settings(autoPoll=False, interval=FLOOR)
        self.at_call = []           # (product, clock at the call, attempt time on disk at the call)
        self.behaviour = None       # callable(product, call_index_in_pass) run inside the request
        self.pass_calls = 0
        self.kills = []
        self.providers.on_call = self._on_call

    # ---- disk ----
    def local_id(self, product):
        return self.CLAUDE_ID if product == "claude" else rl.CODEX_ID

    def disk_attempt(self, product):
        st = common.read_json(common.STATE_PATH, {}) or {}
        mirror = ((st.get("autoPollState") or {}).get(product) or {})
        a = _num(mirror.get("last_attempt")) if mirror.get("accountId", self.local_id(product)) == self.local_id(
            product) else None
        ps = common.read_json(PS(), {}) or {}
        bucket = (((ps.get(product) or {}).get("accounts") or {}).get(self.local_id(product)) or {})
        b = _num((bucket.get("poll") or {}).get("last_attempt"))
        return max([x for x in (a, b) if x is not None] or [0.0])

    def seed_failures(self, n):
        saved = common.read_json(PS(), {}) or {}
        saved["_publishFailures"] = n
        common.write_json(PS(), saved)

    # ---- provider hook ----
    def _on_call(self, product):
        self.at_call.append((product, self.clock.now, self.disk_attempt(product)))
        index = self.pass_calls
        self.pass_calls += 1
        if self.behaviour:
            self.behaviour(product, index)

    def die(self, where):
        self.kills.append((where, self.clock.now))
        self.ledger.dead = True
        raise rl.Kill()

    def pass_at(self, at):
        """One pass in a fresh process at wall time `at`; a killed pass ends like SIGKILL."""
        self.clock.now = at
        self.pass_calls = 0
        self.tick()
        self.restart()
        return self.clock.now

    def starts(self, product):
        return [e.t for e in self.providers.calls(product)]


# ==== A4-21 (N1 = A4-T2-1): the attempt is journalled right before EACH provider call =================================
class TestA421AttemptAtRequestStart(TwoProducts):
    def run_case(self, delay, where="first_request", kill="codex", early=False):
        self.pass_at(NOW)                                         # both products polled at NOW (baseline)
        self.assertEqual((len(self.starts("claude")), len(self.starts("codex"))), (1, 1), "предусловие: оба опрошены")
        if early:
            self.seed_failures(3)
        t0 = NOW + FLOOR
        first = {"done": False}

        def behaviour(product, index):
            if where == "first_request" and index == 0:
                self.clock.advance(delay)                        # a slow first request (DNS, slow body…)
            if product == kill and not first["done"]:
                first["done"] = True
                self.die("request:" + product)                   # killed while this request is in flight
        self.behaviour = behaviour
        if where == "patch1":
            self.gist.patch_script[:] = [lambda rec: (self.clock.advance(delay), None)[1]]
        mark = len(self.at_call)
        o1_mark = len(self.o1())
        self.pass_at(t0)
        self.gist.patch_script[:] = []
        self.behaviour = None
        self.assertTrue(self.kills, "стенд: проход не убит внутри запроса %s" % kill)
        killed = [c for c in self.at_call[mark:] if c[0] == kill][-1]
        _p, started, on_disk = killed
        self.assertEqual(started, t0 + delay, "стенд: убитый запрос стартовал через δ после резерва")
        # 1) the attempt on disk at the moment of the call = the call time (journal-before-action per product)
        self.assertEqual(on_disk, started,
                         "N1: в момент вызова провайдера %s на диске время попытки %+.0f с от старта запроса (резерв "
                         "прохода t0, а не время перед вызовом; δ = %d с)" % (kill, on_disk - started, delay))
        # 2) O1 poll_attempt.attemptAt of the killed call = its start
        attempts = [e for e in self.o1()[o1_mark:] if e.get("ev") == "poll_attempt" and e.get("product") == kill]
        self.assertTrue(attempts, "стенд: нет poll_attempt %s в O1" % kill)
        self.assertEqual(attempts[-1].get("attemptAt"), started,
                         "N1: poll_attempt.attemptAt = время резерва (%+.0f с от старта), скрипт G1 по attemptAt "
                         "спрячет короткий зазор" % ((attempts[-1].get("attemptAt") or 0) - started))
        # 3) the next ACTUAL request pairs stay ≥ the floor; the product is requested again
        at = self.clock.now
        while at <= t0 + 3 * 3600:
            at = max(self.pass_at(at + TICK), at + TICK)
        for product in ("claude", "codex"):
            s = self.starts(product)
            gaps = [round(b - a) for a, b in zip(s, s[1:])]
            self.assertTrue(all(g >= FLOOR for g in gaps),
                            "N1: пара фактических запросов %s ближе пола 900 с: старты (от NOW) %r, зазоры %r"
                            % (product, [round(x - NOW) for x in s], gaps))
        later = [x for x in self.starts(kill) if x > started]
        self.assertTrue(later, "после убитого запроса %s больше не опрашивается (3 ч)" % kill)
        self.assertGreaterEqual(later[0] - started, FLOOR)

    def test_slow_first_request_300_kill_second(self):
        self.run_case(300)

    def test_slow_first_request_600_kill_second(self):
        self.run_case(600)

    def test_slow_first_request_1000_kill_second(self):
        self.run_case(1000)

    def test_early_path_slow_first_request_600_kill_second(self):
        self.run_case(600, early=True)

    def test_slow_patch1_300_kill_second(self):
        self.run_case(300, where="patch1")

    def test_slow_patch1_300_kill_first(self):
        self.run_case(300, where="patch1", kill="claude")


# ==== A4-22 (C1): a pass killed in its FIRST request every time must not silence the other product ===================
class TestA422FirstRequestKilledEveryPass(TwoProducts):
    I = 1800

    def setUp(self):
        super().setUp()
        self.write_settings(autoPoll=False, interval=self.I)
        inner = common.write_atomic
        clock = self.clock

        def write_atomic(path, data, mode=0o600):
            r = inner(path, data, mode)
            if os.path.basename(path) in rl.STATE_FILES:
                clock.advance(0.01)                              # a real clock moves between writes
            return r
        self.patch(common, "write_atomic", write_atomic)

    def series(self, failing_gist):
        self.pass_at(NOW)                                         # baseline, no kills
        self.assertEqual((len(self.starts("claude")), len(self.starts("codex"))), (1, 1), "предусловие: оба опрошены")
        n0 = {p: len(self.starts(p)) for p in ("claude", "codex")}

        def behaviour(product, index):
            if index == 0:
                self.clock.advance(HANG)                         # hangs until TimeoutStartSec
                self.die("first:" + product)
        self.behaviour = behaviour
        begin, end = NOW + TICK, NOW + DAY
        at = begin
        while at <= end:
            if failing_gist:
                self.gist.patch_script[:] = [common.Resp(500)] * 8
            nxt = self.pass_at(at)
            self.gist.patch_script[:] = []
            at = max(at + TICK, nxt)
        self.assertTrue(self.kills, "стенд: точка «запрос первого продукта» ни разу не сработала")
        bound = 3 * (self.I + HANG + TICK)
        for product in ("claude", "codex"):
            s = [x for x in self.starts(product)[n0[product]:]]
            self.assertTrue(s, "C1: каждый проход убит в запросе первого продукта — %s за сутки не запрошен ни разу "
                               "(первым всегда идёт %s; убийства: %r)"
                            % (product, self.kills[0][0].split(":")[1], sorted({k for k, _t in self.kills})))
            edges = [begin] + s + [end]
            gaps = [b - a for a, b in zip(edges, edges[1:])]
            self.assertLessEqual(max(gaps), bound, "C1: %s молчит дольше 3·(I + 20 мин + тик): max %.0f с, запросов %d"
                                 % (product, max(gaps), len(s)))

    def test_healthy_gist(self):
        self.series(failing_gist=False)

    def test_failing_publication_early_path(self):
        self.series(failing_gist=True)


# ==== A4-23 (H1 = A4-T2-2): the 24 h branch does not bypass the neighbour checks while publication is healthy =========
class TestA423DayBranchHealthyPublication(rl.PubEnv):
    def setUp(self):
        super().setUp()
        self.patch(os, "fsync", lambda fd: None)                 # 300 passes; fsync only costs wall time here

    def neighbour(self, kind, now):
        if kind == "fresh_remote":
            rec = self.foreign_record(asOf=rl.iso(now - 60),
                                      schedule={"mode": "auto", "interval": 900, "nextAt": rl.iso(now - 60 + 900)})
        else:                                                    # remote_attempt: an attempt in flight, no reading
            rec = self.foreign_record(status="error", attemptAt=rl.iso(now - 100),
                                      schedule={"mode": "auto", "interval": 900, "nextAt": rl.iso(now - 100 + 900)})
        self.foreign("peer-0001", [rec])

    def run_day(self, kind):
        self.tick()
        self.assertEqual(len(self.providers.calls("claude")), 1, "предусловие: свой опрос в NOW")
        o1_mark = len(self.o1())
        extra = []
        for _ in range(int(25 * 3600 / TICK)):
            now = self.clock.advance(TICK)
            self.neighbour(kind, now)
            before = len(self.providers.calls("claude"))
            self.tick()
            if len(self.providers.calls("claude")) > before:
                extra.append(round(now - NOW))
        skips = [e.get("reason") for e in self.o1()[o1_mark:] if e.get("ev") == "poll_skipped"]
        self.assertIn(kind, skips, "стенд: координация с соседом не сработала (%s); пропуски: %r"
                      % (kind, sorted(set(skips))))
        failures = (common.read_json(PS(), {}) or {}).get("_publishFailures")
        self.assertIn(failures, (0, None), "стенд: публикация здорова (_publishFailures = %r)" % failures)
        self.assertEqual(extra, [], "H1: gist здоров, живой сосед держит %s для моей метки — опрос по ветке «≥ max(I, "
                                    "24 ч)» в обход координации (с от NOW): %r" % (kind, extra))

    def test_fresh_remote_neighbour_no_poll_for_25h(self):
        self.run_day("fresh_remote")

    def test_remote_attempt_neighbour_no_poll_for_25h(self):
        self.run_day("remote_attempt")

    def test_failing_publication_day_branch_still_polls(self):  # GUARD: previous behaviour for an unhealthy series
        self.tick()
        self.assertEqual(len(self.providers.calls("claude")), 1)
        saved = common.read_json(PS(), {}) or {}
        saved["_publishFailures"] = 1
        common.write_json(PS(), saved)
        now = self.clock.advance(DAY + 1)
        self.neighbour("fresh_remote", now)
        self.gist.patch_script[:] = [common.Resp(500)] * 8
        mark = self.ledger.mark()
        self.tick()
        ev = self.ledger.since(mark)
        calls = [e for e in ev if e.kind == "provider" and e.product == "claude"]
        self.assertEqual(len(calls), 1, "серия publish_failed (1 на диске), PATCH 500, ≥ 24 ч с попытки: ветка 24 ч "
                                        "опрашивает, как сейчас (sync-protocol «Series limit»)")
        gets = [e for e in ev if e.kind == "GET"]
        self.assertTrue(not gets or calls[0].seq < gets[0].seq, "запрос до GET (ранний путь)")


# ==================================================================================================================
# Installer / update / status
# ==================================================================================================================
class TestA424OrdinaryNoTrayKeptByUpdate(ti._A416Base):
    """C2: `install.sh --no-tray` without `--publisher`, then `ccl-sync update`."""

    def test_update_passes_no_tray_and_creates_no_entries(self):
        r = ti.run_install(self.fresh(), ["--no-tray"], settings=json.dumps({"lang": "en"}).encode())
        self.assertEqual(r.rc, 0, "подготовка: обычная установка --no-tray:\n" + r.out[-1500:])
        self.assertEqual([p for p in ti.ui_files(r) if os.path.exists(p)], [], "предусловие: --no-tray без ярлыков")
        u = ti.run_update(r, self.tarball)
        self.assertEqual(u.rc, 0, u.out[-1500:])
        self.assertEqual(len(u.installer), 1, u.installer)
        argv = u.installer[0]
        self.assertIn("--no-tray", argv, "C2: обычная установка --no-tray, update не передаёт --no-tray (выбор не "
                                         "сохранён); флаги: %r" % (argv,))
        for flag in ("--publisher", "--name"):
            self.assertNotIn(flag, argv, "обычная машина: %s не передаётся; флаги: %r" % (flag, argv))
        self.assertEqual([p for p in ti.ui_files(r) if os.path.exists(p)], [],
                         "C2: после update появился ярлык меню/автозапуск у установки --no-tray")
        obj = json.loads(ti.settings_of(r))
        self.assertNotEqual(obj.get("publisher"), True, "обычная установка не становится издателем")
        self.assertEqual(obj.get("lang"), "en")


class TestA425StatusNoMachineIdDiskFull(ti.A4Env):
    """C3/F7 (cli.py:512): the second machine_id() of `status` while the machine-id is missing and cannot be created
    (config filesystem full); state writes and the gist read work."""

    def test_status_without_machine_id_on_full_disk(self):
        self.foreign("peer-0001", [], name="machine-peer-0001.json")
        self.tick()                                              # my own machine file is in the gist too
        if os.path.exists(common.MACHINE_ID_PATH):
            os.unlink(common.MACHINE_ID_PATH)

        def enospc(*a, **kw):
            raise OSError(28, "No space left on device")
        self.patch(os, "link", enospc)
        mark = self.ledger.mark()
        code, out = self.run_cli(["status"])
        gets = [e for e in self.ledger.since(mark) if e.kind == "GET"]
        self.assertTrue(gets, "стенд: status не прочитал gist (ветка разбора машин gist не достигнута):\n" + out[-800:])
        self.assertFalse(os.path.exists(common.MACHINE_ID_PATH), "стенд: machine-id не создан (диск полон)")
        self.assertEqual(code, 0, "C3/F7: status без machine-id на полном диске упал (rc %r):\n%s" % (code, out[-800:]))
        for bad in ("Traceback", "Errno", "No space left", "OSError"):
            self.assertNotIn(bad, out, "в status текст исключения: %r" % bad)
        self.assertRegex(out, r"(?m)^\s*Machines in the gist:", "список машин из gist напечатан")
        self.assertRegex(out, r"(?m)^\s*•\s*other\b", "чужая машина в списке")


# ---- A4-26 (F2) helpers ----------------------------------------------------------------------------------------------
_CESC = {"a": "\a", "b": "\b", "f": "\f", "n": "\n", "r": "\r", "t": "\t", "v": "\v", "s": " ",
         "\\": "\\", '"': '"', "'": "'"}


class UnitParseError(ValueError):
    pass


def _cunescape(s, i):
    """systemd C escape at s[i] == '\\' → (char, next index)."""
    if i + 1 >= len(s):
        raise UnitParseError("trailing backslash")
    c = s[i + 1]
    if c in _CESC:
        return _CESC[c], i + 2
    if c == "x" and re.fullmatch(r"[0-9a-fA-F]{2}", s[i + 2:i + 4]):
        return chr(int(s[i + 2:i + 4], 16)), i + 4
    if c in "01234567" and re.fullmatch(r"[0-7]{3}", s[i + 1:i + 4]):
        return chr(int(s[i + 1:i + 4], 8)), i + 4
    if c == "u" and re.fullmatch(r"[0-9a-fA-F]{4}", s[i + 2:i + 6]):
        return chr(int(s[i + 2:i + 6], 16)), i + 6
    raise UnitParseError("unknown escape \\%s" % c)


def systemd_exec_argv(value, env):
    """argv systemd runs for `ExecStart=value` (see the module docstring)."""
    out, i = [], 0
    while i < len(value):                                        # 1) specifiers
        if value[i] == "%":
            if value[i + 1:i + 2] == "%":
                out.append("%")
                i += 2
                continue
            out.append("<specifier %%%s>" % value[i + 1:i + 2])  # systemd would substitute: the path changes
            i += 2
            continue
        out.append(value[i])
        i += 1
    s = "".join(out)
    words, i = [], 0                                             # 2) words, quotes, C escapes
    while i < len(s):
        while i < len(s) and s[i] in " \t":
            i += 1
        if i >= len(s):
            break
        word, quote = [], None
        while i < len(s):
            c = s[i]
            if quote:
                if c == quote:
                    quote = None
                    i += 1
                elif c == "\\":
                    ch, i = _cunescape(s, i)
                    word.append(ch)
                else:
                    word.append(c)
                    i += 1
            elif c in " \t":
                break
            elif c in "\"'":
                quote = c
                i += 1
            elif c == "\\":
                ch, i = _cunescape(s, i)
                word.append(ch)
            else:
                word.append(c)
                i += 1
        if quote:
            raise UnitParseError("unbalanced quote")
        words.append("".join(word))

    def env_sub(w):                                              # 3) $$, ${VAR}, $VAR
        r, j = [], 0
        while j < len(w):
            if w[j] == "$":
                if w[j + 1:j + 2] == "$":
                    r.append("$")
                    j += 2
                    continue
                m = re.match(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)", w[j:])
                if m:
                    r.append(env.get(m.group(1) or m.group(2), ""))
                    j += m.end()
                    continue
            r.append(w[j])
            j += 1
        return "".join(r)
    return [env_sub(w) for w in words]


def cron_command(line):
    """The command cron gives to `sh -c` for a crontab line (5 time fields; `\\%` → `%`, `%` ends the command)."""
    fields = line.split(None, 5)
    if len(fields) < 6:
        raise UnitParseError("not a crontab line: %r" % line)
    cmd, i, out = fields[5], 0, []
    while i < len(cmd):
        if cmd[i] == "\\" and cmd[i + 1:i + 2] == "%":
            out.append("%")
            i += 2
            continue
        if cmd[i] == "%":
            break
        out.append(cmd[i])
        i += 1
    return "".join(out)


F2_VECTORS = (
    ("пробел (GUARD)", "my data"),
    ("одинарная кавычка (GUARD)", "it's"),
    ("% (спецификатор systemd, конец команды cron)", "d%h%%x"),
    ("$VAR", "d$HOME"),
    ("${VAR}", "d${HOME}x"),
    ("$(…)", "d$(touch pwned)"),
    ("обратные кавычки", "d`touch pwned`"),
)


class TestA426DestEscaping(unittest.TestCase):
    """F2: DEST = $XDG_DATA_HOME/claude-codex-limits with shell/systemd/cron metacharacters."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ccl-a4-26-", dir="/tmp")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.recorder = os.path.join(self.tmp, "argv-recorder")
        self.argv_out = os.path.join(self.tmp, "argv.out")
        with open(self.recorder, "w") as f:
            f.write('#!/bin/sh\n: > "%s"\nfor a in "$@"; do printf \'%%s\\0\' "$a" >> "%s"; done\n'
                    % (self.argv_out, self.argv_out))
        os.chmod(self.recorder, 0o755)

    def install(self, root, data_home, cron=False):
        home = os.path.join(root, "home")
        os.makedirs(home, exist_ok=True)
        fb, log = ti.make_fakebin(root)
        if cron:                                                 # no systemd --user session → cron branch
            with open(os.path.join(fb, "systemctl"), "w") as f:
                f.write("#!/bin/sh\nexit 1\n")
            with open(os.path.join(fb, "crontab"), "w") as f:     # a crontab that keeps what it is given
                f.write('#!/bin/sh\nT="%s/crontab.txt"\nif [ "$1" = "-l" ]; then [ -f "$T" ] || exit 1; cat "$T"; '
                        'exit 0; fi\ncat > "$T.new" && mv "$T.new" "$T"\n' % root)
        dead = "http://127.0.0.1:9"
        env = {"HOME": home, "PATH": fb + ":/usr/bin:/bin", "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8",
               "USER": "ccltest", "LOGNAME": "ccltest", "DBUS_SESSION_BUS_ADDRESS": "disabled:",
               "http_proxy": dead, "https_proxy": dead, "PYTHONDONTWRITEBYTECODE": "1", "XDG_DATA_HOME": data_home}
        p = subprocess.run(["sh", ti.INSTALL, "--publisher", "--no-tray", "--name", "vps"], env=env, cwd=root,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
        return p.returncode, p.stdout.decode("utf-8", "replace"), home, env

    def recorded(self, script_text, cwd, env, args=()):
        """Run `script_text` with the python path replaced by the argv recorder → argv after the interpreter."""
        if os.path.exists(self.argv_out):
            os.unlink(self.argv_out)
        self.assertIn("/usr/bin/python3", script_text, "стенд: в команде нет системного python")
        text = script_text.replace("/usr/bin/python3", self.recorder, 1)
        subprocess.run(["sh", "-c", text, "sh"] + list(args), env=env, cwd=cwd, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, timeout=30)
        try:
            with open(self.argv_out, "rb") as f:
                raw = f.read()
        except FileNotFoundError:
            return None
        return [a.decode("utf-8", "replace") for a in raw.split(b"\0")[:-1]]

    def pwned(self, *dirs):
        return [os.path.join(d, n) for d in dirs for n in ("pwned",) if os.path.exists(os.path.join(d, n))]

    def check_vector(self, label, leaf, cron):
        root = tempfile.mkdtemp(prefix="v-", dir=self.tmp)
        data_home = os.path.join(root, leaf)
        dest = os.path.join(data_home, "claude-codex-limits")
        script = os.path.join(dest, "ccl-sync")
        rc, out, home, env = self.install(root, data_home, cron=cron)
        self.assertEqual(rc, 0, "%s: install.sh отказал на DEST %r:\n%s" % (label, dest, out[-1200:]))
        self.assertTrue(os.path.isfile(script), "%s: код не скопирован в DEST" % label)
        run_env = {"HOME": home, "PATH": "/usr/bin:/bin", "LANG": "C.UTF-8"}
        run_dir = os.path.join(root, "cwd")
        os.makedirs(run_dir)
        # wrapper ~/.local/bin/ccl-sync
        with open(os.path.join(home, ".local", "bin", "ccl-sync")) as f:
            wrapper = f.read()
        argv = self.recorded(wrapper, run_dir, run_env, args=("push", "a b"))
        self.assertIsNotNone(argv, "%s: обёртка не дошла до python:\n%s" % (label, wrapper))
        self.assertIn(script, argv, "%s: обёртка передаёт python не тот путь: %r вместо %r" % (label, argv, script))
        self.assertEqual(argv[argv.index(script):], [script, "push", "a b"], "%s: обёртка: %r" % (label, argv))
        if cron:
            with open(os.path.join(root, "crontab.txt")) as f:
                lines = [ln for ln in f.read().splitlines() if "ccl-sync" in ln]
            self.assertEqual(len(lines), 1, "%s: строка cron: %r" % (label, lines))
            argv = self.recorded(cron_command(lines[0]), run_dir, run_env)
            self.assertIsNotNone(argv, "%s: строка cron не дошла до python: %r" % (label, lines[0]))
            self.assertEqual(argv, [script, "push", "--auto", "--quiet"], "%s: cron запускает %r" % (label, argv))
        else:
            service = ti.unit(ti.Install(rc, out, home, root, None, os.path.join(home, ".config")), "ccl-sync.service")
            self.assertIsNotNone(service, "%s: нет ccl-sync.service" % label)
            execs = service.get("ExecStart", [])
            self.assertEqual(len(execs), 1, execs)
            try:
                argv = systemd_exec_argv(execs[0], {"HOME": home, "USER": "ccltest"})
            except UnitParseError as e:
                self.fail("%s: ExecStart не разбирается systemd (%s): %s" % (label, e, execs[0]))
            self.assertEqual(argv, ["/usr/bin/python3", script, "push", "--auto", "--quiet"],
                             "%s: systemd запустит %r (ExecStart=%s)" % (label, argv, execs[0]))
        self.assertEqual(self.pwned(run_dir, root, home), [], "%s: из пути DEST исполнена команда" % label)

    def test_systemd_mode(self):
        for label, leaf in F2_VECTORS:
            with self.subTest(label):
                self.check_vector(label, leaf, cron=False)

    def test_cron_mode(self):
        for label, leaf in F2_VECTORS:
            with self.subTest(label):
                self.check_vector(label, leaf, cron=True)

    def test_cron_line_written_without_prior_crontab_and_kept_once_on_reinstall(self):
        """Found while writing A4-26 (not in T2/r3): `( crontab -l | grep -v … ; printf LINE ) | crontab -` runs under
        `set -eu`; with no crontab (or only the ccl-sync line) `grep -v` exits 1, the subshell stops before `printf`,
        and an EMPTY crontab is installed while install.sh prints «Таймер: cron». The cron fallback never gets its line;
        a reinstall deletes it."""
        root = tempfile.mkdtemp(prefix="v-", dir=self.tmp)
        data_home = os.path.join(root, "plain")
        for n in (1, 2):
            rc, out, _home, _env = self.install(root, data_home, cron=True)
            self.assertEqual(rc, 0, out[-1200:])
            self.assertIn("cron", out, "стенд: ветка cron")
            with open(os.path.join(root, "crontab.txt")) as f:
                lines = [ln for ln in f.read().splitlines() if "ccl-sync" in ln]
            self.assertEqual(len(lines), 1, "установка №%d в режиме cron (без прежнего crontab): строк ccl-sync %d — "
                                            "установлен пустой crontab, таймера нет" % (n, len(lines)))

if __name__ == "__main__":
    unittest.main(verbosity=2)
