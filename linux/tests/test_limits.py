"""Limits parsing and pace (ports of fetchClaude's parser, codexApplyWindow, windowPace)."""

import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from ccl import common, limits  # noqa: E402


class TestClaudeParse(unittest.TestCase):
    def test_flat_and_scoped(self):
        d = limits.LimitData()
        limits._apply_claude_usage(d, {
            "five_hour": {"utilization": 24.0, "resets_at": "2026-09-27T17:16:00.123456+00:00"},
            "seven_day": {"utilization": 58, "resets_at": "2026-10-01T15:16:00+00:00"},
            "limits": [
                {"kind": "weekly_scoped", "percent": 30, "scope": {"model": {"display_name": "Opus"}}},
                {"kind": "weekly_scoped", "percent": 46, "is_active": True, "severity": "warning",
                 "resets_at": "2026-10-01T15:16:00+00:00", "scope": {"model": {"display_name": "Fable"}}},
            ]})
        self.assertEqual((d.session, d.weekly), (24.0, 58.0))
        self.assertEqual(d.session_reset, common.parse_iso("2026-09-27T17:16:00.123456Z"))
        self.assertEqual((d.scoped.name, d.scoped.percent, d.scoped.severity), ("Fable", 46.0, "warning"))

    def test_limits_backfill(self):
        d = limits.LimitData()
        limits._apply_claude_usage(d, {"five_hour": None, "limits": [
            {"kind": "session", "percent": 12, "resets_at": "2026-09-27T17:00:00Z"},
            {"kind": "weekly_all", "percent": 40, "resets_at": "2026-10-01T15:00:00Z"},
            {"kind": "weekly_scoped", "percent": 70, "scope": {"model": {"display_name": "Fable"}}}]})
        self.assertEqual((d.session, d.weekly, d.scoped.percent), (12.0, 40.0, 70.0))


class TestCodexWindows(unittest.TestCase):
    def test_by_duration_not_slot(self):
        d = limits.LimitData()
        # the weekly window sits in the "primary" slot — duration decides
        limits.codex_apply_window({"used_percent": 52.0, "limit_window_seconds": 604800, "reset_at": 1791047384}, d, False)
        self.assertEqual((d.weekly, d.session), (52.0, None))
        limits.codex_apply_window({"used_percent": 10.0, "window_minutes": 300, "resets_at": 1791000000}, d, True)
        self.assertEqual(d.session, 10.0)


class TestPace(unittest.TestCase):
    def test_runs_out_before_reset(self):
        now = 1_000_000.0
        reset = now + 84 * 3600                  # half of a 168 h window left
        p = limits.window_pace(80.0, reset, 168, now=now)
        self.assertAlmostEqual(p.plan_pct, 50.0)
        self.assertAlmostEqual(p.delta_pts, 30.0)
        self.assertAlmostEqual(p.projected, 160.0)
        self.assertIsNotNone(p.runs_out_at)
        self.assertLess(p.runs_out_at, reset)
        self.assertEqual(p.severity, 2)

    def test_lasts(self):
        now = 1_000_000.0
        p = limits.window_pace(20.0, now + 2.5 * 3600, 5, now=now)
        self.assertIsNone(p.runs_out_at)
        self.assertAlmostEqual(p.projected, 40.0)
        self.assertEqual(p.severity, 0)

    def test_too_early_has_no_projection(self):
        now = 1_000_000.0
        p = limits.window_pace(1.0, now + 5 * 3600 - 60, 5, now=now)
        self.assertIsNone(p.projected)


class TestStale(unittest.TestCase):
    def test_past_reset_is_stale(self):
        d = limits.LimitData()
        d.as_of = 1000.0
        d.session_reset = 500.0
        self.assertTrue(limits.is_stale(d, now=1000.0))
        d.session_reset = 5000.0
        self.assertFalse(limits.is_stale(d, now=1000.0))


class TestAlarms(unittest.TestCase):
    def reading(self, weekly, reset, fable=None, fable_reset=None):
        c = limits.LimitData()
        c.session, c.session_reset = 10.0, 5000.0
        c.weekly, c.weekly_reset = weekly, reset
        if fable is not None:
            c.scoped = limits.Scoped("Fable", fable, fable_reset)
        x = limits.LimitData()
        x.present = False
        return c, x

    def test_reached_once_even_on_first_reading(self):
        prev = {}
        ev, upd = limits.detect_alarms(*self.reading(40.0, 9000.0, fable=100.0, fable_reset=9000.0), prev=prev, baseline=False)
        self.assertEqual([(e["kind"], e["window"].split(" · ")[-1]) for e in ev], [("reached", "Fable")])
        prev.update(upd)
        ev, upd = limits.detect_alarms(*self.reading(41.0, 9000.0, fable=100.0, fable_reset=9000.0), prev=prev, baseline=True)
        self.assertEqual(ev, [])

    def test_reset_needs_rollover_and_a_drop(self):
        prev = {}
        _, upd = limits.detect_alarms(*self.reading(60.0, 9000.0), prev=prev, baseline=False)
        prev.update(upd)
        # resets_at creeping forward with usage climbing is not a reset
        ev, upd = limits.detect_alarms(*self.reading(61.0, 9030.0), prev=prev, baseline=True)
        self.assertEqual(ev, [])
        prev.update(upd)
        ev, _ = limits.detect_alarms(*self.reading(0.0, 9000.0 + 7 * 86400), prev=prev, baseline=True)
        self.assertEqual([(e["kind"], e["is5h"]) for e in ev], [("reset", False)])

    def test_no_reset_chime_on_first_reading(self):
        prev = {"rst_c7": 1000.0, "use_c7": 50.0}
        ev, _ = limits.detect_alarms(*self.reading(0.0, 900000.0), prev=prev, baseline=False)
        self.assertEqual(ev, [])


if __name__ == "__main__":
    unittest.main()
