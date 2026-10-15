"""REMOTE-LIMITS A3-01 — pure coordination.decide (synth v2 §D, T1 П7, test plan §A3). Written BEFORE the code (red).

Contract (tester → developer; synth fixes the rules, these names/shapes are tester's choice where synth is silent):
  coordination.decide(now, mine, remote, my_id, tie_wait=None) -> Decision      pure: no I/O, no clock, no globals
    now      float epoch seconds (the caller's clock).
    mine     {"label", "interval" ∈ {900,1800,3600,14400}, "last_attempt", "server_until",
              "remote_retry": None | {"until", "firstSeenAt"}  (accepted foreign retryUntil, stored apart from mine),
              "manual": bool (optional, default False)}
    remote   list of other machines' records for MY label: {"machineId", "status", "asOf"?, "attemptAt"?, "retryUntil"?,
             "nextAt"?, "lastSeenAt"?}; times are epoch seconds, ANY non-number (str, None, bool, NaN, missing) = absent.
    my_id    this machine's machine.id (string compare for the tie-break).
    tie_wait None | (machineId, nextAt) remembered from the previous skip.
  Decision: .action ∈ {"poll","skip"}; .reason ∈ {None,"retry_after","remote_attempt","fresh_remote","tie_break"};
            .tie_wait (value to persist: (machineId, nextAt) after a tie skip, None after poll);
            .remote_retry (value to persist; keeps firstSeenAt of an accepted deadline, also after the cap);
            .events (sequence of O1 event names produced by this decision: "remote_retry_capped").
  Rules (synth §D): 1 retry_after: now < max(server_until, min(remote until, firstSeenAt + 24 h)); a foreign retryUntil is
  accepted only from a live record (lastSeenAt ≥ now − 30 min) and only while no accepted one is in effect;
  2 remote_attempt: now − attemptAt < 960; 3 fresh_remote: now − asOf < I + 60; 4 tie_break: foreign nextAt within ±60 s of
  my due (= last_attempt + I), source alive ≤ 15 min, foreign machineId < my_id, (id, nextAt) ≠ tie_wait; 5 poll.
  A foreign record is NOT fresh for B2 when asOf/attemptAt > now + 60, when asOf > attemptAt + 60 (inconsistent: a success
  later than the last attempt — tester's reading of «несогласованные», open question), or when lastSeenAt < now − 30 min.
  Future within 60 s counts as age 0. Manual (mine.manual): rules 1–2 only.
Run: cd linux && python3 -m unittest tests.test_rl_coordination -v
"""

if __package__:
    from . import _rl_env as rl
else:
    import _rl_env as rl

import importlib
import random
import unittest

N = 1791800000.0
LBL = "3f9a0c71b2d4e5f6"
ME, LOW, HIGH = "m-bbbb", "m-aaaa", "m-cccc"
DAY = 86400
STEPS = (900, 1800, 3600, 14400)
REASONS = (None, "retry_after", "remote_attempt", "fresh_remote", "tie_break")


def tearDownModule():
    rl.assert_real_files_untouched()


def field(d, name):
    if isinstance(d, dict):
        return d.get(name)
    return getattr(d, name, None)


def norm_pair(v):
    return None if v is None else [v[0], v[1]]


def mine(interval=900, last=None, server_until=0, remote_retry=None, manual=False):
    m = {"label": LBL, "interval": interval, "last_attempt": N - interval if last is None else last,
         "server_until": server_until, "remote_retry": remote_retry}
    if manual:
        m["manual"] = True
    return m


def rec(mid=LOW, **kw):
    r = {"machineId": mid, "status": "ok", "lastSeenAt": N - 60}
    r.update(kw)
    return r


class Base(unittest.TestCase):
    def setUp(self):
        try:
            self.co = importlib.import_module("ccl.coordination")
        except ImportError as e:
            self.fail("contract: модуль ccl.coordination отсутствует (A3 не реализован): %s" % e)
        if not callable(getattr(self.co, "decide", None)):
            self.fail("contract: ccl.coordination.decide отсутствует")

    def decide(self, now, m, remote, my_id=ME, tie_wait=None):
        d = self.co.decide(now, m, remote, my_id, tie_wait)
        action, reason = field(d, "action"), field(d, "reason")
        self.assertIn(action, ("poll", "skip"), "Decision.action")
        self.assertIn(reason, REASONS, "Decision.reason")
        self.assertEqual(action == "skip", reason is not None, "skip ⇔ reason")
        return d


# ---- A3-01 golden vectors (decide-vectors.json, shared with Swift C4-04) -------------------------------------------
class TestA301GoldenVectors(Base):
    def test_vectors(self):
        doc = rl.fixture("decide-vectors.json")
        self.assertGreaterEqual(len(doc["vectors"]), 40)
        for v in doc["vectors"]:
            with self.subTest(v["id"], ref=v["ref"]):
                tw = v.get("tie_wait")
                d = self.decide(doc["now"], v["mine"], v["remote"], v["my_id"], tuple(tw) if tw else None)
                exp = v["expect"]
                self.assertEqual((field(d, "action"), field(d, "reason")), (exp["action"], exp["reason"]))
                if "tie_wait" in exp:
                    self.assertEqual(norm_pair(field(d, "tie_wait")), exp["tie_wait"], "tie_wait to persist")
                if "remote_retry" in exp:
                    rr = field(d, "remote_retry") or {}
                    self.assertEqual({k: rr.get(k) for k in ("until", "firstSeenAt")}, exp["remote_retry"])
                events = list(field(d, "events") or ())
                self.assertEqual(events, exp.get("events", []), "events of this decision")

    def test_vectors_file_encodes_the_spec_windows(self):
        # Self-check of the golden file: the 959/961 and I±1 boundaries are really there (not an implementation check).
        doc = rl.fixture("decide-vectors.json")
        ids = {v["id"] for v in doc["vectors"]}
        for need in ("a_attempt_959", "a_attempt_961", "b_asof_I59_900", "b_asof_I61_900", "b_asof_I59_14400",
                     "b_asof_I61_14400", "d_tie_first", "d_tie_second_same_pair", "d_tie_dead_source_16min",
                     "f_asof_plus30", "f_asof_2099", "f_asof_garbage", "g_dead_source_fresh_asof",
                     "h_remote_retry_10y_capped", "h_own_retry_48h_not_cut"):
            self.assertIn(need, ids)


# ---- A3-01(d) tie-break waits once, then polls with the record unchanged ---------------------------------------------
class TestA301TieBreakOnce(Base):
    def test_tie_skips_once_per_pair_then_polls(self):
        tie = rec(attemptAt=N - 14370, asOf=N - 14368, nextAt=N + 30)
        d1 = self.decide(N, mine(), [tie])
        self.assertEqual((field(d1, "action"), field(d1, "reason")), ("skip", "tie_break"))
        tw = field(d1, "tie_wait")
        self.assertEqual(norm_pair(tw), [LOW, N + 30])
        d2 = self.decide(N + 300, mine(last=N - 900), [tie], tie_wait=tuple(tw))
        self.assertEqual(field(d2, "action"), "poll", "та же пара второй раз → опрос (задержка ≤ 1 тика)")
        self.assertIsNone(field(d2, "tie_wait"), "после опроса tie_wait очищен")


# ---- A3-01(h) / T31 / И2: the cap counts from firstSeenAt; repeats, heartbeats and restarts do not extend it ----------
class TestA301RemoteRetryCap(Base):
    def run_days(self, until_of, hours=30, step=300):
        rr, polls, capped = None, [], 0
        t = N
        while t < N + hours * 3600:
            r = rec(status="rate_limited", retryUntil=until_of(t), lastSeenAt=t - 30, attemptAt=N - 2 * DAY)
            m = mine(last=0, remote_retry=rr)          # never polled: due on every tick
            d = self.decide(t, m, [r])
            rr = field(d, "remote_retry")              # persisted by the caller (publisher-state.json)
            capped += list(field(d, "events") or ()).count("remote_retry_capped")
            if field(d, "action") == "poll":
                polls.append(t)
            t += step
        return polls, capped

    def test_ten_years_heartbeat_every_tick_waits_exactly_24h(self):
        polls, capped = self.run_days(lambda t: N + rl.TEN_YEARS)
        self.assertTrue(polls, "за 30 ч ни одного опроса — чужой retryUntil превратился в вечный")
        self.assertEqual(polls[0], N + DAY, "ожидание кончается ровно в firstSeenAt + 24 ч")
        self.assertEqual(capped, 1, "remote_retry_capped — один раз")

    def test_changing_far_deadline_does_not_restart_the_cap(self):
        # A hostile/buggy writer bumps retryUntil every tick: still ≥ 1 poll per 24 h (A3-20(c)).
        polls, _ = self.run_days(lambda t: t + rl.TEN_YEARS)
        self.assertTrue(polls and polls[0] <= N + DAY, polls[:1])

    def test_own_deadline_is_not_capped(self):
        d = self.decide(N + 30 * 3600, mine(server_until=N + 48 * 3600), [])
        self.assertEqual(field(d, "reason"), "retry_after", "свой Retry-After 48 ч не режется")

    def test_foreign_deadline_never_lands_in_server_until(self):
        m = mine()
        before = dict(m)
        self.decide(N, m, [rec(status="rate_limited", retryUntil=N + 3600)])
        self.assertEqual(m, before, "decide не меняет вход (чужой дедлайн хранится отдельно, не в server_until)")


# ---- И4: a foreign fresh reading suppresses only while asOf ≤ now + 60 and now − asOf < I + 60 --------------------------
class TestA301FreshnessWindow(Base):
    def test_asof_window_property(self):
        for interval in (900, 14400):
            for off in list(range(-700, 200, 13)) + list(range(interval - 120, interval + 120, 7)):
                as_of = N - off
                d = self.decide(N, mine(interval), [rec(asOf=as_of, lastSeenAt=N)])
                fresh = as_of <= N + 60 and N - as_of < interval + 60
                with self.subTest(interval=interval, offset=off):
                    self.assertEqual(field(d, "action"), "skip" if fresh else "poll")


# ---- A3-01(i) И1–И4 fuzz: foreign input only postpones (seeded, 10^4 cases) -------------------------------------------
class TestA301Fuzz(Base):
    POOL = None

    def pool(self, rnd, now):
        return rnd.choice([None, "garbage", "", True, float("nan"), float("inf"), -1, 0, 4070908800, 10 ** 30,
                           now, now + 30, now + 61, now + 600, now - 59, now - 959, now - 961, now - 1860,
                           now - 14459, now - 86400, now + rnd.uniform(-20000, 20000), [], {}])

    def random_record(self, rnd, now):
        r = {"machineId": rnd.choice([LOW, HIGH, ME, "", None, 7]),
             "status": rnd.choice(["ok", "error", "rate_limited", "expired", "bogus", None])}
        for k in ("asOf", "attemptAt", "retryUntil", "nextAt", "lastSeenAt"):
            if rnd.random() < 0.8:
                r[k] = self.pool(rnd, now)
        return r

    def test_foreign_input_never_makes_me_poll(self):
        rnd = random.Random(20261015)
        for i in range(10000):
            now = N + rnd.uniform(0, 3 * DAY)
            interval = rnd.choice(STEPS)
            last = rnd.choice([0, now - interval, now - interval - rnd.uniform(0, 5000)])
            server = rnd.choice([0, now - 10, now + 10, now + 48 * 3600])
            base = mine(interval, last=last, server_until=server)
            solo = self.co.decide(now, dict(base), [], ME, None)
            rr = rnd.choice([None, {"until": now + rnd.uniform(-DAY, 10 * DAY), "firstSeenAt": now - rnd.uniform(0, 2 * DAY)},
                             {"until": "garbage", "firstSeenAt": None}])
            remote = [self.random_record(rnd, now) for _ in range(rnd.randint(0, 3))]
            tw = rnd.choice([None, (LOW, now), (HIGH, "x")])
            try:
                d = self.co.decide(now, dict(base, remote_retry=rr), remote, ME, tw)
            except Exception as e:  # noqa: BLE001 — the defect: hostile input must never raise
                self.fail("case %d: decide raised %r on %r" % (i, e, remote))
            self.assertIn(field(d, "action"), ("poll", "skip"), "case %d" % i)
            if field(solo, "action") == "skip":
                self.assertEqual(field(d, "action"), "skip",
                                 "case %d: чужой ввод сократил мой Retry-After/пол (И3): %r" % (i, remote))


if __name__ == "__main__":
    unittest.main()
