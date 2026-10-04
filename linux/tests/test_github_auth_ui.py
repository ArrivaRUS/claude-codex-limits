"""R3/A7/A10/A12 actual Qt Settings, Canvas and sync maintenance callbacks.

No normal app startup. All reachable runtime boundaries are denied before
callbacks, then only named fake slots/workers are enabled. PNGs use /tmp only.
"""
if __package__:
    from . import _isolate
    from ._auth_integration_env import PipelineCase, assert_nonsecret, forbidden
else:
    import _isolate
    from _auth_integration_env import PipelineCase, assert_nonsecret, forbidden

import os
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from ccl import common, sync, usage

try:
    from PyQt5.QtCore import QTimer
    from PyQt5.QtGui import QDesktopServices, QImage, QPainter
    from PyQt5.QtWidgets import QApplication, QLabel, QPushButton, QVBoxLayout, QWidget
    from ccl.gui import app, panel
    from ccl.gui.paint import Canvas
    HAVE_QT = True
except ImportError:
    HAVE_QT = False


class InlineThread:
    """Deterministic fake worker; never starts an OS thread or deferred callback."""
    def __init__(self, *, target, daemon):
        if daemon is not True:
            raise AssertionError("unexpected worker mode")
        self.target = target

    def start(self):
        self.target()


@unittest.skipUnless(HAVE_QT, "PyQt5 missing: actual Qt auth draw/callbacks unverified")
class TestGitHubAuthQt(PipelineCase):
    @classmethod
    def setUpClass(cls):
        cls.qapp = QApplication.instance() or QApplication([])

    def setUp(self):
        super().setUp()
        self.patch(QDesktopServices, "openUrl", forbidden)
        self.patch(QTimer, "singleShot", forbidden)
        self.patch(app.threading, "Thread", forbidden)
        self.patch(app.TrayApp, "__init__", forbidden)
        self.output = os.environ.get("CCL_PREVIEW_DIR", self.tmp.name)
        real_output = os.path.realpath(self.output)
        if not (real_output.startswith("/tmp/") or real_output.startswith("/private/tmp/")):
            raise AssertionError("auth preview output must live under /tmp")
        os.makedirs(self.output, exist_ok=True)

    def fixture_app(self):
        # No TrayApp, timers, tray icon, observers, scan or provider construction.
        model = panel.Model()
        callbacks = []
        return SimpleNamespace(model=model, logout_busy=False, logout_error=None, login_state=None,
                               login_code=None, login_error=None, login_uri=None,
                               start_login=lambda: callbacks.append("login"), logout=lambda: callbacks.append("logout"),
                               callbacks=callbacks)

    def settings(self, fixture, filename):
        holder = QWidget()
        holder.sync_lay = QVBoxLayout(holder)
        holder.app = fixture
        holder._btn = app.SettingsPage._btn
        holder._logout_note = app.SettingsPage._logout_note
        before = self.world.ledger.mark()
        durable_before = common.read_json(common.SYNC_STATE_PATH)
        store_before = self.world.store.snapshot()
        with patch.object(common, "write_json", forbidden), patch.object(common.Store, "set", forbidden):
            app.SettingsPage.render_sync(holder)
        self.assertEqual(self.world.ledger.since(before), {})
        self.assertEqual(common.read_json(common.SYNC_STATE_PATH), durable_before)
        self.assertTrue(self.world.store.snapshot() == store_before)
        labels = [w.text() for w in holder.findChildren(QLabel)]
        buttons = holder.findChildren(QPushButton)
        assert_nonsecret(labels + [button.text() for button in buttons])
        holder.resize(360, max(300, holder.sizeHint().height()))
        holder.show()
        self.qapp.processEvents()
        self.assertTrue(holder.grab().save(os.path.join(self.output, filename + ".png")))
        self.addCleanup(holder.close)
        return labels, buttons

    def draw_main(self, fixture, filename):
        texts = []
        model = fixture.model
        app.TrayApp.update_sync_warning(fixture)
        model.loaded = True
        height = int(panel.advanced_height(model))
        image = QImage(panel.PANEL_W, height, QImage.Format_ARGB32)
        image.fill(0)
        painter = QPainter(image)
        original = Canvas.text
        def capture(canvas, attr, x, top, align=0):
            texts.append("".join(run.s for run in canvas._runs(attr)))
            return original(canvas, attr, x, top, align)
        before = self.world.ledger.mark()
        durable_before = common.read_json(common.SYNC_STATE_PATH)
        try:
            with patch.object(Canvas, "text", capture), patch.object(common, "write_json", forbidden), \
                    patch.object(common.Store, "set", forbidden):
                hits = panel.draw_advanced(Canvas(painter), panel.PANEL_W, height, model)
        finally:
            painter.end()
        self.assertEqual(self.world.ledger.since(before), {})
        self.assertEqual(common.read_json(common.SYNC_STATE_PATH), durable_before)
        for _, rect in hits:
            self.assertGreaterEqual(rect.top(), 0)
            self.assertLessEqual(rect.bottom(), height)
        assert_nonsecret(texts)
        self.assertTrue(image.save(os.path.join(self.output, filename + ".png")))
        return texts, hits

    def test_ru_en_truthful_storage_and_terminal_settings_controls_main_hits(self):
        self.login()
        common.settings().set("monitor_claude", True)
        for lang in ("ru", "en"):
            common.settings().update(lang=lang)
            for kind, reason in (("ready", None), ("temporary", "unreachable"), ("temporary", "locked"),
                                 ("temporary", "network"), ("temporary", "identity_pending"),
                                 ("actionRequired", "lost_result"), ("actionRequired", "refresh_invalid"),
                                 ("actionRequired", "missing"), ("signedOut", None)):
                with self.subTest(lang=lang, kind=kind, reason=reason):
                    # Presentation fixtures carry only typed public projection;
                    # rendering must never ask the owner/store for credentials.
                    sync.sync_state().update(authStatus=dict(kind=kind, reason=reason, backend="secret-service"))
                    fixture = self.fixture_app()
                    fixture.model.claude.present = True
                    fixture.model.claude.session, fixture.model.claude.weekly = 31, 47
                    fixture.model.claude.as_of = self.world.clock()
                    fixture.model.claude.session_reset = self.world.clock() + 3600
                    fixture.model.claude.weekly_reset = self.world.clock() + 86400
                    labels, buttons = self.settings(fixture, "github-settings-%s-%s-%s" % (lang, kind, reason))
                    texts = "\n".join(labels)
                    login_text = "Войти через GitHub" if lang == "ru" else "Sign in with GitHub"
                    login_buttons = [b for b in buttons if b.text() == login_text]
                    if kind == "temporary":
                        self.assertEqual(login_buttons, [])
                        self.assertIn(sync.auth_reason(reason), labels)
                        self.assertNotIn("отозван", texts.lower())
                        self.assertNotIn("revoked", texts.lower())
                    elif kind in ("actionRequired", "signedOut"):
                        self.assertEqual(len(login_buttons), 1)
                        login_buttons[0].click()
                        self.assertEqual(fixture.callbacks, ["login"])
                    else:
                        self.assertEqual(login_buttons, [])
                        self.assertIn("GitHub: fixture-user", texts)
                    main_texts, hits = self.draw_main(fixture, "github-main-%s-%s-%s" % (lang, kind, reason))
                    if kind in ("temporary", "actionRequired"):
                        self.assertEqual(fixture.model.sync_warning, sync.auth_reason(reason))
                        self.assertTrue(any("settings" == target and rect.height() == panel.NOTICE for target, rect in hits))
                        reason_text = sync.auth_reason(reason)
                        self.assertTrue(any(text == reason_text or
                                            (text.endswith("…") and reason_text.startswith(text[:-1]))
                                            for text in main_texts))

    def test_actual_scheduled_callback_advanced_off_stale_index_limits_disabled(self):
        self.login()
        self.world.clock.advance(42 * 86400)
        self.http.marker = 19
        fixture = self.fixture_app()
        fixture.busy_logs = fixture.force_pending = fixture.busy_limits = False
        fixture.selection_generation = 0
        fixture.poll_states = {}
        deliveries = []
        fixture.bridge = SimpleNamespace(logs_done=SimpleNamespace(emit=lambda *args: deliveries.append(args)))
        # Actual callback runs an isolated stale-index read and actual protected
        # sync; allow_push=False must suppress all PATCH while still reading.
        scanned = []
        def stale_index(*, blocking):
            scanned.append(blocking)
            return {"days": {}}, False, False
        mark = self.world.ledger.mark()
        with patch.object(app.threading, "Thread", InlineThread), patch.object(usage, "refresh", stale_index):
            app.TrayApp.refresh_limits(fixture, scheduled=True)
            app.TrayApp.refresh_logs(fixture)
        self.assertEqual(scanned, [False])
        self.assertEqual(len(deliveries), 1)
        days, (remote, result, forced) = deliveries[0]
        self.assertTrue(result.ok, "maintenance callback must actually resume authorized sync")
        self.assertFalse(forced)
        self.assertEqual(remote["days"]["claude"]["2026-10-04"]["fixture-model"]["input"], 19)
        self.assertEqual(self.world.ledger.since(mark)["issuer.refresh_consumed"], 1)
        self.assertEqual(self.world.ledger.since(mark).get("device_flow", 0), 0)
        self.assertEqual(self.http.patch_count, 0)
        self.assertFalse(fixture.busy_limits)

    def test_actual_apply_days_filters_previous_account_memory_cache(self):
        common.settings().update(monitor_claude=True)
        self.login(user_id="1001", login="account-a")
        _, previous = self.cycle()
        fixture = self.fixture_app()
        fixture.update_sync_warning = lambda st: app.TrayApp.update_sync_warning(fixture, st)
        app.TrayApp.apply_days(fixture, {}, previous)
        self.assertTrue(fixture.model.days)
        self.login(user_id="2002", login="account-b")
        self.http.fail_read = True
        self.assertFalse(sync.sync_cycle({}, allow_push=False).ok)
        app.TrayApp.apply_days(fixture, {}, previous)
        self.assertEqual(fixture.model.days, {})
        self.assertEqual(fixture.model.other_machines, 0)
