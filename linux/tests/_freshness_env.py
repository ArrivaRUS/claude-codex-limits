"""FRESH-4H fixtures: no Qt/app construction, real credentials, logs or transport.

AST extraction runs original function bodies only; graphics are recording fakes.
It checks behavior/paint arguments, not pixels or actual Qt layout.
"""
if __package__:
    from . import _isolate
else:
    import _isolate

import ast
import math
import os
import socket
import subprocess
import tempfile
import time
import unittest
from pathlib import Path
from types import MethodType, SimpleNamespace
from unittest.mock import Mock, patch

from ccl import common, limits, polling, quota_refresh, sync, usage, vault
from ccl.gui import fmt

NOW = 1_800_000_000.0
LINUX = Path(__file__).resolve().parents[1]


def extract(path, names, namespace, owner=None):
    tree = ast.parse(path.read_text())
    nodes = tree.body if owner is None else next(n for n in tree.body if isinstance(n, ast.ClassDef) and n.name == owner).body
    selected = [n for n in nodes if isinstance(n, ast.FunctionDef) and n.name in names]
    if {n.name for n in selected} != set(names):
        raise AssertionError('production test seam missing: ' + str(names))
    exec(compile(ast.Module(body=selected, type_ignores=[]), str(path), 'exec'), namespace)
    return namespace


def reading(age=60, weekly_only=False):
    d = limits.LimitData()
    d.as_of = NOW - age
    d.weekly, d.weekly_reset = 47.0, d.as_of + 84 * 3600
    if not weekly_only:
        d.session, d.session_reset = 31.0, d.as_of + 4.5 * 3600
    return d


class Rect:
    def __init__(self, x, y, w, h):
        self.x, self.y, self.w, self.h = x, y, w, h

    def left(self): return self.x
    def center(self): return SimpleNamespace(y=lambda: self.y + self.h / 2)


class Attr:
    def __init__(self, s, size=10, weight='regular', color=None):
        self.s, self.color = s, color

    def width(self): return len(self.s) * 5


class Canvas:
    def __init__(self):
        self.texts, self.gauges = [], []

    def text(self, attr, *args, **kwargs): self.texts.append((attr.s, attr.color))
    text_c = text
    def gauge(self, x, y, radius, width, used, color): self.gauges.append((used, color))
    def round_fill(self, *args): pass
    def round_stroke(self, *args): pass
    def image(self, *args): pass
    def icon(self, *args): pass
    def dot(self, *args): pass


def panel_helpers():
    # Execute exact pure functions with fake drawing; never import the Qt app here.
    ns = dict(limits=limits, common=common, tr=common.tr, fmt=fmt,
              time=time, math=math, quota_refresh=quota_refresh, NOTICE=19, FEEDBACK_H=32,
              CLAUDE_URL='fixture:claude', CODEX_URL='fixture:codex',
              TEXT_MID='mid', AMBER='amber')
    return extract(LINUX / 'ccl/gui/panel.py', (
        'limit_can_fix', 'limit_auth_badge', 'limit_paused_notice',
        'limit_reset_text', 'limit_poll_failed', 'limit_retry_notice', 'feedback_countdown', 'feedback_action', 'feedback_moment', 'feedback_copy',
        'limit_data_badge', 'adv_cards', 'adv_verdict', 'notice_h', 'shows_scoped_row'), ns)


def simple_card(d, product='codex'):
    ns = panel_helpers()
    c = Canvas()
    ns.update(c=c, m=SimpleNamespace(codex=d if product == 'codex' else None, loaded=True,
                                    pending_products=set()), hits=[], cards_top=58, card_h=184,
              rect_tl=Rect, QRectF=Rect, Attr=Attr,
              gray=lambda *x: ('gray',) + x, with_alpha=lambda col, alpha: (col, alpha),
              metric_color=lambda base, v: (base, v), scoped_color=lambda v: ('scoped', v),
              BLUE='blue', LINK='link', PURPLE='purple', AMBER='amber', TEXT_LO='low', TEXT_MID='mid',
              SCOPED_ROW_H=15)
    extract(LINUX / 'ccl/gui/panel.py', ('draw_feedback',), ns)
    tree = ast.parse((LINUX / 'ccl/gui/panel.py').read_text())
    outer = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == 'draw_simple')
    inner = next(n for n in outer.body if isinstance(n, ast.FunctionDef) and n.name == 'draw_card')
    exec(compile(ast.Module(body=[inner], type_ignores=[]), 'production draw_card', 'exec'), ns)
    ns['draw_card'](16, 328, d, product, 'fixture.png', 'fixture:url', product)
    return c


def tray_values(d, picks):
    ns = dict(common=common, limits=limits, QColor=lambda *rgba: tuple(rgba))
    extract(LINUX / 'ccl/gui/trayicon.py', ('metrics', 'sev_color', 'scoped_color', 'values'), ns)
    return ns['values'](d, picks)


def app_methods(names):
    return extract(LINUX / 'ccl/gui/app.py', names,
                   dict(time=time, math=math, common=common, limits=limits, polling=polling,
                        quota_refresh=quota_refresh, Qt=SimpleNamespace(PreciseTimer=0),
                        panel=SimpleNamespace(poll_interval=lambda x: int(x)),
                        threading=SimpleNamespace(Thread=Mock(side_effect=AssertionError('worker forbidden')))),
                   owner='TrayApp')


def bind_owner(fake, ns):
    """Bind public app seams to an inert owner; no constructor, workers or transport."""
    if not hasattr(fake, 'refresh_states'):
        fake.refresh_states = {p: quota_refresh.RefreshState(state.last_attempt)
                               for p, state in fake.poll_states.items()}
    if not hasattr(fake, 'timer'): fake.timer = RecordingTimer()
    if not hasattr(fake, 'win'):
        fake.win = SimpleNamespace(view=SimpleNamespace(update=Mock()), page0_changed=Mock())
    for name in ('scheduled_at', 'publish_auto_intervals', 'start_poll_timer'):
        if name in ns and not hasattr(fake, name):
            setattr(fake, name, MethodType(ns[name], fake))
    return fake


def refresh_method():
    return app_methods(('refresh_limits', 'scheduled_at', 'publish_auto_intervals', 'start_poll_timer'))


class OfflineCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='ccl-freshness-')
        self.addCleanup(self.tmp.cleanup)
        self.settings = common.Store(os.path.join(self.tmp.name, 'settings.json'), common.SETTINGS_DEFAULTS)
        self.settings.update(lang='en', monitor_claude=True, monitor_codex=True, autoPoll=True)
        self.state = common.Store(os.path.join(self.tmp.name, 'state.json'), {})
        def forbidden(*args, **kwargs):
            raise AssertionError('unmocked credentials/transport/logs/process forbidden')
        for owner, names in ((vault, ('_ss', '_ss_v2', 'read', '_file_get')),
                             (sync, ('sync_cycle', 'transport', 'auth_owner')),
                             (common, ('http',)), (usage, ('refresh', 'load_index')),
                             (limits, ('codex_access_token', '_rollout_files', '_read_json_retry', '_rewrite_json')),
                             (socket, ('create_connection',)), (subprocess, ('Popen', 'run'))):
            for name in names:
                p = patch.object(owner, name, forbidden); p.start(); self.addCleanup(p.stop)
        for name, value in (('_settings', self.settings), ('_state', self.state),
                            ('HISTORY_PATH', os.path.join(self.tmp.name, 'history.jsonl')),
                            ('CACHE_PATH', os.path.join(self.tmp.name, 'cache.json')),
                            ('CODEX_AUTH', os.path.join(self.tmp.name, 'missing-auth.json')),
                            ('CODEX_SESSIONS', self.tmp.name)):
            p = patch.object(common, name, value); p.start(); self.addCleanup(p.stop)
        p = patch.object(limits.time, 'time', return_value=NOW); p.start(); self.addCleanup(p.stop)
        p = patch.object(limits.time, 'monotonic', lambda: limits.time.time()); p.start(); self.addCleanup(p.stop)


def publish_callbacks():
    return app_methods(('on_limits', 'publish_auto_intervals', 'scheduled_at', 'start_poll_timer'))


class RecordingTimer:
    def __init__(self): self.milliseconds = -1
    def setSingleShot(self, value): self.single = value
    def setTimerType(self, value): pass
    def start(self, milliseconds): self.milliseconds = milliseconds
    def remainingTime(self): return self.milliseconds


def interval_handlers():
    ns = app_methods(('action', 'start_poll_timer', 'publish_auto_intervals', 'refresh_limits', 'scheduled_at'))
    extract(LINUX / 'ccl/gui/app.py', ('toggle',), ns, owner='PanelWindow')
    ns['QCursor'] = SimpleNamespace(pos=lambda: (0, 0))
    return ns
