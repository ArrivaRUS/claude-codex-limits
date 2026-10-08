"""Adaptive scheduling with deterministic clocks; no network, credentials or real logs."""
if __package__:
    from . import _isolate  # noqa: F401
else:
    import _isolate  # noqa: F401

import json
import os
import tempfile
import unittest
from types import MethodType, SimpleNamespace
from unittest.mock import Mock, patch
from ccl import common, limits, polling, quota_refresh, usage

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
                self.assertFalse(state.due(100900))
                self.assertTrue(state.due(101800))

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

    def test_restart_and_clock_change_preserve_scheduled_due_time_with_separate_manual_admission(self):
        state = polling.PollState({"interval": 14400, "last_attempt": 100000})
        restored = polling.PollState(json.loads(json.dumps(state.saved())))
        self.assertFalse(restored.due(100899))
        self.assertFalse(restored.due(101000))
        self.assertFalse(restored.due(100900))
        self.assertTrue(restored.due(114400))
        manual = quota_refresh.RefreshState(restored.last_attempt)
        self.assertEqual(manual.admit("manual", 100899, monotonic_now=100899).kind, "start")
        self.assertFalse(restored.due(99000))
        self.assertFalse(restored.due(99900))
        restored.begin(200000)
        restored.observe(self.sample(1, 200000), 200030)
        self.assertFalse(restored.due(200910))
        self.assertTrue(restored.due(214430))

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
        p = patch.object(app.time, "monotonic", lambda: app.time.time())
        p.start(); self.addCleanup(p.stop)
        self.st = common.Store(os.path.join(self.tmp.name, "settings.json"), common.SETTINGS_DEFAULTS)
        self.st.set("autoPoll", True)
        for name, value in (("_settings", self.st), ("CACHE_PATH", os.path.join(self.tmp.name, "cache.json"))):
            p = patch.object(common, name, value)
            p.start(); self.addCleanup(p.stop)

    def fake_app(self):
        fake = SimpleNamespace(busy_limits=False, selection_generation=1, model=panel.Model(), save_poll_states=Mock(),
                               poll_states={"claude": polling.PollState({"interval": 14400, "last_attempt": 100000}),
                                            "codex": polling.PollState({"interval": 900, "last_attempt": 100000})},
                               win=SimpleNamespace(view=SimpleNamespace(update=Mock())),
                               bridge=SimpleNamespace(limits_done=SimpleNamespace(emit=Mock())))
        fake.refresh_states = {p: quota_refresh.RefreshState(s.last_attempt) for p, s in fake.poll_states.items()}
        for name in ("scheduled_at", "publish_auto_intervals"):
            setattr(fake, name, MethodType(getattr(app.TrayApp, name), fake))
        return fake

    def test_timer_fetches_only_due_product(self):
        fake = self.fake_app()
        with patch.object(app.time, "time", return_value=100900), \
             patch.object(app.threading, "Thread", side_effect=lambda target, **kw: SimpleNamespace(start=target)), \
             patch.object(limits, "fetch_claude", side_effect=AssertionError("Claude must stay asleep")), \
             patch.object(limits, "fetch_codex", return_value=limits.LimitData()) as fetch:
            app.TrayApp.refresh_limits(fake, scheduled=True)
        fetch.assert_called_once_with(live=True)
        self.assertIsNotNone(fake.refresh_states["codex"].flight)
        self.assertIsNone(fake.refresh_states["claude"].flight)
        self.assertEqual(fake.poll_states["codex"].last_attempt, 100900)
        self.assertEqual(fake.poll_states["claude"].last_attempt, 100000)

    def test_scheduled_before_due_and_manual_after_local_guard_do_not_overlap(self):
        fake = self.fake_app()
        queued = []
        with patch.object(app.time, "time", return_value=100899), \
             patch.object(app.threading, "Thread", side_effect=lambda target, **kw: SimpleNamespace(start=lambda: queued.append(target))):
            app.TrayApp.refresh_limits(fake, scheduled=True)
            self.assertEqual(queued, [])
            self.assertFalse(fake.busy_limits)
            app.TrayApp.refresh_limits(fake)
            self.assertEqual(len(queued), 2, "manual wrongly inherited the 900s floor")
            app.TrayApp.refresh_limits(fake)
            app.TrayApp.refresh_limits(fake, scheduled=True)
            self.assertEqual(len(queued), 2, "repeated panel/timer action overlapped a worker")
        self.assertEqual(fake.model.pending_products, {"claude", "codex"})
        self.assertTrue(self.st.get("autoPoll"))

    def test_disabled_products_never_get_requested(self):
        self.st.update(monitor_claude=False, monitor_codex=False)
        fake = self.fake_app()
        with patch.object(app.time, "time", return_value=200000), \
             patch.object(app.threading, "Thread", side_effect=AssertionError("disabled")):
            app.TrayApp.refresh_limits(fake, scheduled=True)
