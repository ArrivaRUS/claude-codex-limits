"""merge() over hostile files from other machines (docs/sync-protocol.md → Read and merge):
nothing crashes, the bad record/file is dropped, the rest is merged. Pure — no network."""

if __package__:
    from . import _sync_env as env
else:
    import _sync_env as env

import json
import math
import time
import unittest

from ccl import common, sync, usage

MODEL = "claude-opus-5-5"


def tearDownModule():
    env.assert_real_files_untouched()


def u(**kw):
    base = dict(input=1, output=1, cacheRead=1, cacheWrite5m=1, cacheWrite1h=1, turns=1)
    base.update(kw)
    return base


def file_(mid, models=None, **top):
    obj = {"schema": 1, "machine": {"id": mid, "name": "pc-" + mid, "os": "T", "app": "t"},
           "updated": common.iso_utc(), "tz": "UTC", "days": {"claude": {DAY: models or {MODEL: u()}}}}
    obj.update(top)
    return json.dumps(obj)


DAY = common.today_key()


class DupNames(dict):
    """Iterates every name twice — the only way to hand merge() the same id twice."""

    def __iter__(self):
        for k in dict.__iter__(self):
            yield k
            yield k


class TestHostileMerge(unittest.TestCase):
    # Scenario 13
    def setUp(self):
        self.files = {
            "machine-good.json": file_("good", {MODEL: u(input=10)}),
            "machine-huge.json": file_("huge", {MODEL: u(input=10 ** 400), "m-ok": u(input=7)}),
            "machine-bool.json": file_("bool", {MODEL: u(turns=True), "m-ok": u(input=7)}),
            "machine-neg.json": file_("neg", {MODEL: u(output=-1), "m-ok": u(input=7)}),
            "machine-float.json": file_("float", {MODEL: u(input=1.5), "m-ok": u(input=7)}),
            "machine-over.json": file_("over", {MODEL: u(input=10 ** 15 + 1), "m-max": u(input=10 ** 15)}),
            "machine-notdict.json": json.dumps({"schema": 1, "machine": ["notdict"], "days": {}}),
            "machine-strmachine.json": json.dumps({"schema": 1, "machine": "strmachine", "days": {}}),
            "machine-month99.json": file_("month99", updated="2026-99-01T00:00:00Z"),
            "machine-feb30.json": file_("feb30", updated="2026-02-30T00:00:00Z"),
            "machine-nullupd.json": file_("nullupd", updated=None),
            "machine-numupd.json": file_("numupd", updated=12345),
            "machine-aa.json": file_("bb"),                          # id ≠ file name
            "machine-.json": file_(""),                              # empty id
            "machine-intid.json": json.dumps({"schema": 1, "machine": {"id": 5}, "days": {}}),
            "machine-baddays.json": file_("baddays", days=[1, 2]),
            "machine-badday.json": json.dumps({"schema": 1, "machine": {"id": "badday"},
                                               "days": {"claude": {DAY: [1]}, "codex": "x"}}),
            "machine-badmodel.json": json.dumps({"schema": 1, "machine": {"id": "badmodel"},
                                                 "days": {"claude": {DAY: {MODEL: "x", "m-ok": u(input=7)}}}}),
            "machine-noupd.json": json.dumps({"schema": 1, "machine": {"id": "noupd", "name": 5},
                                              "days": {"claude": {DAY: {"m-ok": u(input=7)}}}}),
            "machine-schema2.json": file_("schema2", schema=2),
            "machine-list.json": "[1,2]",
            "machine-trunc.json": '{"schema": 1, "machine": {"id": "trunc"',
        }

    def test_hostile_files_do_not_crash_and_are_dropped(self):
        r = sync.merge(self.files, "me")
        ids = sorted(m["id"] for m in r["machines"])
        self.assertEqual(ids, ["badday", "baddays", "badmodel", "bool", "float", "good", "huge", "neg",
                               "noupd", "over"])
        day = r["days"]["claude"][DAY]
        self.assertEqual(day[MODEL]["input"], 10, "only the good record of MODEL is summed")
        self.assertEqual(day["m-ok"]["input"], 7 * 6)
        self.assertEqual(day["m-max"]["input"], 10 ** 15)
        for model, rec in day.items():
            for k, v in rec.items():
                self.assertIs(type(v), int, (model, k))
                self.assertTrue(0 <= v <= usage.MAX_VALUE)
        for m in r["machines"]:
            self.assertTrue(all(isinstance(m[k], str) for k in ("name", "os", "app")))
        json.dumps(r)                                             # the cache must stay writable

    def test_duplicate_id_contributes_once(self):
        r = sync.merge(DupNames({"machine-good.json": file_("good", {MODEL: u(input=10)})}), "me")
        self.assertEqual([m["id"] for m in r["machines"]], ["good"])
        self.assertEqual(r["days"]["claude"][DAY][MODEL]["input"], 10)

    @unittest.expectedFailure
    def test_schema_true_is_not_schema_1(self):
        """FINDING (minor, parity): Linux accepts `"schema": true` because True == 1 in Python
        (sync.py:219 `obj.get("schema") != SCHEMA`); macOS rejects it (syncCount rejects CFBoolean)
        and the protocol says booleans are not numbers. Expected: the file is skipped."""
        r = sync.merge({"machine-sb.json": file_("sb", schema=True)}, "me")
        self.assertEqual(r["machines"], [])

    def test_own_id_skipped(self):
        r = sync.merge({"machine-me.json": file_("me")}, "me")
        self.assertEqual(r["machines"], [])

    def test_fractional_seconds_and_offset_accepted(self):
        for ts in ("2026-09-29T10:00:00.123Z", "2026-09-29T13:00:00.5+03:00"):
            with self.subTest(ts):
                r = sync.merge({"machine-x.json": file_("x", updated=ts)}, "me",
                               now=common.parse_iso("2026-09-30T00:00:00Z"))
                self.assertEqual([m["id"] for m in r["machines"]], ["x"])

    def test_api_cost_and_money_never_crash(self):
        huge = {k: 10 ** 400 for k in usage.FIELDS}
        for rec in (huge, {"input": True}, {"input": -5}, {"input": float("nan")}, {"input": "x"}, "junk", None):
            with self.subTest(rec=str(rec)[:30]):
                c = usage.api_cost(MODEL, rec)
                self.assertTrue(math.isfinite(c))
        merged = usage.merge_days({"claude": {DAY: {MODEL: huge}}}, {"claude": {DAY: {MODEL: huge}}})
        self.assertEqual(merged["claude"][DAY][MODEL]["input"], usage.MAX_VALUE)
        r = sync.merge(self.files, "me")
        s = usage.money_summary(r["days"], "claude", "max", now=time.time())
        self.assertTrue(math.isfinite(s["usdApi"]))


if __name__ == "__main__":
    unittest.main()
