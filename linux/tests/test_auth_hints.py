"""Auth recovery versus paused snapshots: offline contract and actual draw regressions."""
if __package__:
    from . import _isolate  # noqa: F401
else:
    import _isolate  # noqa: F401

import ast
import copy
import math
import time
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from ccl import common, limits, sync, usage, vault
from ccl.gui import fmt

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
try:
    from PyQt5.QtGui import QImage, QPainter
    from PyQt5.QtWidgets import QApplication
    from ccl.gui import panel
    from ccl.gui.paint import Canvas
    HAVE_QT = True
    helpers = vars(panel)
except ImportError:
    HAVE_QT = False
    # Pure contracts remain runnable without pretending that Qt draw was checked.
    path = Path(__file__).resolve().parents[1] / "ccl" / "gui" / "panel.py"
    names = {"limit_can_fix", "limit_auth_badge", "limit_paused_notice",
             "limit_simple_stale_copy", "notice_h", "adv_verdict", "limit_poll_failed",
             "limit_retry_notice", "limit_snapshot_notice", "limit_data_badge"}
    nodes = [node for node in ast.parse(path.read_text()).body
             if isinstance(node, ast.FunctionDef) and node.name in names]
    helpers = {"limits": limits, "tr": common.tr, "fmt": fmt, "NOTICE": 19, "math": math, "time": time}
    exec(compile(ast.Module(body=nodes, type_ignores=[]), str(path), "exec"), helpers)

NOW = 1_800_000_000.0
CODEX_TARGET = "open:https://chatgpt.com/codex/cloud/settings/analytics#usage"
CLAUDE_TARGET = "open:https://claude.ai/settings/usage"


def reading(kind="fresh"):
    d = limits.LimitData()
    d.session, d.weekly, d.as_of = 31.0, 47.0, NOW - 60
    d.session_reset, d.weekly_reset = NOW + 7200, NOW + 86400
    if kind == "age":
        d.as_of = NOW - 14401
    elif kind == "network":
        d.as_of, d.error = NOW - 1800, "offline fixture"
    elif kind == "reset":
        d.session_reset = d.weekly_reset = NOW - 3600
    elif kind == "no-asof":
        d.as_of = None
    elif kind == "empty":
        d.session = d.weekly = d.as_of = None
    elif kind == "read-error-empty":
        d.auth = limits.READ_ERROR
        d.session = d.weekly = d.as_of = None
    elif kind in (limits.EXPIRED, limits.LOGGED_OUT, limits.READ_ERROR):
        d.auth, d.as_of = kind, NOW - 7200
    return d


class OfflineAuthCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.st = common.Store(os.path.join(self.tmp.name, "settings.json"), common.SETTINGS_DEFAULTS)
        state = common.Store(os.path.join(self.tmp.name, "state.json"), {})

        def forbidden(*args, **kwargs):
            raise AssertionError("real credentials, keyring, logs or API forbidden")

        for owner, name, value in ((common, "_settings", self.st), (common, "_state", state),
                                   (common, "HISTORY_PATH", os.path.join(self.tmp.name, "history.jsonl")),
                                   (vault, "_ss", forbidden), (vault, "read", forbidden),
                                   (vault, "_file_get", forbidden), (sync, "sync_cycle", forbidden),
                                   (common, "http", forbidden), (sync, "transport", forbidden),
                                   (limits, "fetch_claude", forbidden), (limits, "fetch_codex", forbidden),
                                   (usage, "refresh", forbidden), (limits.time, "time", lambda: NOW)):
            p = patch.object(owner, name, value)
            p.start()
            self.addCleanup(p.stop)


class TestAuthCopy(OfflineAuthCase):
    def test_confirmed_claude_auth_is_only_recovery_case(self):
        for lang in ("ru", "en"):
            self.st.set("lang", lang)
            badges = ("данные устарели", "нет входа", "вход истёк", "нет доступа") if lang == "ru" else (
                "stale data", "signed out", "sign-in expired", "read failed")
            for auth, badge in zip((limits.OK, limits.LOGGED_OUT, limits.EXPIRED, limits.READ_ERROR), badges):
                self.assertEqual(helpers["limit_auth_badge"](auth), badge)
                for product in ("claude", "codex"):
                    self.assertEqual(helpers["limit_can_fix"](product, auth),
                                     product == "claude" and auth in (limits.LOGGED_OUT, limits.EXPIRED))

    def test_nil_timestamp_never_becomes_current_time(self):
        for lang in ("ru", "en"):
            self.st.set("lang", lang)
            notice = "Нет свежих данных · темп не считаем" if lang == "ru" else "No fresh data · pace paused"
            self.assertEqual(helpers["limit_paused_notice"](None), notice)
            self.assertEqual(helpers["adv_verdict"]({"kind": "stale", "limit": None}, None), notice)
            snapshot, action = helpers["limit_simple_stale_copy"](reading("no-asof"), "codex")
            self.assertEqual(snapshot, "Нет свежих данных" if lang == "ru" else "No fresh data")
            self.assertEqual(action, "темп не считаем" if lang == "ru" else "pace paused")

    def test_paused_ok_remains_neutral_and_notice_rows_follow_auth(self):
        for lang in ("ru", "en"):
            self.st.set("lang", lang)
            for product in ("claude", "codex"):
                for kind in ("age", "network", "reset", "no-asof", "empty", limits.EXPIRED,
                             limits.LOGGED_OUT, limits.READ_ERROR):
                    d = reading(kind)
                    recover = product == "claude" and kind in (limits.EXPIRED, limits.LOGGED_OUT)
                    _, action = helpers["limit_simple_stale_copy"](d, product)
                    if recover:
                        self.assertEqual(action, "Вход устарел · Как починить?" if lang == "ru" else "Sign-in expired · How to fix?")
                    else:
                        expected = (("Сбой · повтор по расписанию" if lang == "ru" else "Failed · scheduled retry")
                                    if kind == "network" else
                                    ("темп не считаем" if lang == "ru" else "pace paused") if d.as_of is None else
                                    ("обновите данные" if lang == "ru" else "refresh data"))
                        self.assertEqual(action, expected)
                    card = {"product": product, "data": d, "paused": True}
                    self.assertEqual(helpers["notice_h"](card), 38 if recover or kind == "network" else 19)
                    card["paused"] = False
                    # Every card carries observation-time metadata; failed polls add one retry row.
                    self.assertEqual(helpers["notice_h"](card), 38 if recover or kind == "network" else 19)


@unittest.skipUnless(HAVE_QT, "PyQt5 not installed: actual auth draw/hits unverified")
class TestAuthDraw(OfflineAuthCase):
    @classmethod
    def setUpClass(cls):
        cls.qapp = QApplication.instance() or QApplication([])

    def render(self, model, advanced, filename):
        h = panel.advanced_height(model) if advanced else panel.simple_height(model)
        image = QImage(panel.PANEL_W, int(h), QImage.Format_ARGB32)
        painter = QPainter(image)
        texts = []
        before = copy.deepcopy((vars(model.claude), vars(model.codex)))
        original = Canvas.text

        def observe(canvas, attr, x, top, align=0):
            # Keep the original Attr/list and args: flattened strings cannot be drawn.
            texts.append(("".join(run.s for run in canvas._runs(attr)), x, top, align))
            return original(canvas, attr, x, top, align)

        try:
            with patch.object(Canvas, "text", observe), \
                 patch.object(common.Store, "set", side_effect=AssertionError("draw writes settings")), \
                 patch.object(common, "write_json", side_effect=AssertionError("draw writes files")):
                draw = panel.draw_advanced if advanced else panel.draw_simple
                hits = draw(Canvas(painter), panel.PANEL_W, h, model)
        finally:
            painter.end()
        self.assertEqual((vars(model.claude), vars(model.codex)), before)
        for _, rect in hits:
            self.assertGreaterEqual(rect.top(), 0)
            self.assertLessEqual(rect.bottom(), h)
        output = os.environ.get("CCL_PREVIEW_DIR")
        if output:
            os.makedirs(output, exist_ok=True)
            self.assertTrue(image.save(os.path.join(output, filename + ".png")))
        return hits, texts

    def model(self, product, kind, both):
        self.st.update(monitor_claude=both or product == "claude", monitor_codex=both or product == "codex")
        m = panel.Model()
        m.loaded = True
        m.claude, m.codex = reading(), reading()
        setattr(m, product, reading(kind))
        return m

    def product_text(self, texts, model, product, advanced, both):
        if advanced:
            top = 58.0
            for card in panel.adv_cards(model):
                if card["product"] == product:
                    return [text for text, _, y, _ in texts if top <= y < top + panel.card_h(card)]
                top += panel.card_h(card) + 5
            self.fail("missing product card")
        return [text for text, x, y, _ in texts if 58 <= y < 210
                and (not both or (x < 180 if product == "claude" else x >= 180))]

    def test_codex_stale_actual_copy_targets_and_percentages(self):
        for lang in ("ru", "en"):
            self.st.set("lang", lang)
            for advanced in (False, True):
                for both in (False, True):
                    for kind in ("age", "network", "reset", "no-asof", "empty"):
                        with self.subTest(lang=lang, advanced=advanced, both=both, kind=kind):
                            m = self.model("codex", kind, both)
                            hits, texts = self.render(m, advanced, "auth-codex-%s-%s-%s-%s" % (kind, lang, advanced, both))
                            card_text = self.product_text(texts, m, "codex", advanced, both)
                            self.assertIn(CODEX_TARGET, dict(hits))
                            self.assertNotIn("claudefix", dict(hits))
                            self.assertFalse(any("login" in text.lower() or "вход" in text.lower() for text in card_text))
                            self.assertFalse(any("claude" in text.lower() for text in card_text))
                            if kind != "empty":
                                self.assertTrue(any("31%" in text for text in card_text), card_text)
                                self.assertTrue(any("47%" in text for text in card_text), card_text)
                            else:
                                self.assertFalse(any("%" in text for text in card_text), card_text)
                            if advanced:
                                badge = ("сбой обновления" if lang == "ru" else "update failed") if kind == "network" else (
                                    "данные устарели" if lang == "ru" else "stale data")
                                self.assertIn(badge, card_text)
                                self.assertIn(panel.limit_snapshot_notice(m.codex), card_text)
                            else:
                                snapshot, action = panel.limit_simple_stale_copy(m.codex, "codex")
                                self.assertIn(snapshot, card_text)
                                self.assertIn(action, card_text)

    def test_claude_auth_only_recovery_and_paused_ok_is_neutral(self):
        for lang in ("ru", "en"):
            self.st.set("lang", lang)
            for advanced in (False, True):
                for both in (False, True):
                    for kind in (limits.EXPIRED, limits.LOGGED_OUT, limits.READ_ERROR, "read-error-empty", "age"):
                        with self.subTest(lang=lang, advanced=advanced, both=both, kind=kind):
                            m = self.model("claude", kind, both)
                            hits, texts = self.render(m, advanced, "auth-claude-%s-%s-%s-%s" % (kind, lang, advanced, both))
                            card_text = self.product_text(texts, m, "claude", advanced, both)
                            recover = kind in (limits.EXPIRED, limits.LOGGED_OUT)
                            self.assertEqual("claudefix" in dict(hits), recover)
                            if not recover:
                                self.assertIn(CLAUDE_TARGET, dict(hits))
                            if advanced:
                                self.assertEqual("claude → /login" in card_text, recover)
                                self.assertIn(panel.limit_auth_badge(m.claude.auth), card_text)
                                card = panel.adv_cards(m)[0]
                                self.assertEqual(panel.notice_h(card), 38 if recover else 19)
                            if kind == "age":
                                self.assertFalse(any("login" in text.lower() or "вход" in text.lower() for text in card_text))
                            if kind == "read-error-empty":
                                self.assertFalse(any("%" in text or "/login" in text for text in card_text), card_text)
                                self.assertIsNone(m.claude.as_of)
                                self.assertIsNone(m.claude.session)
                                self.assertIsNone(m.claude.weekly)
                                if advanced:
                                    self.assertIn("Нет свежих данных · темп не считаем" if lang == "ru"
                                                  else "No fresh data · pace paused", card_text)
                            if both:
                                self.assertIn(CODEX_TARGET, dict(hits))

    def test_both_problem_cards_keep_recovery_in_claude_area(self):
        for lang in ("ru", "en"):
            self.st.set("lang", lang)
            for advanced in (False, True):
                for claude_auth in (limits.EXPIRED, limits.LOGGED_OUT):
                    with self.subTest(lang=lang, advanced=advanced, auth=claude_auth):
                        m = self.model("codex", "age", True)
                        m.claude = reading(claude_auth)
                        hits, texts = self.render(m, advanced, "auth-both-%s-%s-%s" % (claude_auth, lang, advanced))
                        codex_text = self.product_text(texts, m, "codex", advanced, True)
                        claude_text = self.product_text(texts, m, "claude", advanced, True)
                        self.assertFalse(any("claude" in text.lower() or "login" in text.lower()
                                             or "вход" in text.lower() for text in codex_text), codex_text)
                        self.assertTrue(any("31%" in text for text in codex_text), codex_text)
                        self.assertTrue(any("47%" in text for text in codex_text), codex_text)
                        boxes = dict(hits)
                        self.assertIn(CODEX_TARGET, boxes)
                        self.assertIn("claudefix", boxes)
                        self.assertNotIn(CLAUDE_TARGET, boxes)
                        if advanced:
                            self.assertIn("claude → /login", claude_text)
                            self.assertIn("данные устарели" if lang == "ru" else "stale data", codex_text)
                            claude_card = panel.adv_cards(m)[0]
                            codex_top = 58 + panel.card_h(claude_card) + 5
                            self.assertLess(boxes["claudefix"].bottom(), codex_top)
                            self.assertGreaterEqual(boxes[CODEX_TARGET].center().y(), codex_top)
                        else:
                            self.assertTrue(any("Как починить?" in text or "How to fix?" in text for text in claude_text))
                            self.assertLessEqual(boxes["claudefix"].right(), 180)
                            self.assertGreaterEqual(boxes[CODEX_TARGET].left(), 180)

    def test_fresh_cards_have_no_recovery_or_paused_copy(self):
        for lang in ("ru", "en"):
            self.st.set("lang", lang)
            for advanced in (False, True):
                m = self.model("codex", "fresh", True)
                hits, texts = self.render(m, advanced, "auth-fresh-%s-%s" % (lang, advanced))
                self.assertIn(CODEX_TARGET, dict(hits))
                self.assertIn(CLAUDE_TARGET, dict(hits))
                self.assertNotIn("claudefix", dict(hits))
                self.assertTrue(all(panel.notice_h(card) == 19 for card in panel.adv_cards(m)))
                self.assertFalse(any("stale data" in text or "данные устарели" in text or "/login" in text
                                     for text, _, _, _ in texts))


if __name__ == "__main__":
    unittest.main()
