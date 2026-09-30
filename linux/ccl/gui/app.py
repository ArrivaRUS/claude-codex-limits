"""Claude Codex Limits — tray app for Astra Linux (Fly / KDE Plasma), PyQt5 from the OS repo.

Click the tray icon → the panel (simple or Advanced view, as on the Mac). Right click → menu.
Limits are polled every 1/5/15 minutes; local logs are indexed and synced through the GitHub
gist every 10 minutes (the same code `ccl-sync push --auto` runs from the systemd timer).
"""

import math
import os
import shlex
import shutil
import subprocess
import sys
import threading
import time

from PyQt5.QtCore import QObject, QRectF, Qt, QTimer, QUrl, pyqtSignal
from PyQt5.QtGui import QCursor, QDesktopServices, QFont, QFontDatabase, QFontMetricsF, QGuiApplication, QPainter
from PyQt5.QtWidgets import (QAction, QApplication, QCheckBox, QComboBox, QFrame, QHBoxLayout, QLabel, QLineEdit,
                             QMenu, QPushButton, QScrollArea, QStackedWidget, QSystemTrayIcon, QVBoxLayout, QWidget)

from .. import APP_VERSION, common, limits, sync, update, vault, usage
from ..common import tr
from . import fmt, paint, panel, trayicon

HERE = os.path.dirname(os.path.dirname(os.path.dirname(os.path.realpath(__file__))))   # …/linux
LOGS_EVERY = 10 * 60

RESET_SOUNDS = [("rise", "Восход", "Sunrise", "snd-rise"), ("drop", "Капля", "Droplet", "snd-drop"),
                ("celebrate", "Праздник", "Celebrate", "snd-celebrate"), ("coin", "Монетка", "Coin", "snd-coin"),
                ("victory", "Победа", "Victory", "snd-victory"), ("chime", "Перезвон", "Chime", "snd-chime"),
                ("hop", "Прыжок", "Hop", "snd-hop")]
REACHED_SOUNDS = [("outage", "Отбой", "Lights out", "snd-outage"), ("sunset", "Закат", "Sunset", "snd-sunset"),
                  ("fadeout", "Угасание", "Fade out", "snd-fadeout")]

AUTOSTART = os.path.join(os.environ.get("XDG_CONFIG_HOME") or os.path.join(common.HOME, ".config"),
                         "autostart", "claude-codex-limits.desktop")


def _version_stamp():
    """(mtime, APP_VERSION) of the installed ccl/__init__.py, or None when it can't be read."""
    path = os.path.join(update.app_dir(), "ccl", "__init__.py")
    try:
        mtime = os.stat(path).st_mtime
        with open(path, encoding="utf-8") as f:
            return mtime, update.parse_version(f.read())
    except OSError:
        return None


STYLE = """
QWidget#page { background: transparent; }
QLabel { color: rgba(255,255,255,0.88); font-size: 12px; }
QLabel[role="cap"] { color: rgba(255,255,255,0.40); font-size: 10px; font-weight: 600; letter-spacing: 0.6px; }
QLabel[role="title"] { color: rgba(255,255,255,0.95); font-size: 16px; font-weight: 600; }
QLabel[role="note"] { color: rgba(255,255,255,0.50); font-size: 11px; }
QLabel[role="code"] { color: #FF9E2E; font-size: 22px; font-weight: 700; letter-spacing: 2px; }
QLabel[role="cmd"] { color: rgba(255,255,255,0.9); font-family: monospace; font-size: 11px;
                     background: rgba(255,255,255,0.07); border-radius: 6px; padding: 6px 8px; }
QFrame[role="card"] { background: rgba(255,255,255,0.04); border: 1px solid rgba(255,255,255,0.07); border-radius: 12px; }
QCheckBox { color: rgba(255,255,255,0.88); font-size: 12px; spacing: 8px; }
QComboBox, QLineEdit { color: white; background: rgba(255,255,255,0.08); border: 1px solid rgba(255,255,255,0.10);
                       border-radius: 6px; padding: 3px 8px; font-size: 12px; min-height: 20px; }
QComboBox QAbstractItemView { color: white; background: #2a2a2c; selection-background-color: #3a3a3e; }
QPushButton { color: white; background: rgba(255,255,255,0.09); border: 1px solid rgba(255,255,255,0.10);
              border-radius: 7px; padding: 4px 12px; font-size: 12px; }
QPushButton:hover { background: rgba(255,255,255,0.15); }
QPushButton[role="accent"] { background: rgba(255,158,46,0.18); border-color: rgba(255,158,46,0.5); color: #FF9E2E; font-weight: 600; }
QPushButton[role="link"] { background: transparent; border: none; color: #6B9EF5; padding: 2px 4px; }
QPushButton[role="pill"], QPushButton[role="pill-accent"] {
    border: none; border-radius: 8px; padding: 0 9px; min-height: 26px; max-height: 26px; font-size: 11px; }
QPushButton[role="pill"] { background: rgba(255,255,255,0.14); color: rgba(255,255,255,0.95); font-weight: 500; }
QPushButton[role="pill"]:hover { background: rgba(255,255,255,0.20); }
QPushButton[role="pill-accent"] { background: #FF9E2E; color: #1A1A1A; font-weight: 600; }
QPushButton[role="pill-accent"]:hover { background: #FFAD4D; }
QLabel[role="row"] { color: rgba(255,255,255,0.95); font-size: 13px; }
QLabel[role="busy"] { color: rgba(255,255,255,0.50); font-size: 12px; }
QLabel[role="status"] { color: rgba(255,255,255,0.34); font-size: 11px; }
QLabel[role="status-hot"] { color: #FF9E2E; font-size: 11px; }
QScrollArea { background: transparent; border: none; }
QScrollBar:vertical { background: transparent; width: 8px; }
QScrollBar::handle:vertical { background: rgba(255,255,255,0.18); border-radius: 4px; min-height: 30px; }
QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical { height: 0; }
"""


class Bridge(QObject):
    limits_done = pyqtSignal(object, object)
    logs_done = pyqtSignal(object, object)
    login_code = pyqtSignal(object, object)
    login_done = pyqtSignal(object, object, object)
    logout_done = pyqtSignal(bool, object)
    update_checked = pyqtSignal(object, object)
    update_done = pyqtSignal(object, object)


def play_sound(sid):
    for pool in (RESET_SOUNDS, REACHED_SOUNDS):
        for s in pool:
            if s[0] == sid:
                path = paint.res_path(s[3] + ".wav")
                if not path:
                    return
                for player in ("pw-play", "paplay", "aplay"):
                    exe = shutil.which(player)
                    if exe:
                        args = [exe, "-q", path] if player == "aplay" else [exe, path]
                        try:
                            subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                        except OSError:
                            continue
                        return
                return


# ---- the painted panel ----------------------------------------------------------------------

class PanelView(QWidget):
    def __init__(self, win):
        super().__init__()
        self.win = win
        self.hits = []
        self.setMouseTracking(True)
        self.setAttribute(Qt.WA_TranslucentBackground)

    def content_height(self):
        m = self.win.app.model
        return int(panel.advanced_height(m) if common.settings().get("advanced") else panel.simple_height(m))

    def paintEvent(self, _e):
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        p.setRenderHint(QPainter.TextAntialiasing)
        c = paint.Canvas(p)
        m = self.win.app.model
        W, H = self.width(), self.height()
        self.hits = (panel.draw_advanced if common.settings().get("advanced") else panel.draw_simple)(c, W, H, m)
        p.end()

    def hit(self, pos):
        for hid, r in self.hits:
            if r.contains(pos):
                return hid
        return None

    def mouseMoveEvent(self, e):
        self.setCursor(Qt.PointingHandCursor if self.hit(e.localPos()) else Qt.ArrowCursor)

    def mouseReleaseEvent(self, e):
        if e.button() == Qt.LeftButton:
            hid = self.hit(e.localPos())
            if hid:
                self.win.app.action(hid)


# ---- settings page (real widgets on the same dark panel) ------------------------------------

def _label(text, role=None, wrap=False):
    l = QLabel(text)
    if role:
        l.setProperty("role", role)
    l.setWordWrap(wrap or role == "cap")
    return l


class _ClickLabel(QLabel):
    def __init__(self, text, on_click):
        super().__init__(text)
        self._on_click = on_click
        self.setWordWrap(True)
        self.setCursor(Qt.PointingHandCursor)

    def mouseReleaseEvent(self, e):
        if e.button() == Qt.LeftButton:
            self._on_click()


class WrapCheck(QWidget):
    """A checkbox whose caption wraps. QCheckBox's own text never wraps, so a long caption (or
    a wider style such as Breeze) made the settings page wider than the popup, and the right
    edge ended up under the scroll bar."""
    toggled = pyqtSignal(bool)

    def __init__(self, text):
        super().__init__()
        h = QHBoxLayout(self)
        h.setContentsMargins(0, 0, 0, 0)
        h.setSpacing(8)
        self.box = QCheckBox()
        self.box.toggled.connect(self.toggled)
        h.addWidget(self.box, 0, Qt.AlignTop)
        h.addWidget(_ClickLabel(text, self.box.toggle), 1)

    def setChecked(self, on):
        self.box.setChecked(on)

    def isChecked(self):
        return self.box.isChecked()


class _Icon(QWidget):
    """One of the panel's vector icons (paint.Canvas.icon) as a widget — the SF Symbols of the
    Mac's settings rows."""

    def __init__(self, name, size=16):
        super().__init__()
        self.name = name
        self.setFixedSize(size, size)

    def paintEvent(self, _e):
        p = QPainter(self)
        p.setRenderHint(QPainter.Antialiasing)
        paint.Canvas(p).icon(self.name, QRectF(0.5, 0.5, self.width() - 1, self.height() - 1), paint.TEXT_MID, 1.3)
        p.end()


def _pill(text, accent=False):
    b = QPushButton(text)
    b.setProperty("role", "pill-accent" if accent else "pill")
    b.setCursor(Qt.PointingHandCursor)
    return b


def _fit_pill(b):
    """Text + padding, as the Mac sizes its pills; the style's own button margins would add
    another ~15 px. Measured with the font the stylesheet gives pills (11 px, medium / semibold,
    the application's family) — the page may not be polished yet when this runs."""
    f = QFont(b.font())
    f.setPixelSize(11)
    # what Qt makes of the stylesheet's font-weight 600 / 500
    f.setWeight(QFont.Bold if b.property("role") == "pill-accent" else QFont.DemiBold)
    b.setFixedWidth(int(math.ceil(QFontMetricsF(f).horizontalAdvance(b.text()))) + 20)


def _set_role(w, role):
    """Change a styled role on a live widget (the stylesheet is only re-applied on polish)."""
    w.setProperty("role", role)
    w.style().unpolish(w)
    w.style().polish(w)


def _card():
    f = QFrame()
    f.setProperty("role", "card")
    lay = QVBoxLayout(f)
    lay.setContentsMargins(12, 10, 12, 10)
    lay.setSpacing(8)
    return f, lay


def _combo(items=()):
    cb = QComboBox()
    # never let the longest item widen the page past the popup
    cb.setSizeAdjustPolicy(QComboBox.AdjustToMinimumContentsLengthWithIcon)
    cb.setMinimumContentsLength(11)
    for it in items:
        cb.addItem(it)
    return cb


def _clear(lay):
    """Empty a layout now: detach before deleteLater, or the old widgets stay painted (and
    counted in the layout's height) until the event loop gets round to deleting them."""
    while lay.count():
        it = lay.takeAt(0)
        w = it.widget()
        if w is not None:
            w.hide()
            w.setParent(None)
            w.deleteLater()


def _row(label, widget):
    w = QWidget()
    h = QHBoxLayout(w)
    h.setContentsMargins(0, 0, 0, 0)
    h.addWidget(_label(label))
    h.addStretch(1)
    h.addWidget(widget)
    return w


class SettingsPage(QWidget):
    def __init__(self, win):
        super().__init__()
        self.win = win
        self.app = win.app
        self.setObjectName("page")
        outer = QVBoxLayout(self)
        outer.setContentsMargins(12, 12, 6, 12)
        top = QHBoxLayout()
        back = QPushButton("‹ " + tr("Назад", "Back"))
        back.setProperty("role", "link")
        back.clicked.connect(lambda: self.win.show_page(0))
        top.addWidget(back)
        top.addStretch(1)
        top.addWidget(_label(tr("Настройки", "Settings"), "title"))
        top.addStretch(1)
        top.addSpacing(back.sizeHint().width())
        outer.addLayout(top)
        self.scroll = QScrollArea()
        self.scroll.setWidgetResizable(True)
        self.scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarAlwaysOff)
        self.body = QWidget()
        self.body.setObjectName("page")
        self.scroll.setWidget(self.body)
        self.scroll.viewport().setAutoFillBackground(False)
        self.body.setAutoFillBackground(False)
        outer.addWidget(self.scroll)
        self.build()

    def build(self):
        st = common.settings()
        lay = QVBoxLayout(self.body)
        lay.setContentsMargins(0, 4, 4, 4)
        lay.setSpacing(6)

        lay.addWidget(_label(tr("ОБЩИЕ", "GENERAL"), "cap"))
        card, cl = _card()
        self.lang = _combo(["Русский", "English"])
        self.lang.setCurrentIndex(1 if common.app_lang() == "en" else 0)
        self.lang.currentIndexChanged.connect(self.on_lang)
        cl.addWidget(_row(tr("Язык", "Language"), self.lang))
        self.autostart = WrapCheck(tr("Запускать при входе в систему", "Launch at login"))
        self.autostart.setChecked(os.path.exists(AUTOSTART))
        self.autostart.toggled.connect(self.app.set_autostart)
        cl.addWidget(self.autostart)
        self.view = _combo([tr("Простой", "Simple"), tr("Расширенный", "Advanced")])
        self.view.setCurrentIndex(1 if st.get("advanced") else 0)
        self.view.currentIndexChanged.connect(self.on_view)
        cl.addWidget(_row(tr("Вид панели", "Panel view"), self.view))
        lay.addWidget(card)

        lay.addWidget(_label(tr("В ТРЕЕ", "IN THE TRAY"), "cap"))
        card, cl = _card()
        opts = [("session", tr("Сессия 5 ч", "Session 5 h")), ("weekly", tr("Неделя", "Week")),
                ("model", tr("Неделя · ", "Week · ") + (common.state().get("scopedName") or tr("модель", "model")))]
        picks = trayicon.metrics()
        self.slots = []
        for i, name in enumerate((tr("Верхнее число", "Top number"), tr("Нижнее число", "Bottom number"))):
            cb = _combo()
            for key, text in opts:
                cb.addItem(text, key)
            if i == 1:
                cb.addItem(tr("— нет", "— none"), "")
            cur = picks[i] if i < len(picks) else ""
            idx = cb.findData(cur)
            cb.setCurrentIndex(idx if idx >= 0 else cb.count() - 1)
            cb.currentIndexChanged.connect(self.on_tray)
            self.slots.append(cb)
            cl.addWidget(_row(name, cb))
        self.codex_tray = WrapCheck(tr("Отдельный значок для Codex", "Separate icon for Codex"))
        self.codex_tray.setChecked(bool(st.get("codexTray")))
        self.codex_tray.toggled.connect(lambda on: (st.set("codexTray", on), self.app.update_tray()))
        cl.addWidget(self.codex_tray)
        cl.addWidget(_label(tr("Числа — Claude Code; если вход в Claude не выполнен, значок показывает Codex. "
                               "Полоска снизу: оранжевая — Claude, синяя — Codex.",
                               "Numbers are Claude Code; when Claude isn't signed in the icon shows Codex. "
                               "Bottom stripe: orange — Claude, blue — Codex."), "note", True))
        lay.addWidget(card)

        lay.addWidget(_label(tr("ПОДПИСКИ, $ В МЕСЯЦ", "SUBSCRIPTIONS, $ PER MONTH"), "cap"))
        card, cl = _card()
        self.subs = {}
        for key, name in (("subClaude", "Claude"), ("subCodex", "Codex")):
            e = QLineEdit()
            e.setFixedWidth(90)
            e.setPlaceholderText(tr("по плану", "from plan"))
            if st.has(key):
                e.setText(fmt.fmt_num(usage.clamp_number(st.get(key)), 2).replace(",", "."))
            e.editingFinished.connect(lambda k=key, w=e: self.on_sub(k, w))
            self.subs[key] = e
            cl.addWidget(_row(name, e))
        lay.addWidget(card)

        lay.addWidget(_label(tr("СИНХРОНИЗАЦИЯ ЧЕРЕЗ GITHUB", "SYNC THROUGH GITHUB"), "cap"))
        card, self.sync_lay = _card()
        self.sync_box = card
        lay.addWidget(card)
        self.render_sync()

        lay.addWidget(_label(tr("УВЕДОМЛЕНИЯ И ЗВУКИ", "NOTIFICATIONS & SOUNDS"), "cap"))
        card, cl = _card()
        notify = WrapCheck(tr("Уведомление, когда лимит исчерпан или сброшен", "Notify when a limit is reached or reset"))
        notify.setChecked(bool(st.get("notify")))
        notify.toggled.connect(lambda on: st.set("notify", on))
        cl.addWidget(notify)
        for key, choice_key, text, pool in (
                ("sound5h", "sound5hChoice", tr("Сброс окна 5 ч", "5-hour reset"), RESET_SOUNDS),
                ("sound7d", "sound7dChoice", tr("Сброс недели", "Weekly reset"), RESET_SOUNDS),
                ("reachedOn", "reachedChoice", tr("Лимит исчерпан", "Limit reached"), REACHED_SOUNDS)):
            w = QWidget()
            h = QHBoxLayout(w)
            h.setContentsMargins(0, 0, 0, 0)
            chk = WrapCheck(text)
            chk.setChecked(bool(st.get(key)))
            chk.toggled.connect(lambda on, k=key: st.set(k, on))
            h.addWidget(chk, 1)
            cb = _combo()
            cb.setMinimumContentsLength(9)
            for sid, ru, en, _f in pool:
                cb.addItem(tr(ru, en), sid)
            idx = cb.findData(st.get(choice_key))
            cb.setCurrentIndex(max(0, idx))
            cb.currentIndexChanged.connect(lambda _i, k=choice_key, c=cb: (st.set(k, c.currentData()), play_sound(c.currentData())))
            h.addWidget(cb)
            cl.addWidget(w)
        cl.addWidget(_label(tr("Выбор звука в списке сразу его проигрывает.", "Picking a sound plays it."), "note", True))
        lay.addWidget(card)

        # about: one row as on the Mac — ⓘ Version x.y.z … [action pills], a status line below
        lay.addWidget(_label(tr("О ПРИЛОЖЕНИИ", "ABOUT"), "cap"))
        card = QFrame()
        card.setProperty("role", "card")
        card.setMinimumHeight(44)
        h = QHBoxLayout(card)
        h.setContentsMargins(14, 8, 12, 8)
        h.setSpacing(0)
        h.addWidget(_Icon("info"), 0, Qt.AlignVCenter)
        h.addSpacing(10)
        h.addWidget(_label(tr("Версия ", "Version ") + APP_VERSION, "row"), 0, Qt.AlignVCenter)
        h.addStretch(1)
        self.upd_box = QWidget()
        self.upd_lay = QHBoxLayout(self.upd_box)
        self.upd_lay.setContentsMargins(6, 0, 0, 0)
        self.upd_lay.setSpacing(8)
        h.addWidget(self.upd_box, 0, Qt.AlignVCenter)
        lay.addWidget(card)
        self.upd_status = _label("", "status", True)
        self.upd_status.setContentsMargins(4, 0, 4, 0)
        lay.addWidget(self.upd_status)
        self.render_update()
        lay.addStretch(1)

    def render_update(self):
        """The right side of the About row and the status line under it (drawAbout on the Mac)."""
        _clear(self.upd_lay)
        a = self.app
        avail = a.model.update_available
        act = tr("Скачать", "Download") if update.is_packaged() else tr("Обновить", "Update")
        status, hot = None, False
        if a.update_state == "running":
            self.upd_lay.addWidget(_label(tr("Загрузка…", "Downloading…") if update.is_packaged()
                                          else tr("Обновление…", "Updating…"), "busy"))
        elif a.update_state == "checking":
            self.upd_lay.addWidget(_label(tr("Проверка…", "Checking…"), "busy"))
        elif avail:
            news = _pill(tr("Что нового", "What's new"))
            news.clicked.connect(lambda: a.action("open:" + update.changes_url()))
            go = _pill(act, accent=True)
            go.clicked.connect(a.apply_update)
            self.upd_lay.addWidget(news)
            self.upd_lay.addWidget(go)
            _fit_pill(news)
            _fit_pill(go)
            status, hot = tr("Доступна версия %s — нажмите «%s»", "Version %s available — tap «%s»") % (avail, act), True
        else:
            b = _pill(tr("Проверить обновление", "Check for updates"))
            b.clicked.connect(lambda: a.check_update(manual=True))
            self.upd_lay.addWidget(b)
            _fit_pill(b)
        if a.update_msg and a.update_state is None:
            status, hot = a.update_msg, a.update_msg_hot
        _set_role(self.upd_status, "status-hot" if hot else "status")
        self.upd_status.setText(status or "")
        self.upd_status.setVisible(bool(status))

    def on_lang(self, i):
        common.settings().set("lang", "en" if i == 1 else "ru")
        self.app.rebuild_ui()

    def on_view(self, i):
        common.settings().set("advanced", i == 1)
        self.app.refresh_logs()
        self.win.page0_changed()

    def on_tray(self, _i):
        picks = [cb.currentData() for cb in self.slots if cb.currentData()]
        out = []
        for p in picks:
            if p not in out:
                out.append(p)
        common.settings().set("trayMetrics", ",".join(out or ["session", "weekly"]))
        self.app.update_tray()

    def on_sub(self, key, w):
        t = w.text().strip().replace(",", ".").lstrip("$")
        st = common.settings()
        if not t:
            st.remove(key)
        else:
            try:
                st.set(key, usage.clamp_number(float(t)))
            except (ValueError, OverflowError):
                w.setText("")
                st.remove(key)
        self.win.view.update()

    # -- sync block --
    def render_sync(self):
        lay = self.sync_lay
        _clear(lay)
        a = self.app
        st = sync.sync_state()
        pending = sync.sign_out_incomplete(st)
        if pending or a.logout_busy or a.logout_error:
            if pending:
                lay.addWidget(_label(sync._delete_pending_text(), wrap=True))
            if a.logout_error and a.logout_error != (sync._delete_pending_text() if pending else None):
                lay.addWidget(_label(a.logout_error, "note", True))
            b = self._btn(tr("Выйти", "Sign out"), a.logout)
            b.setEnabled(not a.logout_busy)
            lay.addWidget(b)
            lay.addWidget(_label(self._logout_note(), "note", True))
            if a.logout_busy or a.logout_error:
                return
        if a.login_state == "awaiting":
            lay.addWidget(_label(tr("Откройте github.com/login/device и введите код:",
                                    "Open github.com/login/device and enter the code:"), wrap=True))
            code = _label(a.login_code or "…", "code")
            code.setTextInteractionFlags(Qt.TextSelectableByMouse)
            lay.addWidget(code)
            row = QHBoxLayout()
            b1 = QPushButton(tr("Открыть страницу", "Open the page"))
            b1.setProperty("role", "accent")
            b1.clicked.connect(lambda: QDesktopServices.openUrl(QUrl(a.login_uri or "https://github.com/login/device")))
            b2 = QPushButton(tr("Скопировать код", "Copy code"))
            b2.clicked.connect(lambda: QGuiApplication.clipboard().setText(a.login_code or ""))
            b3 = QPushButton(tr("Отмена", "Cancel"))
            b3.clicked.connect(a.cancel_login)
            for b in (b1, b2, b3):
                row.addWidget(b)
            w = QWidget()
            w.setLayout(row)
            lay.addWidget(w)
            lay.addWidget(_label(tr("Жду подтверждения в GitHub…", "Waiting for GitHub…"), "note"))
            return
        token, backend = vault.read() if st.get("login") and not st.get("revoked") and not pending else (None, None)
        if token:
            lay.addWidget(_row("GitHub: " + (st.get("login") or "?"), self._btn(tr("Выйти", "Sign out"), a.logout)))
            lay.addWidget(_label(self._logout_note(), "note", True))
            for mch in sync.machine_list():
                upd = mch.get("updated")
                when = (tr("обновлён ", "updated ") + fmt.fmt_reset(upd)) if upd else tr("ещё не отправлял", "not sent yet")
                lay.addWidget(_label(("● " if mch.get("self") else "○ ") + mch["name"]
                                     + (tr(" (эта)", " (this)") if mch.get("self") else "") + " · " + when, "note", True))
            # when sync last actually worked, and why it didn't since (docs/sync-protocol.md → Errors)
            upl, ok = st.get("pushedAt"), sync.last_ok_at(st)
            lay.addWidget(_label(tr("Последняя отправка: ", "Last upload: ") + (fmt.fmt_moment(upl) if upl else "—")
                                 + tr(" · чтение: ", " · read: ") + (fmt.fmt_moment(ok) if ok else "—"), "note", True))
            if st.get("lastError"):
                at = st.get("lastErrorAt")
                lay.addWidget(_label(tr("Ошибка ", "Error ") + (fmt.fmt_moment(at) + ": " if at else ": ")
                                     + str(st.get("lastError")), "note", True))
            lay.addWidget(_label(tr("Токен: ", "Token: ") + (tr("хранилище секретов (KWallet)", "Secret Service (KWallet)")
                                                             if backend == "secret-service" else common.TOKEN_FILE_PATH.replace(common.HOME, "~")),
                                 "note", True))
            name = QLineEdit(common.machine_name())
            name.setFixedWidth(150)
            name.editingFinished.connect(lambda w=name: (common.settings().set("machineName", w.text().strip() or None),
                                                         a.refresh_logs(force_push=True)))
            lay.addWidget(_row(tr("Имя этой машины", "This machine's name"), name))
            return
        if backend in ("timeout", "unreachable"):
            text = vault.timeout_text() if backend == "timeout" else tr(
                "Хранилище секретов недоступно", "The Secret Service is unreachable")
            lay.addWidget(_label(text + tr(" — синхронизация повторит попытку сама",
                                          " — sync will try again by itself"), wrap=True))
            return
        if backend == "locked":
            lay.addWidget(_label(tr("Токен GitHub лежит в хранилище секретов, но оно заблокировано — разблокируйте KWallet, "
                                    "синхронизация продолжится сама.",
                                    "The GitHub token is in the Secret Service, which is locked — unlock KWallet and sync "
                                    "resumes by itself."), wrap=True))
            return
        if st.get("revoked") and not pending:
            lay.addWidget(_label(tr("Вход в GitHub отозван — войдите заново.", "GitHub sign-in was revoked — sign in again."), wrap=True))
            upl, ok = st.get("pushedAt"), sync.last_ok_at(st)
            lay.addWidget(_label(tr("Последняя отправка: ", "Last upload: ") + (fmt.fmt_moment(upl) if upl else "—")
                                 + tr(" · чтение: ", " · read: ") + (fmt.fmt_moment(ok) if ok else "—"), "note", True))
            if st.get("lastError"):
                lay.addWidget(_label(str(st.get("lastError")), "note", True))
        lay.addWidget(_label(tr("Расход по дням и моделям (столбики, календарь, деньги) есть только в логах той машины, "
                                "где работал CLI. Синхронизация складывает его с Mac и другими ПК через ваш секретный gist.",
                                "Per-day usage (bars, calendar, money) lives only in the logs of the machine where the CLI ran. "
                                "Sync adds it up with your Mac and other PCs through your secret gist."), "note", True))
        if a.login_error:
            lay.addWidget(_label(a.login_error, "note", True))
        b = self._btn(tr("Войти через GitHub", "Sign in with GitHub"), a.start_login)
        b.setProperty("role", "accent")
        lay.addWidget(b)

    @staticmethod
    def _logout_note():
        return tr(
            "Вход удаляется только на этом компьютере. Отозвать доступ приложения полностью — github.com/settings/applications",
            "This signs out only this computer. To revoke the app's access entirely, visit github.com/settings/applications")

    @staticmethod
    def _btn(text, cb):
        b = QPushButton(text)
        b.clicked.connect(cb)
        return b


class FixPage(QWidget):
    """«Подключить Claude Code» / «Вход устарел» — Linux commands."""

    def __init__(self, win):
        super().__init__()
        self.win = win
        self.setObjectName("page")
        self.lay = QVBoxLayout(self)
        self.lay.setContentsMargins(16, 12, 16, 16)
        self.lay.setSpacing(8)

    def build(self, expired):
        # an expired login only needs `claude` → /login — unless the CLI isn't installed at all
        # (e.g. only the Claude desktop app, whose built-in Claude Code has its own sign-in)
        expired = expired and bool(shutil.which("claude") or os.path.exists(os.path.join(common.HOME, ".local", "bin", "claude")))
        _clear(self.lay)
        topw = QWidget()
        top = QHBoxLayout(topw)
        top.setContentsMargins(0, 0, 0, 0)
        back = QPushButton("‹ " + tr("Назад", "Back"))
        back.setProperty("role", "link")
        back.clicked.connect(lambda: self.win.show_page(0))
        top.addWidget(back)
        top.addStretch(1)
        self.lay.addWidget(topw)
        if expired:
            title = tr("Вход устарел", "Sign-in expired")
            intro = tr("Токен входа Claude Code CLI истёк, и обновить его нечем. Нужно войти заново — это полминуты.",
                       "The Claude Code CLI sign-in has expired and can't be refreshed. Signing in again takes half a minute.")
            steps = [(tr("1. Запустите Claude Code в терминале:", "1. Start Claude Code in a terminal:"), "claude"),
                     (tr("2. Внутри выполните команду входа:", "2. Inside, run the sign-in command:"), "/login"),
                     (tr("3. Войдите через браузер — Claude Code перезапишет ~/.claude/.credentials.json.",
                         "3. Sign in through the browser — Claude Code rewrites ~/.claude/.credentials.json."), None),
                     (tr("4. Вернитесь сюда и нажмите «Обновить».", "4. Come back here and press “Refresh”."), None)]
        else:
            title = tr("Подключить Claude Code", "Connect Claude Code")
            intro = tr("Лимиты читаются из входа Claude Code CLI (~/.claude/.credentials.json).",
                       "Limits are read from the Claude Code CLI login (~/.claude/.credentials.json).")
            steps = [(tr("1. Установите Claude Code CLI (если его ещё нет):", "1. Install the Claude Code CLI (if missing):"),
                      "curl -fsSL https://claude.ai/install.sh | bash"),
                     (tr("2. Если команда claude не находится — добавьте её в PATH и откройте новый терминал:",
                         "2. If claude isn't found, add it to PATH and open a new terminal:"),
                      "echo 'export PATH=\"$HOME/.local/bin:$PATH\"' >> ~/.bashrc"),
                     (tr("3. Запустите claude и войдите через браузер (или командой /login).",
                         "3. Run claude and sign in through the browser (or with /login)."), None),
                     (tr("4. Вернитесь сюда и нажмите «Обновить».", "4. Come back here and press “Refresh”."), None)]
        self.lay.addWidget(_label(title, "title"))
        self.lay.addWidget(_label(intro, wrap=True))
        for text, cmd in steps:
            self.lay.addWidget(_label(text, wrap=True))
            if cmd:
                row = QHBoxLayout()
                l = _label(cmd, "cmd", True)
                l.setTextInteractionFlags(Qt.TextSelectableByMouse)
                row.addWidget(l, 1)
                b = QPushButton(tr("Скопировать", "Copy"))
                b.clicked.connect(lambda _c=False, t=cmd, btn=b: (QGuiApplication.clipboard().setText(t),
                                                                   btn.setText(tr("Скопировано", "Copied"))))
                row.addWidget(b)
                w = QWidget()
                w.setLayout(row)
                self.lay.addWidget(w)
        self.lay.addWidget(_label(tr("Claude Code внутри настольного приложения Claude использует свой вход — монитору нужен "
                                     "именно вход CLI. Пока его нет, карточка Claude показывает эту подсказку; Codex и "
                                     "синхронизация расхода работают и без него.",
                                     "Claude Code inside the Claude desktop app has its own sign-in — the monitor needs the CLI "
                                     "login. Until then the Claude card shows this hint; Codex and the usage sync work without it."),
                                  "note", True))
        refresh = QPushButton(tr("Обновить", "Refresh"))
        refresh.setProperty("role", "accent")
        refresh.clicked.connect(lambda: (self.win.app.refresh_limits(), self.win.show_page(0)))
        self.lay.addWidget(refresh)
        self.lay.addStretch(1)


# ---- the popup window -----------------------------------------------------------------------

class PanelWindow(QWidget):
    def __init__(self, app):
        super().__init__(None, Qt.Popup | Qt.FramelessWindowHint | Qt.NoDropShadowWindowHint)
        self.app = app
        self.setAttribute(Qt.WA_TranslucentBackground)
        self.setStyleSheet(STYLE)
        self.stack = QStackedWidget(self)
        lay = QVBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.addWidget(self.stack)
        self.view = PanelView(self)
        self.settings_page = SettingsPage(self)
        self.fix = FixPage(self)
        for w in (self.view, self.settings_page, self.fix):
            self.stack.addWidget(w)
        self.last_hide = 0.0
        self.above = True
        self.anchor = None
        self.setFixedWidth(panel.PANEL_W)

    def paintEvent(self, _e):
        if self.stack.currentIndex() != 0:
            p = QPainter(self)
            p.setRenderHint(QPainter.Antialiasing)
            panel.background(paint.Canvas(p), self.width(), self.height(), (54, 26))
            p.end()

    def hideEvent(self, e):
        self.last_hide = time.time()
        super().hideEvent(e)

    def page_height(self):
        i = self.stack.currentIndex()
        if i == 0:
            return self.view.content_height()
        scr = self.screen_rect()
        if i == 1:
            return min(scr.height() - 40, 640)
        lay = self.fix.layout()
        need = lay.totalHeightForWidth(panel.PANEL_W) if lay.hasHeightForWidth() else self.fix.sizeHint().height()
        return min(scr.height() - 40, max(360, need + 8))

    def screen_rect(self):
        pos = self.anchor or QCursor.pos()
        s = QGuiApplication.screenAt(pos) or QGuiApplication.primaryScreen()
        return s.availableGeometry()

    def place(self):
        h = self.page_height()
        self.setFixedHeight(h)
        scr = self.screen_rect()
        a = self.anchor or QCursor.pos()
        self.above = a.y() > scr.center().y()
        y = a.y() - h - 10 if self.above else a.y() + 14
        x = a.x() - panel.PANEL_W // 2
        x = max(scr.left() + 6, min(x, scr.right() - panel.PANEL_W - 6))
        y = max(scr.top() + 6, min(y, scr.bottom() - h - 6))
        self.move(x, y)

    def show_page(self, i):
        if i == 1:
            self.settings_page.render_sync()
        self.stack.setCurrentIndex(i)
        if self.isVisible():
            self.place()
        self.update()

    def page0_changed(self):
        if self.isVisible() and self.stack.currentIndex() == 0:
            self.place()
        self.view.update()

    def toggle(self):
        if self.isVisible():
            self.hide()
            return
        if time.time() - self.last_hide < 0.35:      # the click that closed the popup
            return
        self.anchor = QCursor.pos()
        self.stack.setCurrentIndex(0)
        self.place()
        self.show()
        self.raise_()
        self.activateWindow()


# ---- the app ---------------------------------------------------------------------------------

class TrayApp(QObject):
    def __init__(self, qapp):
        super().__init__()
        self.qapp = qapp
        self.model = panel.Model()
        st = common.settings()
        self.model.interval = int(st.get("interval") or 60) if int(st.get("interval") or 60) in (60, 300, 900) else 60
        self.model.history.load()
        self.bridge = Bridge()
        self.bridge.limits_done.connect(self.on_limits)
        self.bridge.logs_done.connect(self.on_logs)
        self.bridge.login_code.connect(self.on_login_code)
        self.bridge.login_done.connect(self.on_login_done)
        self.bridge.logout_done.connect(self.on_logout_done)
        self.bridge.update_checked.connect(self.on_update_checked)
        self.bridge.update_done.connect(self.on_update_done)
        self.update_state = None
        self.update_msg = None
        self.update_msg_hot = False
        self.model.update_available = update.available()
        self.busy_limits = False
        self.busy_logs = False
        self.force_pending = False
        self.login_state = None
        self.login_code = None
        self.login_uri = None
        self.login_error = None
        self.login_attempt = None
        self.logout_busy = False
        self.logout_error = None
        self.sound_baseline = False

        self.win = PanelWindow(self)
        self.tray = QSystemTrayIcon()
        self.tray.activated.connect(self.on_activated)
        self.codex_tray = None
        self.build_menu()
        self.update_tray()
        self.tray.show()

        self.timer = QTimer(self)
        self.timer.timeout.connect(self.refresh_limits)
        self.timer.start(self.model.interval * 1000)
        self.logs_timer = QTimer(self)
        self.logs_timer.timeout.connect(self.refresh_logs)
        self.logs_timer.start(LOGS_EVERY * 1000)
        self.load_local()
        self.refresh_limits()
        QTimer.singleShot(1500, self.refresh_logs)
        self.update_timer = QTimer(self)
        self.update_timer.timeout.connect(lambda: self.check_update(manual=False))
        self.update_timer.start(3600 * 1000)             # hourly tick; the check itself runs every 6 h
        QTimer.singleShot(20000, lambda: self.check_update(manual=False))
        self.disk_stamp = _version_stamp()
        self.disk_timer = QTimer(self)
        self.disk_timer.timeout.connect(self.check_disk_version)
        self.disk_timer.start(60 * 1000)
        if update.is_packaged() and not common.state().get("pkgAutostartSet"):
            # the .deb can't reach into home folders: the first launch turns autostart on,
            # as install.sh does; after that the Settings checkbox is the user's
            self.set_autostart(True)
            common.state().set("pkgAutostartSet", True)

    # -- menu / tray --
    def build_menu(self):
        """One menu for the app's lifetime; later calls only retitle actions and show/hide the
        update item. Rebuilding it makes Plasma's DBusMenu exporter chase destroyed actions."""
        if getattr(self, "menu", None) is None:
            self.menu = QMenu()
            # attach first: Qt's DBusMenu exporter only learns about actions added afterwards
            self.tray.setContextMenu(self.menu)
            self.act = {}
            for key, cb in (("open", lambda: self.win.toggle()),
                            ("refresh", lambda: (self.refresh_limits(), self.refresh_logs())),
                            ("settings", self.open_settings),
                            ("update", self.apply_update)):
                a = QAction("", self.menu)
                a.triggered.connect(cb)
                self.menu.addAction(a)
                self.act[key] = a
            self.menu.addSeparator()
            self.act["quit"] = QAction("", self.menu)
            self.act["quit"].triggered.connect(self.qapp.quit)
            self.menu.addAction(self.act["quit"])
        self.act["open"].setText(tr("Открыть панель", "Open panel"))
        self.act["refresh"].setText(tr("Обновить", "Refresh"))
        self.act["settings"].setText(tr("Настройки…", "Settings…"))
        self.act["quit"].setText(tr("Выход", "Quit"))
        avail = self.model.update_available
        self.act["update"].setText(tr("Обновить до ", "Update to ") + (avail or ""))
        self.act["update"].setVisible(bool(avail))

    def open_settings(self):
        if not self.win.isVisible():
            self.win.toggle()
        self.win.show_page(1)

    def on_activated(self, reason):
        if reason == QSystemTrayIcon.Trigger:
            self.win.toggle()
        elif reason == QSystemTrayIcon.MiddleClick:
            self.refresh_limits()

    def update_tray(self):
        m = self.model
        claude, codex = m.claude, m.codex
        st = common.settings()
        rows = trayicon.values(claude) if claude.present else []
        mark = trayicon.CLAUDE_MARK
        separate = bool(st.get("codexTray")) and codex.present
        if not rows and codex.present and not separate:
            rows, mark = trayicon.values(codex, ["session", "weekly"]), trayicon.CODEX_MARK
        if not m.loaded:
            rows, mark = [], None
        self.tray.setIcon(trayicon.make_icon(rows, mark))
        tip = trayicon.tooltip(claude, codex) if m.loaded else "Claude Codex Limits"
        self.tray.setToolTip(tip)
        if separate:
            if self.codex_tray is None:
                self.codex_tray = QSystemTrayIcon()
                self.codex_tray.activated.connect(self.on_activated)
                # its own QMenu (sharing the actions): one QMenu exported by two tray icons
                # confuses the DBusMenu exporter ("No id for action")
                self.codex_menu = QMenu()
                self.codex_tray.setContextMenu(self.codex_menu)
                for key in ("open", "refresh", "settings", "update"):
                    self.codex_menu.addAction(self.act[key])
                self.codex_menu.addSeparator()
                self.codex_menu.addAction(self.act["quit"])
            self.codex_tray.setIcon(trayicon.make_icon(trayicon.values(codex, ["session", "weekly"]), trayicon.CODEX_MARK))
            self.codex_tray.setToolTip(tip)
            self.codex_tray.show()
        elif self.codex_tray is not None:
            self.codex_tray.hide()
            self.codex_tray.deleteLater()
            self.codex_tray = None

    def rebuild_ui(self):
        """Language switch: rebuild the widgets that hold translated text."""
        visible = self.win.isVisible()
        page = self.win.stack.currentIndex()
        self.win.hide()
        self.win.deleteLater()
        self.win = PanelWindow(self)
        self.build_menu()
        self.update_tray()
        if visible:
            self.win.toggle()
            self.win.show_page(page)

    # -- actions from the panel --
    def action(self, hid):
        st = common.settings()
        if hid == "refresh":
            self.refresh_limits()
            self.refresh_logs()
        elif hid == "settings":
            self.win.show_page(1)
        elif hid == "claudefix":
            self.win.fix.build(self.model.claude.auth == limits.EXPIRED)
            self.win.show_page(2)
        elif hid.startswith("open:"):
            QDesktopServices.openUrl(QUrl(hid[5:]))
            self.win.hide()
        elif hid.startswith("iv"):
            sec = int(hid[2:])
            self.model.interval = sec
            st.set("interval", sec)
            self.timer.start(sec * 1000)
            self.win.view.update()
        elif hid == "quit":
            self.qapp.quit()
        elif hid == "hist:toggle":
            st.set("advHistExpanded", not st.get("advHistExpanded"))
            self.win.page0_changed()
        elif hid.startswith("hist:"):
            st.set("advHistProduct", hid[5:])
            self.win.page0_changed()

    def set_autostart(self, on):
        if on:
            os.makedirs(os.path.dirname(AUTOSTART), exist_ok=True)
            if update.is_packaged():
                # TryExec: once the package is removed, the session skips the entry
                run = ["Exec=/usr/bin/claude-codex-limits", "TryExec=/usr/bin/claude-codex-limits",
                       "Icon=claude-codex-limits"]
            else:
                run = ['Exec=/usr/bin/python3 "%s"' % os.path.join(HERE, "claude-codex-limits"),
                       "Icon=" + (paint.res_path("appicon.png") or "")]
            common.write_atomic(AUTOSTART, "\n".join([
                "[Desktop Entry]", "Type=Application", "Name=Claude Codex Limits",
                "Comment=" + tr("Лимиты Claude Code и Codex в трее", "Claude Code & Codex limits in the tray")]
                + run + ["Terminal=false", "X-GNOME-Autostart-enabled=true", "X-KDE-autostart-after=panel", ""]), 0o644)
        else:
            try:
                os.unlink(AUTOSTART)
            except OSError:
                pass

    # -- workers --
    def refresh_limits(self):
        if self.busy_limits:
            return
        self.busy_limits = True

        def one(fetch):
            try:
                return fetch()
            except Exception as e:  # never let one product's failure blank the other
                d = limits.LimitData()
                d.error = str(e) or e.__class__.__name__
                return d

        def work():
            claude = one(limits.fetch_claude)
            codex = one(lambda: limits.fetch_codex(live=True))
            try:
                claude, codex = limits.apply_cache(claude, codex)
            except Exception:
                pass
            self.bridge.limits_done.emit(claude, codex)
        threading.Thread(target=work, daemon=True).start()

    def on_limits(self, claude, codex):
        self.busy_limits = False
        m = self.model
        m.claude, m.codex = claude, codex
        m.loaded = True
        m.updated = time.time()
        m.history.record(claude, "claude")
        m.history.record(codex, "codex")
        self.update_sync_warning()           # «стоит с HH:mm» ages with the clock, not only with syncs
        self.check_alarms(claude, codex)
        self.update_tray()
        self.win.page0_changed()

    def load_local(self):
        ix = usage.load_index()
        self.apply_days(ix["days"], sync.load_remote())

    def apply_days(self, local_days, remote):
        m = self.model
        m.local_days = local_days
        # signed in and not revoked → add the other machines. Decided from the sync state, not
        # from a keyring read: this runs on the GUI thread, and a revoked sign-in is not hidden
        # here — update_sync_warning says it on the main screen.
        st = sync.sync_state()
        if remote.get("machines") and st.get("login") and not st.get("revoked"):
            m.days = usage.merge_days(local_days, remote.get("days", {}))
            m.other_machines = len(remote.get("machines", []))
        else:
            m.days = local_days
            m.other_machines = 0
        self.update_sync_warning(st)

    def update_sync_warning(self, st=None):
        try:
            self.model.sync_warning = sync.warning(st, moment=fmt.fmt_moment)
        except Exception:
            self.model.sync_warning = None

    def refresh_logs(self, force_push=False):
        if force_push:
            self.force_pending = True
        if self.busy_logs:
            return                          # a queued force is picked up when this pass ends
        self.busy_logs = True
        force_push = self.force_pending
        self.force_pending = False

        def work():
            remote = None
            try:
                ix, _changed, fresh = usage.refresh(blocking=False)
                # another process (the timer) is scanning right now and will sync the fresh
                # index itself — pushing our older copy would only hold its write back 10 min
                res = sync.sync_cycle(ix["days"], force=force_push, auto=not force_push) if fresh else None
                remote = sync.load_remote()
                days = ix["days"]
            except Exception as e:
                days, remote = usage.load_index()["days"], sync.load_remote()
                sync.record_error(str(e) or e.__class__.__name__)
                res = None
            self.bridge.logs_done.emit(days, (remote, res, force_push))
        threading.Thread(target=work, daemon=True).start()

    def on_logs(self, days, payload):
        self.busy_logs = False
        remote, res, forced = payload
        if forced and (res is None or res.skipped == "busy"):
            self.force_pending = True       # the timer was mid-scan/sync — try again shortly
        if self.force_pending:
            QTimer.singleShot(20000, self.refresh_logs)
        self.apply_days(days, remote)
        self.win.page0_changed()
        if self.win.isVisible() and self.win.stack.currentIndex() == 1 and self.login_state is None:
            self.win.settings_page.render_sync()

    # -- GitHub sign-in (Device Flow) --
    def start_login(self):
        if self.logout_busy:
            return
        attempt = self.login_attempt = sync.begin_login()
        self.login_state, self.login_code, self.login_error = "awaiting", None, None
        self.logout_error = None
        self.win.settings_page.render_sync()

        def work():
            cancelled = lambda: not sync.is_current(attempt)
            try:
                dev = sync.device_start()
                self.bridge.login_code.emit(attempt, dev)
                token = sync.device_poll(dev, cancelled=cancelled)
                login = sync.login_finish(token, cancelled=cancelled, attempt=attempt)
                self.bridge.login_done.emit(attempt, login, None)
            except sync.LoginError as e:
                self.bridge.login_done.emit(attempt, None, None if str(e) == "cancelled" else str(e))
            except Exception as e:
                self.bridge.login_done.emit(attempt, None, str(e))
        threading.Thread(target=work, daemon=True).start()

    def on_login_code(self, attempt, dev):
        if attempt != self.login_attempt or not sync.is_current(attempt):
            return
        self.login_code = dev.get("user_code")
        self.login_uri = dev.get("verification_uri")
        QDesktopServices.openUrl(QUrl(self.login_uri))
        self.win.settings_page.render_sync()

    def on_login_done(self, attempt, login, error):
        if attempt != self.login_attempt or not sync.is_current(attempt):
            return
        self.login_state = None
        self.login_error = error
        if self.win.isVisible():
            self.win.settings_page.render_sync()
        if login:
            self.refresh_logs(force_push=True)

    def cancel_login(self):
        sync.cancel_login(self.login_attempt)
        self.login_state = None
        self.win.settings_page.render_sync()

    def logout(self):
        if self.logout_busy:
            return
        sync.cancel_login(self.login_attempt)
        self.login_state = None
        self.logout_busy, self.logout_error = True, None
        self.win.settings_page.render_sync()

        def work():
            try:
                ok = sync.logout()
                error = None if ok else sync._delete_pending_text()
            except sync.LoginError as e:
                ok, error = False, str(e)
            except Exception as e:
                ok, error = False, str(e)
            self.bridge.logout_done.emit(ok, error)
        threading.Thread(target=work, daemon=True).start()

    def on_logout_done(self, ok, error):
        self.logout_busy = False
        self.logout_error = error if not ok else None
        self.load_local()
        self.win.settings_page.render_sync()
        self.win.page0_changed()

    # -- self-update from the repository's main branch --
    def check_update(self, manual=False):
        if self.update_state is not None or update.is_checkout() and not manual:
            return
        if not manual and not update.due():
            return
        self.update_state = "checking"
        if manual:
            self.update_msg = None
            self.win.settings_page.render_update()

        def work():
            try:
                latest, err = update.check()
            except Exception as e:
                latest, err = None, str(e)
            self.bridge.update_checked.emit((latest, err), manual)
        threading.Thread(target=work, daemon=True).start()

    def on_update_checked(self, res, manual):
        self.update_state = None
        latest, err = res
        self.model.update_available = update.available()
        if manual:
            self.update_msg_hot = False
            if err:
                self.update_msg = tr("Не удалось проверить обновление (%s)", "Couldn't check for updates (%s)") % err
            elif not self.model.update_available:
                self.update_msg = tr("Установлена последняя версия (%s)", "You're on the latest version (%s)") % APP_VERSION
            else:
                self.update_msg = None
        self.build_menu()
        self.win.page0_changed()
        if self.win.isVisible() and self.win.stack.currentIndex() == 1:
            self.win.settings_page.render_update()

    def apply_update(self):
        if self.update_state is not None:
            return
        if update.is_checkout():
            self.update_msg = tr("Запущено из git-копии — обновляйте её через git pull.", "Running from a git checkout — use git pull.")
            self.update_msg_hot = False
            self.win.settings_page.render_update()
            return
        self.update_state = "running"
        self.update_msg = None
        self.win.settings_page.render_update()

        def work():
            try:
                if update.is_packaged():
                    _ver, path = update.fetch_deb()
                    self.bridge.update_done.emit(("deb", path), None)
                else:
                    new, _out = update.apply()
                    self.bridge.update_done.emit(new, None)
            except Exception as e:
                self.bridge.update_done.emit(None, str(e))
        threading.Thread(target=work, daemon=True).start()

    def on_update_done(self, new, err):
        self.update_state = None
        if err:
            self.update_msg, self.update_msg_hot = err, False
            if self.win.isVisible():
                self.win.settings_page.render_update()
            return
        if isinstance(new, tuple):
            # root installs the package, not us: hand it to the system package installer;
            # check_disk_version() restarts the icon once dpkg has put the new files in place
            path = new[1]
            if QDesktopServices.openUrl(QUrl.fromLocalFile(path)):
                self.update_msg = tr("Готово — в открывшемся установщике нажмите «Установить»",
                                     "Ready — press «Install» in the package installer")
            else:
                self.update_msg = tr("Пакет в «Загрузках». Установите: sudo apt install ",
                                     "The package is in Downloads. Install it: sudo apt install ") + shlex.quote(path)
            self.update_msg_hot = True
            if self.win.isVisible():
                self.win.settings_page.render_update()
            return
        self.restart()

    def restart(self):
        """Start the installed version in this process's place (the single-instance lock fd is
        close-on-exec, so the new image takes it over)."""
        script = os.path.join(update.app_dir(), "claude-codex-limits")
        if not os.path.exists(script):
            return
        self.tray.hide()
        if self.codex_tray is not None:
            self.codex_tray.hide()
        os.execv(sys.executable, [sys.executable, script])

    def check_disk_version(self):
        """A package upgrade (or a re-run of install.sh) replaced the files under us: restart
        into the new version — a little later, so dpkg has finished moving files in."""
        stamp = _version_stamp()
        if stamp is None or stamp == self.disk_stamp:
            return
        self.disk_stamp = stamp
        if stamp[1] and stamp[1] != APP_VERSION and self.update_state is None:
            QTimer.singleShot(10000, self.restart)

    # -- reset / limit sounds (port of checkAlarms) --
    def check_alarms(self, claude, codex):
        st, ss = common.state(), common.settings()
        events, upd = limits.detect_alarms(claude, codex, st.data, self.sound_baseline)
        if upd:
            st.update(**upd)
        self.sound_baseline = True
        resets = [e for e in events if e["kind"] == "reset"]
        reached = [e for e in events if e["kind"] == "reached"]
        if any(e["is5h"] for e in resets) and ss.get("sound5h"):
            play_sound(ss.get("sound5hChoice"))
        elif any(not e["is5h"] for e in resets) and ss.get("sound7d"):
            play_sound(ss.get("sound7dChoice"))
        if reached and ss.get("reachedOn"):
            play_sound(ss.get("reachedChoice"))
        if ss.get("notify"):
            for e in reached + resets:
                self.notify(e)

    def notify(self, e):
        """Desktop notification (org.freedesktop.Notifications through the tray icon)."""
        if e["kind"] == "reached":
            title = e["product"] + tr(": лимит исчерпан", ": limit reached")
            body = e["window"] + " — 100%" + ((tr(". Сброс ", ". Resets ") + fmt.fmt_reset(e["reset"])) if e["reset"] else "")
            icon = QSystemTrayIcon.Warning
        else:
            title = e["product"] + tr(": лимит сброшен", ": limit reset")
            body = e["window"] + tr(" — снова доступно", " — available again")
            icon = QSystemTrayIcon.Information
        tray = self.codex_tray if (e["product"] == "Codex" and self.codex_tray is not None) else self.tray
        tray.showMessage(title, body, icon, 15000)


def _share_session_bus():
    """The sync timer reads the GitHub token from the keyring over D-Bus. Some sessions start
    the systemd user manager without the bus address; hand it over (best effort)."""
    try:
        r = subprocess.run(["systemctl", "--user", "show-environment"], stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, timeout=5)
        if r.returncode == 0 and b"DBUS_SESSION_BUS_ADDRESS=" not in r.stdout and os.environ.get("DBUS_SESSION_BUS_ADDRESS"):
            subprocess.run(["systemctl", "--user", "import-environment", "DBUS_SESSION_BUS_ADDRESS"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
    except (OSError, subprocess.SubprocessError):
        pass


def pick_family():
    fams = set(QFontDatabase().families())
    for f in ("Noto Sans", "PT Astra Sans", "Roboto"):
        if f in fams:
            return f
    return QApplication.font().family()


def main(argv=None):
    argv = argv if argv is not None else sys.argv
    common.ensure_dirs()
    import fcntl
    lock_fd = os.open(os.path.join(common.STATE_DIR, "app.lock"), os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print(tr("Claude Codex Limits уже запущен.", "Claude Codex Limits is already running."))
        return 0
    QApplication.setAttribute(Qt.AA_EnableHighDpiScaling, True)
    QApplication.setAttribute(Qt.AA_UseHighDpiPixmaps, True)
    qapp = QApplication(argv)
    qapp.setApplicationName("Claude Codex Limits")
    qapp.setDesktopFileName("claude-codex-limits")        # notifications carry the app's name/icon
    qapp.setQuitOnLastWindowClosed(False)
    res_dirs = [os.path.join(HERE, "Resources"), os.path.join(os.path.dirname(HERE), "Resources")]
    paint.RES_DIRS[:] = [d for d in res_dirs if os.path.isdir(d)]
    paint.FAMILY[0] = pick_family()
    paint.MONO[0] = "DejaVu Sans Mono"
    icon = paint.res_path("appicon.png")
    if icon:
        from PyQt5.QtGui import QIcon
        qapp.setWindowIcon(QIcon(icon))
    if not QSystemTrayIcon.isSystemTrayAvailable():
        # the panel may still be starting (autostart) — wait a little before giving up
        for _ in range(30):
            time.sleep(1)
            if QSystemTrayIcon.isSystemTrayAvailable():
                break
    _share_session_bus()
    app = TrayApp(qapp)
    qapp._ccl = app
    return qapp.exec_()
