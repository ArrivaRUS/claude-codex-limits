"""K342: O1 retention and at-least-once application-version delivery.

All state, locks and journal files belong to RLEnv's disposable offline sandbox.
Run: QT_QPA_PLATFORM=offscreen PYTHONDONTWRITEBYTECODE=1 python3 -m unittest tests.test_o1_retention -v
"""

if __package__:
    from . import _rl_env as rl
else:
    import _rl_env as rl

import json
import os
from unittest import mock

from ccl import common

DAY = 86400
MIB = 1024 * 1024


def tearDownModule():
    rl.assert_real_files_untouched()


class TestO1Retention(rl.RLEnv):
    def setUp(self):
        super().setUp()
        common._o1_state_dir()
        self.path = os.path.join(common.STATE_DIR, "publisher.jsonl")
        self.marker = os.path.join(common.STATE_DIR, "publisher-journal-state.json")
        for target, value in (("time.time", self.clock), ("ccl.common.APP_VERSION", "9.8.7")):
            patch = mock.patch(target, value)
            patch.start()
            self.addCleanup(patch.stop)

    def rows(self):
        with open(self.path, "rb") as stream:
            data = stream.read()
        self.assertTrue(data.endswith(b"\n"), "no partial final JSON line")
        # Deliberately parse every line: a split rotation boundary must fail.
        return [json.loads(line) for line in data.splitlines()]

    def seed(self, rows):
        with open(self.path, "wb") as stream:
            for row in rows:
                encoded = json.dumps(row, separators=(",", ":")).encode()
                # Exactly 268 * 256 = 67 KiB/day, including valid JSON whitespace.
                self.assertLess(len(encoded), 256)
                stream.write(encoded + b" " * (255 - len(encoded)) + b"\n")

    def historical(self, age, count):
        return dict(ev="poll_result", product="claude", count=count,
                    ts=common.iso_utc(self.clock() - age))

    def test_rotation_preserves_at_least_30_days_at_67_kib_per_day(self):
        self.seed(self.historical(day * DAY + tick * DAY / 268, day * 268 + tick)
                  for day in range(69, -1, -1) for tick in range(267, -1, -1))
        self.assertGreater(os.path.getsize(self.path), 4 * MIB)
        self.assertTrue(common.o1_event("poll_result", product="claude", count=-1))
        self.assertLessEqual(os.path.getsize(self.path), 3 * MIB)
        rows = self.rows()
        history = [row for row in rows if row.get("count", -1) >= 0]
        ages = [self.clock() - common.parse_iso(row["ts"]) for row in history]
        self.assertGreaterEqual(max(ages), 30 * DAY)
        self.assertLessEqual(max(ages), 45 * DAY)
        # Every one of the newest 30 days survives, not just one old outlier.
        self.assertEqual({row["count"] for row in history if row["count"] < 30 * 268},
                         set(range(30 * 268)))
        self.assertEqual(rows[-2]["ev"], "app_version")
        self.assertEqual(rows[-1]["count"], -1)

    def test_rotation_filters_expired_rows_even_inside_newest_tail(self):
        rows = [self.historical(DAY, n) for n in range(4 * MIB // 256 + 1)]
        # Out-of-order timestamps ensure the age filter, rather than byte trimming,
        # removes expired records. Exact cutoff survives; one second older does not.
        rows += [self.historical(46 * DAY, -46), self.historical(45 * DAY + 1, -451),
                 self.historical(45 * DAY, -45), self.historical(0, -2)]
        self.seed(rows)
        self.assertTrue(common.o1_event("poll_result", count=-1))
        kept = self.rows()
        counts = {row.get("count") for row in kept}
        self.assertNotIn(-46, counts)
        self.assertNotIn(-451, counts)
        self.assertTrue({-45, -2, -1}.issubset(counts))
        self.assertIn(8192, counts, "recent row within the 3 MiB tail survives age filtering")
        self.assertLessEqual(os.path.getsize(self.path), 3 * MIB)

    def test_no_rotation_below_four_mib(self):
        self.seed(self.historical(DAY, n) for n in range(3 * MIB // 256 + 1))
        inode = os.stat(self.path).st_ino
        self.assertTrue(common.o1_event("poll_result", count=-1))
        self.assertEqual(os.stat(self.path).st_ino, inode)
        self.assertEqual(self.rows()[0]["count"], 0)
        self.assertGreater(os.path.getsize(self.path), 3 * MIB)
        self.assertLess(os.path.getsize(self.path), 4 * MIB)

    def test_first_version_precedes_event_and_unchanged_version_is_not_repeated(self):
        self.assertTrue(common.o1_event("poll_result", count=1))
        self.assertTrue(common.o1_event("poll_result", count=2))
        rows = self.rows()
        self.assertEqual([row["ev"] for row in rows], ["app_version", "poll_result", "poll_result"])
        self.assertEqual(rows[0]["version"], common.APP_VERSION)
        with open(self.marker) as stream:
            self.assertEqual(json.load(stream), {"version": common.APP_VERSION})

    def test_changed_marker_and_running_version_emit_once_per_transition(self):
        common.write_json(self.marker, {"version": "0.0.1"})
        self.assertTrue(common.o1_event("poll_result", count=1))
        with mock.patch.object(common, "APP_VERSION", "9.8.8"):
            self.assertTrue(common.o1_event("poll_result", count=2))
            self.assertTrue(common.o1_event("poll_result", count=3))
        rows = self.rows()
        self.assertEqual([row.get("version") for row in rows if row["ev"] == "app_version"],
                         ["9.8.7", "9.8.8"])
        self.assertEqual([row["ev"] for row in rows],
                         ["app_version", "poll_result", "app_version", "poll_result", "poll_result"])

    def test_marker_save_failure_allows_repeat_without_losing_event(self):
        common.write_json(self.marker, {"version": "0.0.1"})
        write_json = common.write_json

        def fail_marker(path, *args, **kwargs):
            if path == self.marker:
                # Observe journal delivery BEFORE the failed marker commit.
                self.assertEqual([r["ev"] for r in self.rows()], ["app_version", "poll_result"])
                raise OSError("synthetic marker save failure")
            return write_json(path, *args, **kwargs)

        with mock.patch.object(common, "write_json", side_effect=fail_marker):
            common.o1_event("poll_result", count=1)
        self.assertTrue(common.o1_event("poll_result", count=2))
        self.assertTrue(common.o1_event("poll_result", count=3))
        rows = self.rows()
        self.assertEqual([r["ev"] for r in rows],
                         ["app_version", "poll_result", "app_version", "poll_result", "poll_result"])
        self.assertEqual([r["count"] for r in rows if r["ev"] == "poll_result"], [1, 2, 3])

    def test_version_validator_accepts_only_running_version_on_app_version(self):
        self.assertEqual(common._o1_record("app_version", {"version": common.APP_VERSION})["version"],
                         common.APP_VERSION)
        for event, version in (("app_version", "0.0.1"), ("app_version", None),
                               ("poll_result", common.APP_VERSION)):
            with self.subTest(event=event, version=version), self.assertRaises(ValueError):
                common._o1_record(event, {"version": version})
