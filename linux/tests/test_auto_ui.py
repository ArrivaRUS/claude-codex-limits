"""Auto footer contracts and runtime publication; fixtures only (lesson 006)."""
if __package__:
    from . import _isolate  # noqa: F401
else:
    import _isolate  # noqa: F401

import ast
import os
import tempfile
import unittest
from pathlib import Path
from types import MethodType, SimpleNamespace
from unittest.mock import Mock, patch

from ccl import common, limits, polling, sync, usage, vault

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
try:
    from PyQt5.QtGui import QImage, QPainter
    from PyQt5.QtWidgets import QApplication
    from ccl.gui import app, panel
    from ccl.gui.paint import Attr, Canvas
    label_parts = panel.auto_poll_label_parts
    HAVE_QT = True
except ImportError:
    HAVE_QT = False
    # Run the exact dependency-free production formatter when Qt is unavailable.
    # This is not a substitute for the skipped draw/runtime tests below.
    path = Path(__file__).parents[1] / "ccl" / "gui" / "panel.py"
    tree = ast.parse(path.read_text())
    nodes = [n for n in tree.body if
             isinstance(n, ast.FunctionDef) and n.name == "auto_poll_label_parts" or
             isinstance(n, ast.Assign) and any(isinstance(t, ast.Name) and t.id == "POLL_DEFAULT" for t in n.targets)]
    namespace = {}
    exec(compile(ast.Module(body=nodes, type_ignores=[]), str(path), "exec"), namespace)
    label_parts = namespace["auto_poll_label_parts"]


class TestAutoLabel(unittest.TestCase):
    def test_all_pairs_single_none_manual_and_missing_state(self):
        for lang, labels in (("ru", ["15м", "30м", "1ч", "4ч"]), ("en", ["15m", "30m", "1h", "4h"])):
            values = dict(zip((900, 1800, 3600, 14400), labels))
            both = {"claude": True, "codex": True}
            for ci, ct in values.items():
                for xi, xt in values.items():
                    with self.subTest(lang=lang, claude=ci, codex=xi):
                        expected = [ct] if ci == xi else ["Claude " + ct, "Codex " + xt]
                        self.assertEqual(label_parts(True, both, {"claude": ci, "codex": xi}, lang), expected)
                for product in ("claude", "codex"):
                    self.assertEqual(label_parts(True, {product: True}, {product: ci}, lang), [ct])
            self.assertEqual(label_parts(True, {}, {}, lang), ["no subscriptions" if lang == "en" else "нет подписок"])
            self.assertEqual(label_parts(False, both, {"claude": 900, "codex": 14400}, lang), [])
            self.assertEqual(label_parts(True, both, {}, lang), [labels[1]])


@unittest.skipUnless(HAVE_QT, "PyQt5 not installed: actual draw/runtime unverified")
class TestAutoUI(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.qapp = QApplication.instance() or QApplication([])

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.st = common.Store(os.path.join(self.tmp.name, "settings.json"), common.SETTINGS_DEFAULTS)
        self.state = common.Store(os.path.join(self.tmp.name, "state.json"), {})
        self.st.update(autoPoll=True, interval=3600, monitor_claude=True, monitor_codex=True)
        def forbidden(*args, **kwargs):
            raise AssertionError("real transport/credentials/logs forbidden")
        for owner, name, value in ((common, "_settings", self.st), (common, "_state", self.state),
                                   (vault, "_ss", forbidden), (vault, "read", forbidden),
                                   (vault, "_file_get", forbidden), (sync, "sync_cycle", forbidden),
                                   (limits, "fetch_claude", forbidden), (limits, "fetch_codex", forbidden),
                                   (usage, "refresh", forbidden)):
            p = patch.object(owner, name, value)
            p.start(); self.addCleanup(p.stop)

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
        painter = QPainter(image)
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
        for hid, x, width in (("iv900", 16, 40), ("iv1800", 56, 40), ("iv3600", 96, 40),
                              ("iv0", 136, 40), ("quit", 320, 24)):
            self.assertEqual((boxes[hid].x(), boxes[hid].width(), boxes[hid].height()), (x, width, 24))
        self.assertFalse(boxes["iv0"].intersects(boxes["quit"]))
        self.assertEqual(boxes["iv0"].y(), boxes["quit"].y())

    def test_actual_draw_text_geometry_manual_and_fallback(self):
        m = self.model()
        for lang in ("ru", "en"):
            self.st.set("lang", lang)
            for advanced in (False, True):
                for enabled in ((True, True), (True, False), (False, True), (False, False)):
                    self.st.update(monitor_claude=enabled[0], monitor_codex=enabled[1])
                    image, hits, texts, fills = self.render(m, advanced)
                    self.assert_geometry(hits)
                    expected = label_parts(True, dict(zip(("claude", "codex"), enabled)), m.auto_intervals, lang)
                    labels = [t for t in texts if t[1] == 184]
                    self.assertIn([t[0] for t in labels], [[" · ".join(expected)], expected])
                    self.assertFalse(any(t[0].startswith(("updated ", "обновлено ")) for t in texts))
                    self.assertFalse(any(r.x() in (18, 58, 98) and r.width() == 36 for r in fills))
                    # Includes Advanced -> Simple when both products are disabled.
                    output = os.environ.get("CCL_PREVIEW_DIR")
                    if output:
                        os.makedirs(output, exist_ok=True)
                        name = "auto-ui-%s-advanced-%s-enabled-%s%s.png" % (lang, advanced, *enabled)
                        self.assertTrue(image.save(os.path.join(output, name)))
                self.st.update(monitor_claude=True, monitor_codex=True)
                for fixture, intervals, expected in (("equal", {"claude": 1800, "codex": 1800}, ["30m" if lang == "en" else "30м"]),
                                                     ("backoff", {"claude": 3600, "codex": 900},
                                                      ["Claude 1h", "Codex 15m"] if lang == "en" else ["Claude 1ч", "Codex 15м"]),
                                                     ("long", {"claude": 1800, "codex": 900},
                                                      ["Claude 30m", "Codex 15m"] if lang == "en" else ["Claude 30м", "Codex 15м"])):
                    m.auto_intervals = intervals
                    image, hits, texts, _ = self.render(m, advanced)
                    self.assert_geometry(hits)
                    self.assertIn([t[0] for t in texts if t[1] == 184], [[" · ".join(expected)], expected])
                    if output:
                        self.assertTrue(image.save(os.path.join(output, "auto-ui-%s-%s-advanced-%s.png" % (fixture, lang, advanced))))
                self.st.update(monitor_claude=False, monitor_codex=True)
                for seconds, minutes, label in ((900, 15, "15m" if lang == "en" else "15м"),
                                                 (1800, 30, "30m" if lang == "en" else "30м"),
                                                 (3600, 60, "1h" if lang == "en" else "1ч"),
                                                 (14400, 240, "4h" if lang == "en" else "4ч")):
                    m.auto_intervals = {"codex": seconds}
                    image, hits, texts, _ = self.render(m, advanced)
                    self.assert_geometry(hits)
                    self.assertEqual([t[0] for t in texts if t[1] == 184], [label])
                    if output:
                        name = "auto-ui-single-codex-%s-%s-advanced-%s.png" % (minutes, lang, advanced)
                        self.assertTrue(image.save(os.path.join(output, name)))
                m.auto_intervals = {"claude": 900, "codex": 14400}
                self.st.update(autoPoll=False, monitor_claude=True, monitor_codex=True)
                image, hits, texts, fills = self.render(m, advanced)
                self.assert_geometry(hits)
                self.assertFalse(any(t[1] == 184 for t in texts))
                self.assertTrue(any(t[0].startswith(("updated ", "обновлено ")) for t in texts))
                self.assertEqual([r.x() for r in fills if r.width() == 36 and r.height() == 20], [98])
                if output:
                    self.assertTrue(image.save(os.path.join(output, "auto-ui-manual-60-%s-advanced-%s.png" % (lang, advanced))))
                self.st.set("autoPoll", True)

    def test_width_boundary_and_two_rows_stay_in_label_region(self):
        m = self.model()
        real_width = Attr.width
        for width in (128, 129):
            with patch.object(Attr, "width", lambda a: width if " · " in a.s else real_width(a)):
                _, hits, texts, _ = self.render(m)
            label = [t for t in texts if t[1] == 184]
            self.assertEqual([t[0] for t in label], ["Claude 15м · Codex 4ч"] if width == 128 else ["Claude 15м", "Codex 4ч"])
            top = dict(hits)["iv0"].y()
            for value, x, y, height, align in label:
                self.assertLessEqual(real_width(Attr(value, 10, "medium")) if width > 128 else width, 128)
                self.assertGreaterEqual(y, top)
                self.assertLessEqual(y + height, top + 24)
            if width > 128:
                self.assertEqual(label[1][2] - label[0][2], 12)

    def fake_app(self):
        fake = SimpleNamespace(model=self.model(), activity_busy=False, busy_limits=False, selection_generation=1,
                               poll_states={p: polling.PollState({"interval": v, "last_attempt": 100000})
                                            for p, v in (("claude", 14400), ("codex", 14400))},
                               win=SimpleNamespace(view=SimpleNamespace(update=Mock()), page0_changed=Mock()),
                               load_local=Mock(), update_sync_warning=Mock(), check_alarms=Mock(), update_tray=Mock(),
                               refresh_logs=Mock(), refresh_products=["claude"])
        fake.model.history.record = Mock()
        for name in ("publish_auto_intervals", "save_poll_states", "refresh_limits", "auto_summary"):
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
        fake.win.view.update.assert_called_once_with()
        self.assertFalse(fake.busy_limits)
        _, _, texts, _ = self.render(fake.model)
        self.assertIn([t[0] for t in texts if t[1] == 184],
                      [["Claude 15м · Codex 4ч"], ["Claude 15м", "Codex 4ч"]])

    def test_observe_backoff_and_subscription_toggle_publish(self):
        fake = self.fake_app()
        fake.poll_states["claude"].interval = 900
        error = limits.LimitData()
        error.error = "offline fixture"
        with patch.object(app.time, "time", return_value=100400):
            app.TrayApp.on_limits(fake, error, fake.model.codex, 1)
        self.assertEqual(fake.model.auto_intervals, {"claude": 1800, "codex": 14400})
        fake.win.view.update.assert_called_once_with()
        self.assertTrue(fake.poll_states["claude"].failed)
        self.assertIn("пауза после ошибки", fake.auto_summary())
        # Real selection handler, with refresh_limits exercising the not-due path.
        with patch.object(app.time, "time", return_value=100400), \
             patch.object(app.threading, "Thread", side_effect=AssertionError("not-due request")):
            app.TrayApp.set_product_enabled(fake, "codex", False)
        _, _, texts, _ = self.render(fake.model)
        self.assertEqual([t[0] for t in texts if t[1] == 184], ["30м"])
        fake.win.page0_changed.assert_called()

    def test_timestamp_and_error_are_tooltip_only_when_auto_on(self):
        fake = self.fake_app()
        fake.poll_states["claude"].failed = True
        for lang, clock_prefix, error_text in (("ru", "обновлено ", "пауза после ошибки"),
                                                ("en", "updated ", "backing off after an error")):
            self.st.set("lang", lang)
            for updated in (100000, None):
                fake.model.updated = updated
                summary = fake.auto_summary()
                self.assertEqual(clock_prefix in summary, updated is not None)
                self.assertIn(error_text, summary)
                self.assertIn(error_text, next(line for line in summary.splitlines() if line.startswith("Claude Code:")))
                self.assertNotIn(error_text, next(line for line in summary.splitlines() if line.startswith("Codex:")))
                _, _, texts, _ = self.render(fake.model)
                self.assertFalse(any(clock_prefix in t[0] or error_text in t[0] for t in texts))
            self.st.set("autoPoll", False)
            self.assertNotIn(clock_prefix, fake.auto_summary())
            self.st.set("autoPoll", True)


if __name__ == "__main__":
    unittest.main()
