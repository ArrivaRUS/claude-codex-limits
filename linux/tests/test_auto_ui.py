"""Auto footer contracts and runtime publication; fixtures only (lesson 006)."""
if __package__:
    from . import _isolate  # noqa: F401
else:
    import _isolate  # noqa: F401

import os
import socket
import subprocess
import tempfile
import unittest
from types import MethodType, SimpleNamespace
from unittest.mock import Mock, patch

from ccl import common, limits, polling, quota_refresh, sync, usage, vault

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
try:
    from PyQt5.QtGui import QImage, QPainter
    from PyQt5.QtWidgets import QApplication, QStyleFactory
    from ccl.gui import app, panel
    from ccl.gui.paint import Canvas
    HAVE_QT = True
except ImportError:
    HAVE_QT = False

NOW = 1_800_000_000


@unittest.skipUnless(HAVE_QT, "PyQt5 not installed: actual draw/runtime unverified")
class TestAutoUI(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.qapp = QApplication.instance() or QApplication([])

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        previous_style = self.qapp.style().objectName()
        self.addCleanup(self.qapp.setStyle, previous_style)
        # Every preview has an explicit style, including the existing compact set.
        TestAutoUI.set_preview_style(self, "Fusion")
        p = patch.object(app.time, "monotonic", lambda: app.time.time())
        p.start(); self.addCleanup(p.stop)
        self.st = common.Store(os.path.join(self.tmp.name, "settings.json"), common.SETTINGS_DEFAULTS)
        self.state = common.Store(os.path.join(self.tmp.name, "state.json"), {})
        self.st.update(autoPoll=True, interval=3600, monitor_claude=True, monitor_codex=True)
        def forbidden(*args, **kwargs):
            raise AssertionError("real transport/credentials/logs forbidden")
        for owner, name, value in ((common, "_settings", self.st), (common, "_state", self.state),
                                   (common, "CACHE_PATH", os.path.join(self.tmp.name, "cache.json")),
                                   (vault, "_ss", forbidden), (vault, "read", forbidden),
                                   (vault, "_file_get", forbidden), (sync, "sync_cycle", forbidden),
                                   (limits, "fetch_claude", forbidden), (limits, "fetch_codex", forbidden),
                                   (usage, "refresh", forbidden), (usage, "load_index", forbidden),
                                   (vault, "_ss_v2", forbidden), (sync, "transport", forbidden),
                                   (sync, "auth_owner", forbidden), (common, "http", forbidden),
                                   (socket, "create_connection", forbidden),
                                   (subprocess, "Popen", forbidden), (subprocess, "run", forbidden)):
            p = patch.object(owner, name, value)
            p.start(); self.addCleanup(p.stop)

    def set_preview_style(self, name):
        available = {key.lower() for key in QStyleFactory.keys()}
        self.assertIn(name.lower(), available, "requested CI preview style is unavailable")
        self.qapp.setStyle(name)
        self.assertEqual(self.qapp.style().objectName().lower(), name.lower())

    def save_preview(self, image, case, lang, advanced, prefix="auto-ui"):
        # Unittest previously discarded these QImages; CI already collects this path.
        root = os.environ.get("CCL_PREVIEW_DIR")
        if root:
            real_root = os.path.realpath(root)
            self.assertTrue(real_root.startswith(("/tmp/", "/private/tmp/")),
                            "preview output must remain in the synthetic temporary directory")
            os.makedirs(root, exist_ok=True)
            style = self.qapp.style().objectName().lower()
            self.assertIn(style, ("fusion", "breeze"))
            name = "%s-%s-%s-%s-%s.png" % (prefix, style, case, lang, "advanced" if advanced else "simple")
            self.assertTrue(image.save(os.path.join(root, name)), name)

    def preview_model(self):
        # Fixed coherent observations: these PNGs also contain valid pace/forecasts.
        m = panel.Model()
        m.loaded, m.updated, m.interval = True, NOW - 60, 3600
        for product in ("claude", "codex"):
            d = getattr(m, product)
            d.present, d.api_fresh, d.as_of = True, True, NOW - 60
            d.weekly, d.weekly_reset = 47, d.as_of + 84 * 3600
            if product == "claude":
                d.session, d.session_reset = 31, d.as_of + 2.5 * 3600
        return m

    def model(self):
        m = panel.Model()
        m.loaded = True
        m.claude.present = m.codex.present = True
        m.claude.session, m.codex.weekly = 50, 20
        m.auto_intervals = {"claude": 900, "codex": 14400}
        m.interval, m.updated = 3600, 100000
        return m

    def render(self, model, advanced=False):
        h = panel.advanced_height(model) if advanced else panel.simple_height(model)
        image = QImage(panel.PANEL_W, int(h), QImage.Format_ARGB32)
        image.fill(0)
        painter = QPainter(image)
        painter.setRenderHint(QPainter.Antialiasing)
        painter.setRenderHint(QPainter.TextAntialiasing)
        texts, fills = [], []
        original_text, original_fill = Canvas.text_c, Canvas.round_fill
        def text(canvas, attr, x, top, height, align=0):
            texts.append(("".join(run.s for run in canvas._runs(attr)), x, top, height, align))
            return original_text(canvas, attr, x, top, height, align)
        def fill(canvas, rect, *args):
            fills.append(rect)
            return original_fill(canvas, rect, *args)
        before = dict(model.auto_intervals)
        try:
            with patch.object(Canvas, "text_c", text), patch.object(Canvas, "round_fill", fill), \
                 patch.object(common.Store, "set", side_effect=AssertionError("draw writes settings")), \
                 patch.object(common, "write_json", side_effect=AssertionError("draw writes files")):
                draw = panel.draw_advanced if advanced else panel.draw_simple
                hits = draw(Canvas(painter), panel.PANEL_W, h, model)
        finally:
            painter.end()
        self.assertEqual(model.auto_intervals, before)
        return image, hits, texts, fills

    def assert_geometry(self, hits):
        boxes = dict(hits)
        ids = ("iv900", "iv1800", "iv3600", "iv14400", "iv0")
        self.assertEqual([hid for hid, _ in hits if hid.startswith("iv")], list(ids))
        for i, hid in enumerate(ids):
            r = boxes[hid]
            self.assertEqual((r.x(), r.width(), r.height()), (16 + 40 * i, 40, 24))
            self.assertEqual(r.y(), boxes["quit"].y())
        self.assertEqual((boxes["quit"].x(), boxes["quit"].width()), (320, 24))
        for i, hid in enumerate(ids):
            for other in ids[i + 1:] + ("quit",):
                self.assertFalse(boxes[hid].intersects(boxes[other]))

    def selected_intervals(self, hits, fills):
        top = dict(hits)["iv0"].y()
        # Contract: selected fixed/actual Auto segments have an inset neutral fill.
        return {seconds for i, seconds in enumerate((900, 1800, 3600, 14400))
                if any((r.x(), r.y(), r.width(), r.height()) ==
                       (18 + i * 40, top + 2, 36, 20) for r in fills)}

    def assert_schedule(self, hits, texts, fills, expected):
        self.assert_geometry(hits)
        self.assertEqual(self.selected_intervals(hits, fills), set(expected))
        top = dict(hits)["iv0"].y()
        row = [t for t in texts if top <= t[2] < top + 24]
        self.assertFalse(any(216 <= t[1] <= 320 for t in row), row)
        labels = [t[0] for t in row]
        self.assertEqual(labels, ["15m", "30m", "1h", "4h", "A"] if self.st.get("lang") == "en"
                         else ["15м", "30м", "1ч", "4ч", "А"])

    def test_actual_auto_highlights_enabled_intervals_not_saved_fixed_or_retry(self):
        m = self.model()
        scenarios = (
            ((True, True), {"claude": 900, "codex": 900}, {900}),
            ((True, True), {"claude": 900, "codex": 14400}, {900, 14400}),
            ((True, True), {"claude": 14400, "codex": 900}, {900, 14400}),
            ((True, True), {"claude": 1800, "codex": 3600}, {1800, 3600}),
            ((True, True), {"claude": 3600, "codex": 1800}, {1800, 3600}),
            ((True, False), {"claude": 14400, "codex": 900}, {14400}),
            ((False, True), {"claude": 900, "codex": 1800}, {1800}),
            ((False, False), {"claude": 900, "codex": 14400}, set()),
            ((True, True), {}, set()),
            ((True, True), {"claude": 900}, {900}),
        )
        for lang in ("ru", "en"):
            self.st.set("lang", lang)
            for advanced in (False, True):
                for enabled, intervals, expected in scenarios:
                    with self.subTest(lang=lang, advanced=advanced, enabled=enabled, intervals=intervals):
                        self.st.update(autoPoll=True, monitor_claude=enabled[0], monitor_codex=enabled[1])
                        m.auto_intervals = intervals
                        m.interval = 3600
                        m.claude.next_poll_at = 100410  # Retry deadline is not the interval.
                        _, hits, texts, fills = self.render(m, advanced)
                        self.assert_schedule(hits, texts, fills, expected)
                        # Auto capsule gradient must coexist with actual segment fills.
                        self.assertFalse(any(r.x() == 181 and r.width() == 30 and r.height() == 20 for r in fills))

    def test_fixed_only_selected_segment_and_off_preserves_choice(self):
        m = self.model()
        for lang in ("ru", "en"):
            self.st.set("lang", lang)
            for advanced in (False, True):
                for seconds in (900, 1800, 3600, 14400):
                    for enabled in ((True, True), (True, False), (False, False)):
                        with self.subTest(lang=lang, advanced=advanced, seconds=seconds, enabled=enabled):
                            self.st.update(autoPoll=False, interval=seconds,
                                           monitor_claude=enabled[0], monitor_codex=enabled[1])
                            m.interval = seconds
                            _, hits, texts, fills = self.render(m, advanced)
                            self.assert_schedule(hits, texts, fills, {seconds} if any(enabled) else set())
                            self.assertTrue(any((r.x(), r.width(), r.height()) == (181, 30, 20) for r in fills))
                            self.assertEqual(self.st.get("interval"), seconds)

    def test_representative_schedule_previews(self):
        # Eight curated rows x RU/EN = 16 PNGs, not a style/view/state cross product.
        # Fixed 15/60 use Simple; Fixed 240 and distinct 30/60 use Advanced.
        cases = (
            ("fixed-15", "Fusion", False, 900, {}),
            ("fixed-60", "Fusion", False, 3600, {}),
            ("fixed-240", "Fusion", True, 14400, {}),
            ("auto-equal-30", "Fusion", False, None, {"claude": 1800, "codex": 1800}),
            ("auto-claude30-codex60", "Fusion", True, None, {"claude": 1800, "codex": 3600}),
            ("auto-claude60-codex30", "Fusion", True, None, {"claude": 3600, "codex": 1800}),
            ("fixed-240", "Breeze", True, 14400, {}),
            ("auto-claude60-codex30", "Breeze", True, None, {"claude": 3600, "codex": 1800}),
        )
        with patch.object(app.time, "time", return_value=NOW):
            for case, style, advanced, fixed, intervals in cases:
                self.set_preview_style(style)
                for lang in ("ru", "en"):
                    with self.subTest(case=case, style=style, lang=lang):
                        self.st.update(lang=lang, autoPoll=fixed is None, interval=fixed or 14400,
                                       monitor_claude=True, monitor_codex=True, advHistExpanded=False)
                        m = self.preview_model()
                        m.interval, m.auto_intervals = fixed or 14400, intervals
                        image, hits, texts, fills = self.render(m, advanced)
                        self.assert_schedule(hits, texts, fills, {fixed} if fixed else set(intervals.values()))
                        auto_off = any(r.x() == 181 and r.width() == 30 and r.height() == 20 for r in fills)
                        self.assertEqual(auto_off, fixed is not None)
                        if fixed is None:
                            for seconds in set(intervals.values()):
                                tooltip = panel.interval_tooltip(m, seconds)
                                self.assertEqual("Claude Code" in tooltip, intervals["claude"] == seconds)
                                self.assertEqual("Codex" in tooltip, intervals["codex"] == seconds)
                        if advanced:
                            self.assertIn("94%", "\n".join(t[0] for t in texts))
                        self.save_preview(image, case, lang, advanced)

    def fake_app(self):
        fake = SimpleNamespace(model=self.model(), activity_busy=False, busy_limits=False, selection_generation=1,
                               sound_baselines={"claude": False, "codex": False},
                               poll_states={p: polling.PollState({"interval": v, "last_attempt": 100000})
                                            for p, v in (("claude", 14400), ("codex", 14400))},
                               win=SimpleNamespace(view=SimpleNamespace(update=Mock()), page0_changed=Mock()),
                               load_local=Mock(), update_sync_warning=Mock(), check_alarms=Mock(), update_tray=Mock(),
                               refresh_logs=Mock(), start_poll_timer=Mock())
        fake.model.history.record = Mock()
        fake.refresh_states = {p: quota_refresh.RefreshState(state.last_attempt) for p, state in fake.poll_states.items()}
        fake.start_poll_timer.side_effect = lambda: fake.publish_auto_intervals()
        for name in ("scheduled_at", "publish_auto_intervals", "save_poll_states", "refresh_limits", "auto_summary"):
            setattr(fake, name, MethodType(getattr(app.TrayApp, name), fake))
        return fake

    def test_startup_publishes_restored_states_before_window_exists(self):
        self.state.set("autoPollState", {"claude": {"interval": 14400, "last_attempt": 100000},
                                          "codex": {"interval": 900, "last_attempt": 100000}})
        class StopAtWindow(Exception):
            pass
        def window(fake):
            self.assertEqual(fake.model.auto_intervals, {"claude": 14400, "codex": 900})
            self.assertEqual(fake.model.interval, 3600)
            raise StopAtWindow()
        # The real constructor reaches publication; stop before windows, tray, timers or workers.
        with patch.object(panel.limits.History, "load"), patch.object(app, "Bridge"), \
             patch.object(app.update, "available", return_value=None), patch.object(app, "PanelWindow", side_effect=window):
            with self.assertRaises(StopAtWindow):
                app.TrayApp(self.qapp)

    def test_local_activity_not_due_publishes_and_repaints_without_fetch(self):
        fake = self.fake_app()
        with patch.object(app.time, "time", return_value=100400), \
             patch.object(app.threading, "Thread", side_effect=AssertionError("not-due request")):
            app.TrayApp.on_activity(fake, {"claude": [100100, 100200, 100300]})
        self.assertEqual(fake.model.auto_intervals, {"claude": 900, "codex": 14400})
        fake.win.view.update.assert_called_with()
        self.assertFalse(fake.busy_limits)
        fake.start_poll_timer.assert_called_with()
        _, hits, texts, fills = self.render(fake.model)
        self.assert_schedule(hits, texts, fills, {900, 14400})

    def test_observe_backoff_and_subscription_toggle_publish(self):
        fake = self.fake_app()
        fake.poll_states["claude"].interval = 900
        error = limits.LimitData()
        error.error = "offline fixture"
        with patch.object(app.time, "time", return_value=100400):
            ticket = fake.refresh_states["claude"].admit("manual", 100400, monotonic_now=100400).ticket
            app.TrayApp.on_limits(fake, "claude", ticket, error)
        self.assertEqual(fake.model.auto_intervals, {"claude": 1800, "codex": 14400})
        fake.win.view.update.assert_called_with()
        self.assertTrue(fake.poll_states["claude"].failed)
        fake.start_poll_timer.assert_called_with()
        self.assertIn("Claude Code → 30 минут", fake.auto_summary())
        # Real selection handler, with refresh_limits exercising the not-due path.
        with patch.object(app.time, "time", return_value=100400), \
             patch.object(app.threading, "Thread", side_effect=AssertionError("not-due request")):
            app.TrayApp.set_product_enabled(fake, "codex", False)
        _, hits, texts, fills = self.render(fake.model)
        self.assert_schedule(hits, texts, fills, {1800})
        fake.win.page0_changed.assert_called()

    def test_auto_tooltip_names_only_enabled_actual_intervals_and_off(self):
        fake = self.fake_app()
        fake.model.auto_intervals = {"claude": 900, "codex": 14400}
        for lang, claude, codex, off in (("ru", "Claude Code → 15 минут", "Codex → 4 часа", "Нет включённых подписок"),
                                       ("en", "Claude Code → 15 minutes", "Codex → 4 hours", "No subscriptions enabled")):
            self.st.update(lang=lang, monitor_claude=True, monitor_codex=True)
            summary = fake.auto_summary()
            self.assertIn(claude, summary)
            self.assertIn(codex, summary)
            both = panel.interval_tooltip(fake.model, 900)
            self.assertIn("Claude Code", both)
            self.assertNotIn("Codex", both)
            fake.model.auto_intervals["codex"] = 900
            both = panel.interval_tooltip(fake.model, 900)
            self.assertIn("Claude Code", both)
            self.assertIn("Codex", both)
            self.st.set("monitor_claude", False)
            self.assertNotIn("Claude Code", fake.auto_summary())
            self.assertNotIn("Claude Code", panel.interval_tooltip(fake.model, 900))
            self.st.set("monitor_codex", False)
            self.assertEqual(fake.auto_summary(), off)
            self.assertEqual(panel.interval_tooltip(fake.model, 14400), off)
            fake.model.auto_intervals = {"claude": 900, "codex": 14400}


if __name__ == "__main__":
    unittest.main()
