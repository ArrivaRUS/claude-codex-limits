"""Subscription selection: offline fixtures, no credentials or real CLI logs."""
if __package__:
    from . import _isolate  # noqa: F401
else:
    import _isolate  # noqa: F401

import contextlib
import io
import json
import os
import tempfile
import time
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch

from ccl import cli, common, limits, usage

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
try:
    from PyQt5.QtGui import QImage, QPainter
    from PyQt5.QtWidgets import QApplication
    from ccl.gui import app, panel
    from ccl.gui.paint import Canvas
    HAVE_QT = True
except ImportError:
    HAVE_QT = False


class TestSubscriptions(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = self.tmp.name
        self.st = common.Store(os.path.join(self.root, "settings.json"), common.SETTINGS_DEFAULTS)
        for name, value in (("_settings", self.st), ("HISTORY_PATH", os.path.join(self.root, "history.jsonl")),
                            ("CACHE_PATH", os.path.join(self.root, "cache.json"))):
            patcher = patch.object(common, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def select(self, claude, codex):
        self.st.update(monitor_claude=claude, monitor_codex=codex)

    def test_defaults_and_persistence(self):
        self.assertTrue(common.product_enabled("claude"))
        self.assertTrue(common.product_enabled("codex"))
        self.select(False, True)
        saved = common.Store(self.st.path, common.SETTINGS_DEFAULTS)
        self.assertIs(saved.get("monitor_claude"), False)
        self.assertIs(saved.get("monitor_codex"), True)

    def test_no_credentials_network_or_rollouts_when_disabled(self):
        self.select(False, False)
        with patch.object(limits.os.path, "exists", side_effect=AssertionError("credential lookup")), \
             patch.object(limits.os.path, "isdir", side_effect=AssertionError("log lookup")), \
             patch.object(common, "http", side_effect=AssertionError("network")):
            self.assertFalse(limits.fetch_claude().present)
            self.assertFalse(limits.fetch_codex().present)

    def test_disabled_cache_and_history_are_not_updated(self):
        self.select(False, False)
        common.write_json(common.CACHE_PATH, {"claude": {"session": 80}, "codex": {"weekly": 30}})
        c = limits.LimitData()
        c.session = 45
        c.error = "offline"
        x = limits.LimitData()
        x.weekly = 60
        cached = common.read_json(common.CACHE_PATH)
        c, x = limits.apply_cache(c, x)
        self.assertFalse(c.present or x.present)
        self.assertEqual(common.read_json(common.CACHE_PATH), cached)
        history = limits.History()
        history.record(x, "codex")
        self.assertEqual(history.samples, [])
        self.assertFalse(os.path.exists(common.HISTORY_PATH))

    def test_scan_skips_disabled_tree_and_preserves_offsets(self):
        cr, xr = os.path.join(self.root, "claude"), os.path.join(self.root, "codex")
        os.makedirs(cr)
        os.makedirs(xr)
        cp, xp = os.path.join(cr, "session.jsonl"), os.path.join(xr, "rollout-test.jsonl")
        stamp = common.iso_utc()
        cl = {"timestamp": stamp, "type": "assistant", "message": {"id": "m1", "model": "claude-opus",
              "usage": {"input_tokens": 20, "output_tokens": 10}}}
        cx = {"timestamp": stamp, "type": "event_msg", "payload": {"type": "token_count", "info": {
              "last_token_usage": {"input_tokens": 50, "output_tokens": 10}}}}
        for path, record in ((cp, cl), (xp, cx)):
            with open(path, "w") as f:
                f.write(json.dumps(record) + "\n")
        ix = usage.new_index()
        self.select(False, True)
        original = usage._walk
        def walk(root, want):
            self.assertNotEqual(root, cr, "disabled tree must not be walked")
            return original(root, want)
        with patch.object(usage, "_walk", side_effect=walk):
            usage.scan(ix, claude_root=cr, codex_root=xr)
        self.assertEqual(set(ix["days"]), {"codex"})
        self.select(True, True)
        usage.scan(ix, claude_root=cr, codex_root=xr)
        marks = json.loads(json.dumps(ix["files"]))
        self.select(False, False)
        self.assertFalse(usage.scan(ix, claude_root=cr, codex_root=xr))
        self.assertEqual(ix["files"], marks)
        cl["message"]["id"] = "m2"
        with open(cp, "a") as f:
            f.write(json.dumps(cl) + "\n")
        self.select(True, False)
        usage.scan(ix, claude_root=cr, codex_root=xr)
        self.assertEqual(ix["files"][xp], marks[xp])
        by_day = next(iter(ix["days"]["claude"].values()))
        self.assertEqual(next(iter(by_day.values()))["turns"], 2)

    def test_sync_and_cli_exclude_disabled_history(self):
        self.select(False, True)
        day = common.day_key(time.time())
        ix = usage.new_index()
        ix["days"] = {p: {day: {"model": usage.empty_usage()}} for p in ("claude", "codex")}
        self.assertEqual(set(usage.snapshot_days(ix)), {"codex"})
        args = SimpleNamespace(no_scan=True, merged=True, product=None, days=7, json=True)
        out = io.StringIO()
        with patch.object(usage, "load_index", return_value=ix), \
             patch.object(cli.sync, "load_remote", return_value={"days": ix["days"]}), contextlib.redirect_stdout(out):
            self.assertEqual(cli.cmd_dump(args), 0)
        self.assertEqual(set(json.loads(out.getvalue())), {"codex"})
        self.assertIn("claude", ix["days"], "retained data must not be mutated")

    @unittest.skipUnless(HAVE_QT, "PyQt5 not installed")
    def test_late_refresh_is_discarded_and_rescheduled(self):
        fake = SimpleNamespace(busy_limits=True, selection_generation=2, refresh_limits=Mock())
        app.TrayApp.on_limits(fake, limits.LimitData(), limits.LimitData(), 1)
        self.assertFalse(fake.busy_limits)
        fake.refresh_limits.assert_called_once_with(scheduled=True)

    @unittest.skipUnless(HAVE_QT, "PyQt5 not installed")
    def test_remote_history_filtered_in_gui(self):
        self.select(False, True)
        fake = SimpleNamespace(model=panel.Model(), update_sync_warning=Mock())
        with patch.object(app.sync, "sync_state", return_value=common.Store(os.path.join(self.root, "sync.json"), {"login": "test"})):
            app.TrayApp.apply_days(fake, {"claude": {}, "codex": {common.day_key(time.time()): {"model": usage.empty_usage()}}},
                                  {"machines": [{}], "days": {"claude": {}}})
        self.assertEqual(set(fake.model.days), {"codex"})
        self.assertIn("claude", fake.model.local_days)

    @unittest.skipUnless(HAVE_QT, "PyQt5 not installed")
    def test_panels_all_selections_and_intervals(self):
        qapp = QApplication.instance() or QApplication([])
        m = panel.Model()
        m.loaded = True
        m.claude.present = m.codex.present = True
        m.claude.session = 50
        m.codex.weekly = 20
        m.updated = time.time()
        for lang in ("ru", "en"):
            self.st.set("lang", lang)
            for c, x in ((True, True), (False, True), (True, False), (False, False)):
                self.select(c, x)
                cards = panel.adv_cards(m)
                self.assertEqual([card["product"] for card in cards], [p for p, on in (("claude", c), ("codex", x)) if on])
                self.assertFalse(panel.show_missing_product(cards))
                for advanced in (False, True):
                    h = panel.advanced_height(m) if advanced else panel.simple_height(m)
                    for interval in panel.POLL_CHOICES:
                        m.interval = interval
                        self.st.set("autoPoll", interval == 900)
                        image = QImage(panel.PANEL_W, int(h), QImage.Format_ARGB32)
                        painter = QPainter(image)
                        try:
                            draw = panel.draw_advanced if advanced else panel.draw_simple
                            hits = draw(Canvas(painter), panel.PANEL_W, h, m)
                        finally:
                            painter.end()
                        self.assertTrue(qapp)
                        self.assertIn("settings", [hid for hid, _ in hits])
                        self.assertEqual([hid for hid, _ in hits if hid.startswith("iv")], ["iv900", "iv1800", "iv3600", "iv0"])
                        if not c:
                            self.assertFalse(any("claude.ai" in hid or hid == "claudefix" for hid, _ in hits))
                        output = os.environ.get("CCL_PREVIEW_DIR")
                        if output and interval == 900:
                            os.makedirs(output, exist_ok=True)
                            self.assertTrue(image.save(os.path.join(output, "%s-advanced-%s-claude-%s-codex-%s.png" % (lang, advanced, c, x))))
