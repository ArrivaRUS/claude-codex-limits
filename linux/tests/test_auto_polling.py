"""Adaptive scheduling with deterministic clocks; no network, credentials or real logs."""
if __package__:
    from . import _isolate  # noqa: F401
else:
    import _isolate  # noqa: F401

import json
import os
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch
from ccl import common, limits, polling, usage

try:
    from ccl.gui import app, panel
    HAVE_QT = True
except ImportError:
    HAVE_QT = False


class TestAutoPolicy(unittest.TestCase):
    def sample(self, used, at, reset=1000000):
        d = limits.LimitData()
        d.session, d.session_reset, d.as_of, d.api_fresh = used, reset, at, True
        return d

    def observe(self, state, used, at, reset=1000000):
        state.begin(at)
        state.observe(self.sample(used, at, reset), at)

    def test_active_then_quiet_ladder_and_four_hour_cap(self):
        state = polling.PollState()
        self.observe(state, 10, 100000)
        self.assertEqual(state.interval, 1800)  # baseline, not a quiet measurement
        self.observe(state, 12, 101800)
        self.assertEqual(state.interval, 900)
        self.observe(state, 12, 102700)
        self.assertEqual(state.interval, 1800)
        self.observe(state, 12.5, 104500)
        self.assertEqual(state.interval, 3600)
        self.observe(state, 12.5, 108100)
        self.assertEqual(state.interval, 14400)
        self.observe(state, 12.5, 122500)
        self.assertEqual(state.interval, 14400)
        self.observe(state, 30, 136900)
        self.assertEqual(state.interval, 900)

    def test_resets_and_changed_models_do_not_look_active(self):
        state = polling.PollState()
        self.observe(state, 95, 100000)
        self.observe(state, 2, 101800, reset=1100000)
        self.assertEqual(state.interval, 1800)
        self.observe(state, 2, 103600, reset=1100000)
        self.assertEqual(state.interval, 3600)

    def test_error_and_cached_fallback_back_off(self):
        for kind in ("error", "cache", "rollout", "expired", "no_limits"):
            with self.subTest(kind=kind):
                state = polling.PollState({"interval": 900})
                data = self.sample(50, 100000)
                if kind == "error": data.error = "429"
                if kind == "cache": data.from_cache = True
                if kind == "rollout": data.api_fresh = False
                if kind == "expired": data.auth = limits.EXPIRED
                if kind == "no_limits": data.session = None
                state.begin(100000)
                state.observe(data, 100000)
                self.assertTrue(state.failed)
                self.assertEqual(state.interval, 1800)
                self.assertFalse(state.local_activity([100100, 100200, 100300], 100400))
                self.assertFalse(state.due(100900, manual=True))
                self.assertTrue(state.due(101800, manual=True))

    def test_local_activity_wakes_sleeping_schedule_without_replaying_history(self):
        state = polling.PollState({"interval": 14400, "last_attempt": 100000})
        self.assertFalse(state.local_activity([99900, 99950, 99999], 100100))
        self.assertFalse(state.local_activity([100010, 100010, 100010], 100100))
        self.assertFalse(state.local_activity([100010, 100020], 100100))
        self.assertTrue(state.local_activity([100010, 100020, 100030], 100100))
        self.assertEqual(state.interval, 900)
        self.assertFalse(state.due(100899))
        self.assertTrue(state.due(100900))
        self.assertFalse(state.local_activity([100010, 100020, 100030], 200000))

    def test_restart_manual_refresh_and_clock_change_preserve_floor(self):
        state = polling.PollState({"interval": 14400, "last_attempt": 100000})
        restored = polling.PollState(json.loads(json.dumps(state.saved())))
        self.assertFalse(restored.due(100899, manual=True))
        self.assertFalse(restored.due(101000))
        self.assertTrue(restored.due(100900, manual=True))
        self.assertTrue(restored.due(114400))
        self.assertFalse(restored.due(99000))  # clock rollback
        self.assertTrue(restored.due(99900, manual=True))
        restored.begin(200000)
        restored.observe(self.sample(1, 200000), 200030)
        self.assertFalse(restored.due(200910, manual=True))  # request duration counts too

    def test_enabled_products_have_independent_schedules(self):
        claude = polling.PollState({"interval": 14400, "last_attempt": 100000})
        codex = polling.PollState({"interval": 900, "last_attempt": 100000})
        self.assertFalse(claude.due(100900))
        self.assertTrue(codex.due(100900))

    def test_local_index_ignores_old_zero_and_duplicate_events(self):
        ix = usage.new_index()
        usage.mark_activity(ix, "codex", 100000, 10, now=100100)
        usage.mark_activity(ix, "codex", 100000, 10, now=100100)
        usage.mark_activity(ix, "codex", 99999, 0, now=100100)
        usage.mark_activity(ix, "codex", 80000, 10, now=100100)
        usage.mark_activity(ix, "codex", 100200, 10, now=100100)
        self.assertEqual(ix["activity"], {"codex": [100000]})
        self.assertNotIn("activity", usage.snapshot_days(ix))


@unittest.skipUnless(HAVE_QT, "PyQt5 not installed")
class TestAutoIntegration(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.st = common.Store(os.path.join(self.tmp.name, "settings.json"), common.SETTINGS_DEFAULTS)
        self.st.set("autoPoll", True)
        for name, value in (("_settings", self.st), ("CACHE_PATH", os.path.join(self.tmp.name, "cache.json"))):
            p = patch.object(common, name, value)
            p.start(); self.addCleanup(p.stop)

    def fake_app(self):
        return SimpleNamespace(busy_limits=False, selection_generation=1, model=panel.Model(), save_poll_states=Mock(),
                               poll_states={"claude": polling.PollState({"interval": 14400, "last_attempt": 100000}),
                                            "codex": polling.PollState({"interval": 900, "last_attempt": 100000})},
                               bridge=SimpleNamespace(limits_done=SimpleNamespace(emit=Mock())))

    def test_timer_fetches_only_due_product(self):
        fake = self.fake_app()
        with patch.object(app.time, "time", return_value=100900), \
             patch.object(app.threading, "Thread", side_effect=lambda target, **kw: SimpleNamespace(start=target)), \
             patch.object(limits, "fetch_claude", side_effect=AssertionError("Claude must stay asleep")), \
             patch.object(limits, "fetch_codex", return_value=limits.LimitData()) as fetch:
            app.TrayApp.refresh_limits(fake, scheduled=True)
        fetch.assert_called_once_with(live=True)
        self.assertEqual(fake.refresh_products, ["codex"])
        self.assertEqual(fake.poll_states["codex"].last_attempt, 100900)
        self.assertEqual(fake.poll_states["claude"].last_attempt, 100000)

    def test_panel_timer_and_repeated_refresh_cannot_bypass_floor(self):
        fake = self.fake_app()
        with patch.object(app.time, "time", return_value=100899), \
             patch.object(app.threading, "Thread", side_effect=AssertionError("no request before 15 minutes")):
            app.TrayApp.refresh_limits(fake, scheduled=True)
            app.TrayApp.refresh_limits(fake)
        self.assertFalse(fake.busy_limits)
        fake.save_poll_states.assert_not_called()

    def test_disabled_products_never_get_requested(self):
        self.st.update(monitor_claude=False, monitor_codex=False)
        fake = self.fake_app()
        with patch.object(app.time, "time", return_value=200000), \
             patch.object(app.threading, "Thread", side_effect=AssertionError("disabled")):
            app.TrayApp.refresh_limits(fake, scheduled=True)
