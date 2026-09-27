"""Claude Codex Limits — tray app for Astra Linux (Fly / KDE Plasma), PyQt5 from the OS repo.

Click the tray icon → the panel (simple or Advanced view, as on the Mac). Right click → menu.
Limits are polled every 1/5/15 minutes; local logs are indexed and synced through the GitHub
gist every 10 minutes (the same code `ccl-sync push --auto` runs from the systemd timer).
"""

import os
import shutil
import subprocess
import sys
import threading
import time

from PyQt5.QtCore import QObject, QRectF, Qt, QTimer, QUrl, pyqtSignal
from PyQt5.QtGui import QCursor, QDesktopServices, QFontDatabase, QGuiApplication, QPainter
from PyQt5.QtWidgets import (QAction, QApplication, QCheckBox, QComboBox, QFrame, QHBoxLayout, QLabel, QLineEdit,
                             QMenu, QPushButton, QScrollArea, QStackedWidget, QSystemTrayIcon, QVBoxLayout, QWidget)

from .. import APP_VERSION, REPO_URL, common, limits, sync, vault, usage
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
QScrollArea { background: transparent; border: none; }
QScrollBar:vertical { background: transparent; width: 8px; }
QScrollBar::handle:vertical { background: rgba(255,255,255,0.18); border-radius: 4px; min-height: 30px; }
QScrollBar::add-line:vertical, QScrollBar::sub-line:vertical { height: 0; }
"""


class Bridge(QObject):
    limits_done = pyqtSignal(object, object)
    logs_done = pyqtSignal(object, object)
    login_code = pyqtSignal(object)
    login_done = pyqtSignal(object, object)


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
        self.autostart = QCheckBox(tr("Запускать при входе в систему", "Launch at login"))
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
        self.codex_tray = QCheckBox(tr("Отдельный значок для Codex", "Separate icon for Codex"))
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
                e.setText(fmt.fmt_num(float(st.get(key)), 2).replace(",", "."))
            e.editingFinished.connect(lambda k=key, w=e: self.on_sub(k, w))
            self.subs[key] = e
            cl.addWidget(_row(name, e))
        lay.addWidget(card)

        lay.addWidget(_label(tr("СИНХРОНИЗАЦИЯ ЧЕРЕЗ GITHUB", "SYNC THROUGH GITHUB"), "cap"))
        card, self.sync_lay = _card()
        self.sync_box = card
        lay.addWidget(card)
        self.render_sync()

        lay.addWidget(_label(tr("ЗВУКИ", "SOUNDS"), "cap"))
        card, cl = _card()
        for key, choice_key, text, pool in (
                ("sound5h", "sound5hChoice", tr("Сброс 5-часового окна", "5-hour window reset"), RESET_SOUNDS),
                ("sound7d", "sound7dChoice", tr("Сброс недели", "Weekly reset"), RESET_SOUNDS),
                ("reachedOn", "reachedChoice", tr("Лимит исчерпан", "Limit reached"), REACHED_SOUNDS)):
            w = QWidget()
            h = QHBoxLayout(w)
            h.setContentsMargins(0, 0, 0, 0)
            chk = QCheckBox(text)
            chk.setChecked(bool(st.get(key)))
            chk.toggled.connect(lambda on, k=key: st.set(k, on))
            h.addWidget(chk)
            h.addStretch(1)
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

        lay.addWidget(_label(tr("О ПРИЛОЖЕНИИ", "ABOUT"), "cap"))
        card, cl = _card()
        cl.addWidget(_label("Claude Codex Limits · Linux %s" % APP_VERSION, wrap=True))
        link = QPushButton(REPO_URL.replace("https://", ""))
        link.setProperty("role", "link")
        link.clicked.connect(lambda: self.app.action("open:" + REPO_URL))
        cl.addWidget(link)
        cl.addWidget(_label(tr("Данные: ", "Data: ") + common.STATE_DIR.replace(common.HOME, "~"), "note", True))
        lay.addWidget(card)
        lay.addStretch(1)

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
                st.set(key, max(0.0, float(t)))
            except ValueError:
                w.setText("")
                st.remove(key)
        self.win.view.update()

    # -- sync block --
    def render_sync(self):
        lay = self.sync_lay
        _clear(lay)
        a = self.app
        st = sync.sync_state()
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
        token, backend = vault.read()
        if token:
            lay.addWidget(_row("GitHub: " + (st.get("login") or "?"), self._btn(tr("Выйти", "Sign out"), a.logout)))
            for mch in sync.machine_list():
                upd = mch.get("updated")
                when = (tr("обновлён ", "updated ") + fmt.fmt_reset(upd)) if upd else tr("ещё не отправлял", "not sent yet")
                lay.addWidget(_label(("● " if mch.get("self") else "○ ") + mch["name"]
                                     + (tr(" (эта)", " (this)") if mch.get("self") else "") + " · " + when, "note", True))
            if st.get("lastError"):
                lay.addWidget(_label(tr("Ошибка: ", "Error: ") + str(st.get("lastError")), "note", True))
            lay.addWidget(_label(tr("Токен: ", "Token: ") + (tr("хранилище секретов (KWallet)", "Secret Service (KWallet)")
                                                             if backend == "secret-service" else common.TOKEN_FILE_PATH.replace(common.HOME, "~")),
                                 "note", True))
            name = QLineEdit(common.machine_name())
            name.setFixedWidth(150)
            name.editingFinished.connect(lambda w=name: (common.settings().set("machineName", w.text().strip() or None),
                                                         a.refresh_logs(force_push=True)))
            lay.addWidget(_row(tr("Имя этой машины", "This machine's name"), name))
            return
        if st.get("revoked"):
            lay.addWidget(_label(tr("Вход в GitHub отозван — войдите заново.", "GitHub sign-in was revoked — sign in again."), wrap=True))
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
                l = _label(cmd, "cmd")
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
        return min(scr.height() - 40, max(420, self.fix.sizeHint().height()))

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
        self.busy_limits = False
        self.busy_logs = False
        self.login_state = None
        self.login_code = None
        self.login_uri = None
        self.login_error = None
        self.login_cancel = False
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

    # -- menu / tray --
    def build_menu(self):
        menu = QMenu()
        for text, cb in ((tr("Открыть панель", "Open panel"), self.win.toggle),
                         (tr("Обновить", "Refresh"), lambda: (self.refresh_limits(), self.refresh_logs())),
                         (tr("Настройки…", "Settings…"), self.open_settings)):
            a = QAction(text, menu)
            a.triggered.connect(cb)
            menu.addAction(a)
        menu.addSeparator()
        q = QAction(tr("Выход", "Quit"), menu)
        q.triggered.connect(self.qapp.quit)
        menu.addAction(q)
        self.menu = menu
        self.tray.setContextMenu(menu)

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
                self.codex_tray.setContextMenu(self.menu)
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
            exe = os.path.join(HERE, "claude-codex-limits")
            icon = paint.res_path("appicon.png") or ""
            common.write_atomic(AUTOSTART, "\n".join([
                "[Desktop Entry]", "Type=Application", "Name=Claude Codex Limits",
                "Comment=" + tr("Лимиты Claude Code и Codex в трее", "Claude Code & Codex limits in the tray"),
                'Exec=/usr/bin/python3 "%s"' % exe, "Icon=" + icon, "Terminal=false",
                "X-GNOME-Autostart-enabled=true", "X-KDE-autostart-after=panel", ""]), 0o644)
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

        def work():
            try:
                claude = limits.fetch_claude()
                codex = limits.fetch_codex(live=True)
                claude, codex = limits.apply_cache(claude, codex)
            except Exception as e:  # never let a worker kill the tray
                claude, codex = limits.LimitData(), limits.LimitData()
                claude.error = codex.error = str(e)
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
        self.check_alarms(claude, codex)
        self.update_tray()
        self.win.page0_changed()

    def load_local(self):
        ix = usage.load_index()
        self.apply_days(ix["days"], sync.load_remote())

    def apply_days(self, local_days, remote):
        m = self.model
        m.local_days = local_days
        token, _ = vault.read() if remote.get("machines") else (None, None)
        if token:
            m.days = usage.merge_days(local_days, remote.get("days", {}))
            m.other_machines = len(remote.get("machines", []))
        else:
            m.days = local_days
            m.other_machines = 0

    def refresh_logs(self, force_push=False):
        if self.busy_logs:
            return
        self.busy_logs = True

        def work():
            remote = None
            try:
                ix, _changed = usage.refresh(blocking=False)
                res = sync.sync_cycle(ix["days"], force=force_push, auto=not force_push)
                remote = sync.load_remote()
                days = ix["days"]
            except Exception as e:
                days, remote = usage.load_index()["days"], sync.load_remote()
                sync.sync_state().set("lastError", str(e))
                res = None
            self.bridge.logs_done.emit(days, (remote, res))
        threading.Thread(target=work, daemon=True).start()

    def on_logs(self, days, payload):
        self.busy_logs = False
        remote, _res = payload
        self.apply_days(days, remote)
        self.win.page0_changed()
        if self.win.isVisible() and self.win.stack.currentIndex() == 1 and self.login_state is None:
            self.win.settings_page.render_sync()

    # -- GitHub sign-in (Device Flow) --
    def start_login(self):
        self.login_state, self.login_code, self.login_error, self.login_cancel = "awaiting", None, None, False
        self.win.settings_page.render_sync()

        def work():
            try:
                dev = sync.device_start()
                self.bridge.login_code.emit(dev)
                token = sync.device_poll(dev, cancelled=lambda: self.login_cancel)
                login = sync.login_finish(token)
                self.bridge.login_done.emit(login, None)
            except sync.LoginError as e:
                self.bridge.login_done.emit(None, None if str(e) == "cancelled" else str(e))
            except Exception as e:
                self.bridge.login_done.emit(None, str(e))
        threading.Thread(target=work, daemon=True).start()

    def on_login_code(self, dev):
        self.login_code = dev.get("user_code")
        self.login_uri = dev.get("verification_uri")
        QDesktopServices.openUrl(QUrl(self.login_uri))
        self.win.settings_page.render_sync()

    def on_login_done(self, login, error):
        self.login_state = None
        self.login_error = error
        if self.win.isVisible():
            self.win.settings_page.render_sync()
        if login:
            self.refresh_logs(force_push=True)

    def cancel_login(self):
        self.login_cancel = True
        self.login_state = None
        self.win.settings_page.render_sync()

    def logout(self):
        sync.logout()
        self.load_local()
        self.win.settings_page.render_sync()
        self.win.page0_changed()

    # -- reset / limit sounds (port of checkAlarms) --
    def check_alarms(self, claude, codex):
        st, ss = common.state(), common.settings()
        wins = [("rst_c5", "use_c5", claude.session_reset, claude.session, True),
                ("rst_x5", "use_x5", codex.session_reset, codex.session, True),
                ("rst_c7", "use_c7", claude.weekly_reset, claude.weekly, False),
                ("rst_x7", "use_x7", codex.weekly_reset, codex.weekly, False)]
        if claude.scoped:
            k = claude.scoped.name.lower()
            wins.append(("rst_cs_" + k, "use_cs_" + k, claude.scoped.reset, claude.scoped.percent, False))
        fired5 = fired7 = False
        upd = {}
        for rkey, ukey, date, used, is5 in wins:
            if date is None:
                continue
            old_r = float(st.get(rkey) or 0)
            rolled = old_r > 0 and date > old_r + 60
            if used is not None:
                old_u = float(st.get(ukey) or 0)
                if self.sound_baseline and rolled and old_u > 0 and used <= old_u + 0.5:
                    if is5:
                        fired5 = True
                    else:
                        fired7 = True
                upd[ukey] = used
            upd[rkey] = date
        reach = [("rch_c5", claude.session), ("rch_x5", codex.session), ("rch_c7", claude.weekly), ("rch_x7", codex.weekly)]
        if claude.scoped:
            reach.append(("rch_cs_" + claude.scoped.name.lower(), claude.scoped.percent))
        fired_reached = False
        for key, used in reach:
            if used is None:
                continue
            now_r = used >= 99.5
            if now_r and not st.get(key):
                fired_reached = True
            upd[key] = now_r
        if upd:
            st.update(**upd)
        first = not self.sound_baseline
        self.sound_baseline = True
        if not first:
            if fired5 and ss.get("sound5h"):
                play_sound(ss.get("sound5hChoice"))
            elif fired7 and ss.get("sound7d"):
                play_sound(ss.get("sound7dChoice"))
        if fired_reached and ss.get("reachedOn"):
            play_sound(ss.get("reachedChoice"))


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
    app = TrayApp(qapp)
    qapp._ccl = app
    return qapp.exec_()
