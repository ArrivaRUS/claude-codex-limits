"""REMOTE-LIMITS A3-20 — two-machine simulator, 24 h of virtual time (synth v2 §C budget table, §D «Допуск», T1 П7 И1–И4).
Written BEFORE the code (red: ccl.publisher is missing).

Harness: `_rl_sim.Sim` (see its docstring). Each timer tick (5 min) of each machine is a new process running
publisher.run_pass("auto"). Both machines are signed in to the same Claude account (U_A) and Codex account (CODEX_ID).
Provider truth depends on true time: «active» = +1.5 pp per 15 min (Auto falls to 15 min), «idle» = constant (Auto climbs
to 4 h). Pair = two consecutive requests for one account (any machines) closer than 900 s of true time.

Grid (test plan A3-20): I ∈ {15 min, 4 h} × visibility delay × skew; phase of machine 2 = 137 s (seeded, fixed).
A 5-min visibility delay cannot give «0 pairs» under the synth's 60-s margins — a recorded open question (skipped with
the reason), not a silent omission; delay 30 s + skew ±59 s holds only at the fixed phase (see the grid comment).
Run: cd linux && python3 -m unittest tests.test_rl_sim -v
"""

if __package__:
    from . import _rl_env as rl
    from . import _rl_sim as simmod
else:
    import _rl_env as rl
    import _rl_sim as simmod

import random
import unittest

from ccl import common

DAY = 86400
H = 3600
WARMUP = 2 * H
PRODUCTS = ("claude", "codex")
BUDGET = {"active": (288, 528), "idle": (288, 168)}   # synth §C table, per machine per day: GET, PATCH (upper bound)


def tearDownModule():
    rl.assert_real_files_untouched()


class SimBase(rl.PubEnv):
    CODEX = True

    def sim(self, mode="active", delay=0.0):
        self.pub()                                   # red: contract missing → one clear failure, not a crash
        return simmod.Sim(self, mode=mode, delay=delay)

    def assert_clean(self, s):
        self.assertEqual(s.errors(), [], "run_pass выпустил исключение")

    def assert_budget(self, s, mode):
        get_cap, patch_cap = BUDGET[mode]
        for m in s.machines:
            gets, patches = s.count("GET", m.name), s.count("PATCH", m.name)
            self.assertLessEqual(gets, get_cap + 2, "%s: GET/сутки %d > таблицы §C" % (m.name, gets))
            self.assertLessEqual(patches, patch_cap, "%s: PATCH/сутки %d > таблицы §C (%s)" % (m.name, patches, mode))


# ---- A3-20(a) steady state: 0 pairs, budget within the §C table -----------------------------------------------------------
class TestA320aSteadyState(SimBase):
    def steady(self, mode, delay, skew):
        s = self.sim(mode, delay)
        s.add(phase=0)
        s.add(phase=137, skew=skew)
        s.run(24)
        self.assert_clean(s)
        for p in PRODUCTS:
            self.assertEqual(s.pairs(p, since=WARMUP), [], "%s: пары < 900 с в установившемся режиме" % p)
            self.assertLessEqual(len(s.pairs(p, until=WARMUP)), 1, "%s: старт — не больше 1 пары" % p)
            self.assertTrue(s.requests(p), "%s: аккаунт вообще опрашивается" % p)
        self.assert_budget(s, mode)

    @unittest.skip("open question (report): a 5-min visibility delay exceeds the synth's 60-s margin — a correct "
                   "implementation pairs every period (reference probe: 71 steady pairs/day); the test plan's «0 pairs» "
                   "for this cell needs a decision (wider margin, read-before-poll, or drop the cell)")
    def test_delay_5min(self):
        for mode in ("active", "idle"):
            self.steady(mode, 300, 0)


# Phase 137 s is fixed: with delay 30 s + |skew| 59 s the outcome depends on the phase (pairs when the other machine's
# tick lands < delay + |skew| − 60 s after an attempt); 137 s is outside that band — recorded in the report.
for _mode, _delay, _skew in (("active", 0, 0), ("active", 0, 59), ("active", 0, -59), ("active", 30, 0),
                             ("active", 30, 59), ("active", 30, -59),
                             ("idle", 0, 0), ("idle", 30, 0), ("idle", 0, -59)):
    setattr(TestA320aSteadyState, "test_%s_delay%d_skew%s" % (_mode, _delay, str(_skew).replace("-", "m")),
            lambda self, m=_mode, d=_delay, k=_skew: self.steady(m, d, k))


# ---- A3-20(b) one machine idle 12 h → interval 4 h, ≤ 10 requests a day ------------------------------------------------------
class TestA320bIdleSolo(SimBase):
    def test_idle_day(self):
        s = self.sim("idle")
        s.add(phase=0)
        s.run(24)
        self.assert_clean(s)
        for p in PRODUCTS:
            n = len(s.requests(p))
            self.assertGreaterEqual(n, 1)
            self.assertLessEqual(n, 10, "%s: простой → интервал 4 ч, ≤ 10 запросов/сутки" % p)
            gaps = [b.t - a.t for a, b in zip(s.requests(p), s.requests(p)[1:])]
            self.assertTrue(gaps and max(gaps) >= 4 * H, "%s: Auto дошёл до 4 ч" % p)
        self.assert_budget(s, "idle")


# ---- A3-20(c) T24 fuzz of foreign files: И1 (≤ solo Auto), ≥ 1 request per max(I, 24 h) on garbage/future fields --------------
class TestA320cFuzz(SimBase):
    HOSTILE = "machine-ffffffff-ffff-4fff-8fff-ffffffffffff.json"

    def solo(self, hours):
        s = self.sim("idle")
        s.add(phase=0)
        s.run(hours, extra=600)
        self.assert_clean(s)
        return {p: len(s.requests(p)) for p in PRODUCTS}

    def hostile_writer(self, rnd, garbage_only):
        def write(sim, m):
            now = sim.true
            labels = {p: self.label(p) for p in PRODUCTS}

            def t_any():
                return rnd.choice([None, "garbage", rl.iso(now - rnd.uniform(0, 3 * H)), rl.iso(now - 959),
                                   rl.iso(now - 30), rl.iso(now + 30), rl.iso(now + 61), rl.iso(now + 600),
                                   rl.iso(now + rl.TEN_YEARS), "2099-01-01T00:00:00Z", "1970-01-01T00:00:00Z"])

            def t_bad():
                return rnd.choice([None, "garbage", rl.iso(now + 61 + rnd.uniform(0, 7 * DAY)),
                                   "2099-01-01T00:00:00Z", rl.iso(now + rl.TEN_YEARS), "", "NaN"])
            pick = t_bad if garbage_only else t_any
            records = []
            for p in PRODUCTS:
                for _ in range(rnd.randint(0, 2)):
                    r = {"product": p, "label": labels[p],
                         "status": rnd.choice(["ok", "error", "rate_limited", "expired", "bogus"]), "days": {}}
                    for key in ("asOf", "attemptAt", "nextAt", "retryUntil"):
                        v = pick()
                        if v is not None:
                            r[key] = v
                    if "nextAt" in r:
                        r["schedule"] = {"mode": "auto", "interval": 900, "nextAt": r.pop("nextAt"), "backoff": False}
                    records.append(r)
            last_seen = rnd.choice([rl.iso(now), rl.iso(now - 2 * H), "garbage", rl.iso(now + 600)])
            obj = {"schema": 1, "machine": {"id": self.HOSTILE[8:-5], "name": "x", "os": "x", "app": "x"},
                   "updated": rl.iso(now), "lastSeenAt": last_seen, "tz": "UTC", "days": {}, "accounts": records}
            import json
            sim.gist.put(self.HOSTILE, json.dumps(obj))
        return write

    def test_any_foreign_input_never_exceeds_solo(self):
        base = self.solo(24)
        s = self.sim("idle")
        s.add(phase=0)
        s.hostile = self.hostile_writer(random.Random(24241), garbage_only=False)
        s.run(24, extra=600)
        self.assert_clean(s)
        for p in PRODUCTS:
            self.assertLessEqual(len(s.requests(p)), base[p], "%s: И1 — чужой ввод не учащает опрос сверх Auto" % p)

    def test_garbage_or_future_fields_still_poll_daily(self):
        base = self.solo(24)
        s = self.sim("idle")
        s.add(phase=0)
        s.hostile = self.hostile_writer(random.Random(24242), garbage_only=True)
        s.run(24, extra=600)
        self.assert_clean(s)
        for p in PRODUCTS:
            n = len(s.requests(p))
            self.assertGreaterEqual(n, 1, "%s: мусорные/будущие чужие поля → ≥ 1 запрос за max(I, 24 ч)" % p)
            self.assertLessEqual(n, base[p])


# ---- A3-20(d) T32 convergence events: ≤ 1 pair per event --------------------------------------------------------------------
class TestA320dEvents(SimBase):
    def run_two(self, mode="active", delay=0.0, phase2=137, skew2=0.0, setup=None):
        s = self.sim(mode, delay)
        s.add(phase=0)
        s.add(phase=phase2, skew=skew2)
        if setup:
            setup(s)
        s.run(24)
        self.assert_clean(s)
        return s

    def test_start_and_aligned_ticks(self):
        s = self.run_two(delay=30, phase2=0)
        for p in PRODUCTS:
            self.assertLessEqual(len(s.pairs(p)), 1, "%s: выровненные тики + старт → ≤ 1 пара за сутки" % p)
        for m in s.machines:
            seq = [(e.get("product"), e.get("reason")) for e in s.journal(m) if e.get("ev") == "poll_skipped"]
            for p in PRODUCTS:
                reasons = [r for prod, r in seq if prod == p]
                twice = [i for i in range(1, len(reasons)) if reasons[i] == reasons[i - 1] == "tie_break"]
                self.assertEqual(twice, [], "%s/%s: тай-брейк задерживает ≤ 1 тика" % (m.name, p))

    def test_account_switch(self):
        def setup(s):
            def switch(sim):
                for m in sim.machines:
                    sim.on_machine(m, lambda: self.write_claude_json(rl.U_B))
            s.at(12 * H, switch)
        s = self.run_two(setup=setup)
        self.assertLessEqual(len(s.pairs("claude", since=12 * H, until=14 * H)), 1, "смена входа → ≤ 1 пара")
        self.assertEqual(s.pairs("claude", since=14 * H), [])

    def test_auto_drops_to_15_min(self):
        s = self.sim(lambda t: "active" if t >= simmod.T0 + 12 * H else "idle")
        s.add(phase=0)
        s.add(phase=137)
        s.run(24)
        self.assert_clean(s)
        for p in PRODUCTS:
            self.assertEqual(s.pairs(p, since=WARMUP, until=12 * H), [])
            self.assertLessEqual(len(s.pairs(p, since=12 * H)), 1, "%s: Auto упал до 15 мин → ≤ 1 пара" % p)

    def test_gist_outage_3h(self):
        def setup(s):
            def outage(reader, now):
                if reader == "m2" and simmod.T0 + 10 * H <= now < simmod.T0 + 13 * H:
                    return common.Resp(503)
                return None
            s.gist.get_fail = outage
        s = self.run_two(setup=setup)
        for p in PRODUCTS:
            during = [e for e in s.requests(p, machine="m2") if simmod.T0 + 10 * H <= e.t < simmod.T0 + 13 * H]
            self.assertLessEqual(len(during), 3 * H // 900 + 1,
                                 "%s: простой gist → своё расписание, ≤ 1 лишний запрос на 15 мин простоя" % p)
            self.assertLessEqual(len(s.pairs(p, since=13 * H, until=15 * H)), 1, "%s: восстановление → ≤ 1 пара" % p)
            self.assertEqual(s.pairs(p, since=WARMUP, until=10 * H), [])
            self.assertEqual(s.pairs(p, since=15 * H), [])

    def test_clock_back_and_restart_keep_the_floor(self):
        def setup(s):
            def back(sim):
                sim.machines[0].skew = -1800.0
            s.at(12 * H, back)
        s = self.run_two(setup=setup)
        for m in s.machines:
            for p in PRODUCTS:
                own = [e.t for e in s.requests(p, machine=m.name)]
                gaps = [b - a for a, b in zip(own, own[1:])]
                self.assertTrue(all(g >= 900 for g in gaps), "%s/%s: перевод часов назад обошёл пол 900 с" % (m.name, p))


# ---- A3-20(e) skew ±120 s: no guarantee claimed — clock_skew must be recorded ---------------------------------------------
class TestA320eLargeSkew(SimBase):
    def test_clock_skew_recorded(self):
        for skew in (120.0, -120.0):
            with self.subTest(skew=skew):
                s = self.sim("active")
                s.add(phase=0)
                m2 = s.add(phase=137, skew=skew)
                s.run(2)
                self.assert_clean(s)
                self.assertTrue([e for e in s.journal(m2) if e.get("ev") == "clock_skew"], "clock_skew записан")


if __name__ == "__main__":
    unittest.main()
