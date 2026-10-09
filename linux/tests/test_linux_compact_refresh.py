"""Linux 0.4.5 requirements, synthetic Qt bitmaps, no live service dependencies.

Run only through reviewed offline Linux CI. Preparing this file is not a runtime run.
The preview matrix is deliberately small; assertions cover extra transitions without PNGs.
"""
if __package__:
    from . import _isolate  # noqa: F401
    from . import test_auto_ui as auto_tests
else:
    import _isolate  # noqa: F401
    import test_auto_ui as auto_tests

import copy
import unittest
from pathlib import Path
from types import MethodType, SimpleNamespace
from unittest.mock import Mock, patch

from ccl import common, limits, polling, quota_refresh

HAVE_QT = auto_tests.HAVE_QT
if HAVE_QT:
    from ccl.gui import app, panel, paint

NOW = 1_800_000_000


@unittest.skipUnless(HAVE_QT, "PyQt5 absent: compact bitmap/runtime unverified")
class TestLinuxCompactRefresh(unittest.TestCase):
    setUpClass = classmethod(auto_tests.TestAutoUI.setUpClass.__func__)
    render = auto_tests.TestAutoUI.render
    assert_geometry = auto_tests.TestAutoUI.assert_geometry
    selected_intervals = auto_tests.TestAutoUI.selected_intervals
    assert_schedule = auto_tests.TestAutoUI.assert_schedule
    set_preview_style = auto_tests.TestAutoUI.set_preview_style

    def setUp(self):
        auto_tests.TestAutoUI.setUp(self)
        for clock in (panel.time, app.time, limits.time):
            if clock is not None:
                p = patch.object(clock, "time", return_value=NOW)
                p.start(); self.addCleanup(p.stop)
        self.st.update(lang="en", autoPoll=True, advHistExpanded=False)
        resources = Path(__file__).resolve().parents[2] / "Resources"
        for name in ("appicon.png", "claude_128.png", "codex_128.png"):
            self.assertTrue((resources / name).is_file(), "bitmap fixture resource missing: " + name)
        for name, value in (("RES_DIRS", [str(resources)]), ("_img_cache", {}),
                            ("FAMILY", ["DejaVu Sans"]), ("MONO", ["DejaVu Sans Mono"])):
            p = patch.object(paint, name, value)
            p.start(); self.addCleanup(p.stop)
        self.assertEqual(common.settings().path, self.st.path)

    def model(self):
        m = panel.Model()
        m.loaded = True
        for product in ("claude", "codex"):
            d = getattr(m, product)
            d.present = True
            d.api_fresh = True
            d.as_of = NOW - 60
            d.weekly, d.weekly_reset = 47, d.as_of + 84 * 3600
            if product == "claude":
                d.session, d.session_reset = 31, d.as_of + 2.5 * 3600
        m.interval = 3600
        m.auto_intervals = {"claude": 900, "codex": 14400}
        m.updated = NOW - 60
        return m

    def save_preview(self, image, case, lang, advanced):
        auto_tests.TestAutoUI.save_preview(self, image, case, lang, advanced, prefix="compact")

    def test_manual_four_hour_roundtrip_and_legacy_startup_migration(self):
        class StopBeforeWindow(Exception):
            pass
        for stored, expected in ((14400, 14400), ("14400", 14400), (60, 1800), (300, 1800)):
            with self.subTest(stored=stored):
                self.st.update(interval=stored, autoPoll=False)
                def stop(owner):
                    self.assertEqual(owner.model.interval, expected)
                    self.assertEqual(self.st.get("interval"), expected)
                    saved = common.Store(self.st.path, common.SETTINGS_DEFAULTS)
                    self.assertEqual(saved.get("interval"), expected)
                    raise StopBeforeWindow()
                with patch.object(panel.limits.History, "load"), patch.object(app, "Bridge"), \
                     patch.object(app.update, "available", return_value=None), \
                     patch.object(app, "PanelWindow", side_effect=stop):
                    with self.assertRaises(StopBeforeWindow):
                        app.TrayApp(self.qapp)

    def test_click_each_interval_then_auto_preserves_last_fixed_selection(self):
        fake = SimpleNamespace(model=self.model(), start_poll_timer=Mock(), scan_activity=Mock(),
                               refresh_limits=Mock(), win=SimpleNamespace(view=SimpleNamespace(update=Mock())))
        for seconds in (900, 1800, 3600, 14400):
            with self.subTest(seconds=seconds):
                app.TrayApp.action(fake, "iv" + str(seconds))
                self.assertFalse(self.st.get("autoPoll"))
                self.assertEqual(fake.model.interval, seconds)
                saved = common.Store(self.st.path, common.SETTINGS_DEFAULTS)
                self.assertEqual(saved.get("interval"), seconds)
                self.assertFalse(saved.get("autoPoll"))
        fake.refresh_limits.assert_not_called()
        app.TrayApp.action(fake, "iv0")
        self.assertTrue(self.st.get("autoPoll"))
        self.assertEqual(self.st.get("interval"), 14400)
        fake.scan_activity.assert_called_once_with()
        fake.refresh_limits.assert_called_once_with(scheduled=True)

    def test_refresh_is_small_header_icon_beside_settings(self):
        m = self.model()
        for advanced in (False, True):
            icons = []
            original = paint.Canvas.icon
            def record(canvas, name, rect, color, weight=1.6):
                icons.append((name, rect, color))
                return original(canvas, name, rect, color, weight)
            with patch.object(paint.Canvas, "icon", record):
                _, hits, texts, fills = self.render(m, advanced)
            boxes = dict(hits)
            refresh, settings = boxes["refresh"], boxes["settings"]
            self.assertEqual((refresh.width(), refresh.height()), (24, 24))
            self.assertEqual((settings.width(), settings.height()), (24, 24))
            self.assertGreater(refresh.x(), settings.x())
            self.assertFalse(refresh.intersects(settings))
            self.assertLessEqual(refresh.bottom(), 53)
            glyph = [r for name, r, _ in icons if name == "refresh" and r.top() < 53]
            self.assertEqual(len(glyph), 1)
            self.assertEqual((glyph[0].width(), glyph[0].height()), (16, 16))
            self.assertTrue(refresh.contains(glyph[0]))
            self.assertFalse(any(r.width() > 24 and r.intersects(refresh) and r.top() < 53 for r in fills))
            self.assertFalse(any("Refresh now" in t[0] or "Обновить сейчас" in t[0] for t in texts))

    def assert_feedback_inside_cards(self, m, hits, fills, texts):
        feedback = {hid: r for hid, r in hits if hid.startswith("feedback:")}
        expected = {"feedback:" + p for p in ("claude", "codex") if common.product_enabled(p)}
        self.assertEqual(set(feedback), expected)
        cards = [r for r in fills if r.width() in (158, 328, 330) and r.height() >= 40 and r.top() >= 58]
        for hid, footer in feedback.items():
            self.assertGreater(footer.height(), 0)
            self.assertLessEqual(footer.height(), 32)
            card = next((r for r in cards if r.contains(footer)), None)
            self.assertIsNotNone(card, hid)
            first, second, _, _ = panel.feedback_copy(m, getattr(m, hid.split(":")[1]), hid.split(":")[1])
            if not first and not second:
                self.assertIn(footer.width(), (16, 18, 80), "idle tooltip uses an existing icon or missing-product name")
                self.assertEqual(footer.height(), 20 if footer.width() == 80 else footer.width())
                self.assertIn(footer.top() - card.top(), (10, 13))
                continue
            self.assertEqual(footer.height(), 32 if second else 16)
            self.assertEqual(footer.bottom(), card.bottom())
            lines = [t for t in texts if footer.top() <= t[2] < footer.bottom() and footer.left() <= t[1] < footer.right()]
            self.assertLessEqual(len(lines), 2, lines)
            for _, _, top, height, _ in lines:
                self.assertLessEqual(top + height, footer.bottom())

    def test_valid_pace_forecast_retained_without_snapshot_line_or_reserved_height(self):
        m = self.model()
        before = copy.deepcopy(vars(m.codex))
        for lang in ("ru", "en"):
            self.st.set("lang", lang)
            for age in (60, 14401):
                m.codex.as_of = NOW - age
                m.codex.weekly_reset = m.codex.as_of + 84 * 3600
                for failure in (False, True):
                    m.codex.error = "synthetic failure" if failure else None
                    m.codex.poll_failed = failure
                    m.codex.api_fresh = not failure
                    m.codex.from_cache = failure
                    self.st.update(monitor_claude=False, monitor_codex=True)
                    observation = copy.deepcopy(vars(m.codex))
                    image, hits, texts, fills = self.render(m, True)
                    self.assertEqual(vars(m.codex), observation, "drawing mutated the observation")
                    self.assert_feedback_inside_cards(m, hits, fills, texts)
                    words = "\n".join(t[0] for t in texts)
                    self.assertNotIn("Pace from snapshot at", words)
                    self.assertNotIn("Темп по снимку от", words)
                    self.assertIn("94%", words, "valid weekly forecast was removed")
                    self.assertIn("plan " if lang == "en" else "план ", words)
                    card = panel.adv_cards(m)[0]
                    self.assertEqual(panel.notice_h(card), 0, "old annotation/retry rows still reserve height")
                    self.assertIsNotNone(card["rows"][0]["limit"]["pace"])
                    if age == 60 and not failure:
                        self.save_preview(image, "fresh-codex", lang, True)
        # A draw must not replace as_of with render time or erase a failure.
        self.assertEqual(m.codex.as_of, NOW - 14401)
        self.assertEqual(m.codex.weekly, before["weekly"])
        self.assertEqual(m.codex.error, "synthetic failure")

    def test_card_tooltip_keeps_asof_and_failure_detail_without_inventing_signin_expiry(self):
        m = self.model()
        d = m.codex
        d.error = "synthetic failure"
        d.poll_failed = True
        d.api_fresh = False
        d.from_cache = True
        d.next_poll_at = NOW + 1800
        for lang in ("ru", "en"):
            self.st.set("lang", lang)
            detail = panel.feedback_copy(m, d, "codex")[3]
            self.assertIn("synthetic failure", detail)
            self.assertIn("Snapshot:" if lang == "en" else "Снимок:", detail)
            self.assertNotIn("Sign-in expired" if lang == "en" else "вход истёк", detail)
            self.assertEqual(d.auth, limits.OK)
            self.assertEqual(d.as_of, NOW - 60)
            d.as_of = None
            detail = panel.feedback_copy(m, d, "codex")[3]
            self.assertIn("Data —" if lang == "en" else "Данные —", detail)
            self.assertNotIn("Snapshot:" if lang == "en" else "Снимок:", detail)
            self.assertIsNone(d.as_of)
            d.as_of = NOW - 60

    def test_representative_bitmaps_and_compact_pending_response_error_stable_height(self):
        # 2 languages x 2 views x 6 useful fixtures = 24 real QPainter bitmaps in CI.
        cases = ("both-fresh", "claude-only", "both-pending", "both-error", "enabled-missing", "off")
        for lang in ("ru", "en"):
            self.st.set("lang", lang)
            for advanced in (False, True):
                heights = {}
                for case in cases:
                    m = self.model()
                    self.st.update(monitor_claude=case != "off", monitor_codex=case not in ("off", "claude-only"))
                    if case == "both-pending":
                        m.pending_products = {"claude", "codex"}
                    if case == "both-error":
                        m.codex.error = "synthetic failure"
                        m.codex.poll_failed = True
                        m.codex.api_fresh = False
                        m.codex.from_cache = True
                        m.codex.next_poll_at = NOW + 1800
                    if case == "enabled-missing":
                        m.codex = limits.absent_limits()
                    with self.subTest(lang=lang, advanced=advanced, case=case):
                        image, hits, texts, fills = self.render(m, advanced)
                        self.assert_schedule(hits, texts, fills, set() if case == "off" else
                                             {900} if case == "claude-only" else {900, 14400})
                        self.assert_feedback_inside_cards(m, hits, fills, texts)
                        heights[case] = image.height()
                        if case == "both-pending":
                            self.assertEqual(sum(t[0] == ("Refreshing…" if lang == "en" else "Обновляем…") for t in texts), 2)
                        if case == "both-error":
                            self.assertIn("Failed" if lang == "en" else "Сбой",
                                          [t[0] for t in texts])
                            self.assertIn("Retry" if lang == "en" else "Повторить", [t[0] for t in texts])
                            self.assertIn("feedbackretry:codex", dict(hits))
                        self.save_preview(image, case, lang, advanced)
                self.assertEqual(heights["both-pending"], heights["both-fresh"] + (32 if advanced else 13))
                self.assertEqual(heights["both-error"], heights["both-fresh"] + (32 if advanced else 29))
                if not advanced:
                    self.assertEqual(heights["both-fresh"], 289)
                    self.assertEqual(heights["claude-only"], 289)
                    self.assertEqual(heights["off"], 286)

    def test_guard_server_partial_completion_and_codex_only_previews(self):
        # Seven rows x RU/EN = 14 PNGs. Repeat only narrow Simple layouts in Breeze;
        # the schedule preview set separately covers Breeze Advanced.
        cases = (
            ("local-guard-30s", "Fusion", False),
            ("server-retry-after-90s", "Fusion", True),
            ("claude-success-codex-pending", "Fusion", False),
            ("codex-success-claude-pending", "Fusion", True),
            ("codex-only", "Fusion", False),
            ("local-guard-30s", "Breeze", False),
            ("codex-only", "Breeze", False),
        )
        for case, style, advanced in cases:
            self.set_preview_style(style)
            for lang in ("ru", "en"):
                with self.subTest(case=case, style=style, lang=lang):
                    self.st.update(lang=lang, autoPoll=True, monitor_claude=case != "codex-only", monitor_codex=True)
                    m = self.model()
                    baseline_height = panel.advanced_height(m) if advanced else panel.simple_height(m)
                    d = m.codex
                    if case == "local-guard-30s":
                        d.as_of, d.weekly_reset = NOW, NOW + 84 * 3600
                        d.local_retry_at = NOW + 30
                        d.next_poll_at = NOW + 14400
                    elif case == "server-retry-after-90s":
                        d.error, d.http_status, d.failure_kind = "HTTP 429", 429, "http"
                        d.api_fresh, d.from_cache, d.poll_failed = False, True, True
                        d.server_retry_at = quota_refresh.retry_after("90", NOW)
                        d.next_poll_at = d.server_retry_at
                        self.assertEqual(d.server_retry_at, NOW + 90)
                    elif "-success-" in case:
                        completed = "claude" if case.startswith("claude-") else "codex"
                        pending = "codex" if completed == "claude" else "claude"
                        m.pending_products = {pending}
                        getattr(m, pending).refresh_in_flight = True
                        finished = getattr(m, completed)
                        finished.as_of, finished.weekly_reset = NOW, NOW + 84 * 3600
                        if completed == "claude":
                            finished.session_reset = NOW + 2.5 * 3600
                    before = copy.deepcopy((vars(m.claude), vars(m.codex), m.pending_products))
                    painted_words = []
                    original_text = paint.Canvas.text
                    def record_text(canvas, attr, *args, **kwargs):
                        painted_words.append("".join(run.s for run in canvas._runs(attr)))
                        return original_text(canvas, attr, *args, **kwargs)
                    with patch.object(paint.Canvas, "text", record_text):
                        image, hits, texts, fills = self.render(m, advanced)
                    self.assertEqual((vars(m.claude), vars(m.codex), m.pending_products), before)
                    self.assertEqual(image.height(), baseline_height + (0 if case == "codex-only" else 16 if advanced else 13),
                                     "one visible status line reserves 16 px; empty Simple keeps 3 px padding")
                    self.assert_schedule(hits, texts, fills, {14400} if case == "codex-only" else {900, 14400})
                    self.assert_feedback_inside_cards(m, hits, fills, texts)
                    boxes = dict(hits)
                    def footer_text(product):
                        r = boxes["feedback:" + product]
                        return [t[0] for t in texts if r.left() <= t[1] < r.right() and r.top() <= t[2] < r.bottom()]
                    if case == "local-guard-30s":
                        self.assertIn("Повтор через 30 с" if lang == "ru" else "Retry in 30 s", footer_text("codex"))
                        self.assertFalse(any(t.startswith("Проверено " if lang == "ru" else "Checked ")
                                             for t in footer_text("codex")))
                        self.assertNotIn("feedbackretry:codex", boxes)
                        self.assertIsNone(d.server_retry_at)
                    elif case == "server-retry-after-90s":
                        self.assertIn("Пауза сервиса · 2 мин" if lang == "ru" else "Service wait · 2 min", footer_text("codex"))
                        self.assertNotIn("feedbackretry:codex", boxes)
                        self.assertEqual(d.as_of, NOW - 60)
                        detail = panel.feedback_copy(m, d, "codex")[3]
                        self.assertIn("Сервис разрешит повтор через" if lang == "ru" else "Service allows retry in", detail)
                        self.assertIn("HTTP 429", detail)
                    elif "-success-" in case:
                        self.assertIn("Обновляем…" if lang == "ru" else "Refreshing…", footer_text(pending))
                        self.assertEqual(footer_text(completed), [])
                        self.assertNotIn("feedbackretry:" + pending, boxes)
                        self.assertEqual(getattr(m, pending).as_of, NOW - 60)
                        self.assertEqual(getattr(m, completed).as_of, NOW)
                    else:
                        self.assertEqual(set(hid for hid in boxes if hid.startswith("feedback:")), {"feedback:codex"})
                        self.assertIn("47%", painted_words)
                        self.assertEqual(image.height(), 289)
                    self.save_preview(image, case, lang, advanced)

    def test_pending_publication_and_response_clear_without_real_worker(self):
        fake = auto_tests.TestAutoUI.fake_app(self)
        fake.model = self.model()
        fake.model.history.record = Mock()
        fake.bridge = SimpleNamespace(limits_done=SimpleNamespace(emit=Mock()))
        fake.poll_states = {p: polling.PollState({"interval": 14400, "last_attempt": NOW - 14400})
                            for p in ("claude", "codex")}
        for outcome in ("response", "error"):
            self.st.set("autoPoll", False)
            fake.refresh_states = {p: quota_refresh.RefreshState() for p in ("claude", "codex")}
            self.assertEqual(fake.model.pending_products, set())
            queued = []
            def defer(target, **kwargs):
                queued.append(target)
                return SimpleNamespace(start=Mock())
            with patch.object(app.threading, "Thread", side_effect=defer) as worker:
                app.TrayApp.refresh_limits(fake)
                self.assertEqual(fake.model.pending_products, {"claude", "codex"})
                app.TrayApp.refresh_limits(fake)
                self.assertEqual(worker.call_count, 2, "one worker per provider, no double click duplicate")
            response = self.model()
            if outcome == "error":
                response.codex.error = "synthetic failure"
                response.codex.api_fresh = False
                response.codex.poll_failed = True
            with patch.object(limits, "fetch_claude", return_value=response.claude), \
                 patch.object(limits, "fetch_codex", return_value=response.codex), \
                 patch.object(limits, "apply_provider_cache", side_effect=lambda p, d, previous=None: d):
                for target in queued:
                    target()
                    product, ticket, data = fake.bridge.limits_done.emit.call_args[0]
                    app.TrayApp.on_limits(fake, product, ticket, data)
            self.assertEqual(fake.model.pending_products, set())
            self.assertFalse(fake.busy_limits)
        self.st.update(monitor_claude=False, monitor_codex=False)
        with patch.object(app.threading, "Thread", side_effect=AssertionError("off creates worker")):
            app.TrayApp.refresh_limits(fake)
        self.assertEqual(fake.model.pending_products, set())


if __name__ == "__main__":
    unittest.main()
