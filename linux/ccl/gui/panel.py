"""The panel — ports of `drawPanel` (simple view) and `drawAdvanced` («Темп» view).

Geometry, colours and wording follow the Swift reference; both views return hit rectangles
(id, QRectF) that the window uses for clicks.
"""

import time
import math

from PyQt5.QtCore import QPointF, QRectF, Qt
from PyQt5.QtGui import QBrush, QLinearGradient, QPainterPath, QPen, QRadialGradient

from .. import APP_AUTHOR, APP_VERSION, REPO_URL, common, limits, usage, quota_refresh
from ..common import tr
from . import fmt
from .paint import (AMBER, BLUE, CRIT, LINK, MODEL, PURPLE, SCOPED, TEXT_HI, TEXT_LO, TEXT_MID, WARN,
                    Attr, caps, gray, rect_tl, rgb, with_alpha)

PANEL_W = 360
PANEL_H = 286
SCOPED_ROW_H = 15
FEEDBACK_H = 32
CLAUDE_URL = "https://claude.ai/settings/usage"
CODEX_URL = "https://chatgpt.com/codex/cloud/settings/analytics#usage"
CREDIT = "Claude Codex Limits %s · by %s · " % (APP_VERSION, APP_AUTHOR)

# Refresh intervals match macOS; old 1/5-minute choices migrate to 30 minutes.
POLL_CHOICES = (900, 1800, 3600, 14400)
POLL_DEFAULT = 1800


def poll_interval(value):
    """A stored or clicked interval, clamped to the choices: anything else (the old 60/300, junk) → 30 min."""
    try:
        sec = int(value)
    except (TypeError, ValueError, OverflowError):
        return POLL_DEFAULT
    return sec if sec in POLL_CHOICES else POLL_DEFAULT


def poll_segments():
    return [(tr("%dч", "%dh") % (sec // 3600) if sec >= 3600 else tr("%dм", "%dm") % (sec // 60), sec)
            for sec in POLL_CHOICES] + [(tr("А", "A"), 0)]


def highlighted_intervals(m):
    """Actual enabled-provider intervals, independent of request retry deadlines."""
    enabled = [p for p in ("claude", "codex") if common.product_enabled(p)]
    if not enabled:
        return set()
    if common.settings().get("autoPoll"):
        return {m.auto_intervals.get(p) for p in enabled} & set(POLL_CHOICES)
    return {m.interval}


def interval_name(sec):
    return {900: tr("15 минут", "15 minutes"), 1800: tr("30 минут", "30 minutes"),
            3600: tr("1 час", "1 hour"), 14400: tr("4 часа", "4 hours")}.get(sec, "—")


def no_subscriptions():
    return tr("Нет включённых подписок", "No subscriptions enabled")


def interval_tooltip(m, sec):
    if not any(common.product_enabled(p) for p in ("claude", "codex")):
        return no_subscriptions()
    label = interval_name(sec)
    if common.settings().get("autoPoll"):
        names = [name for p, name in (("claude", "Claude Code"), ("codex", "Codex"))
                 if common.product_enabled(p) and m.auto_intervals.get(p) == sec]
        if names:
            label += " · " + ", ".join(names)
    return label


class Model(object):
    """Everything the panel draws from."""

    def __init__(self):
        self.claude = limits.LimitData()
        self.codex = limits.LimitData()
        self.claude.present = self.codex.present = False
        self.loaded = False
        self.interval = POLL_DEFAULT
        self.auto_intervals = {}
        self.pending_products = set()    # enabled providers with reserved worker flights
        self.updated = None
        self.history = limits.History()
        self.days = {}            # merged usage days (local + other machines)
        self.local_days = {}
        self.other_machines = 0
        self.sync_warning = None         # sync stalled / sign-in revoked → orange line in «История и деньги»
        self.update_available = None     # newer Linux version on main → orange dot on the gear


def background(c, W, H, glow_at):
    p = c.p
    path = QPainterPath()
    path.addRoundedRect(QRectF(0.5, 0.5, W - 1, H - 1), 18, 18)
    p.save()
    p.setClipPath(path)
    g = QLinearGradient(0, 0, 0, H)
    g.setColorAt(0, gray(0.16, 1))
    g.setColorAt(1, gray(0.075, 1))
    p.fillRect(QRectF(0, 0, W, H), QBrush(g))
    rg = QRadialGradient(QPointF(*glow_at), 170)
    rg.setColorAt(0, rgb(1, 0.5, 0.2, 0.10))
    rg.setColorAt(1, rgb(1, 0.5, 0.2, 0))
    p.fillRect(QRectF(0, 0, W, H), QBrush(rg))
    p.restore()
    p.setBrush(Qt.NoBrush)
    p.setPen(QPen(gray(1, 0.08), 1))
    p.drawPath(path)


def update_badge(c, gear):
    """The orange "update available" dot on the gear, with a dark halo for contrast."""
    x, y = gear.right() - 5, gear.top() - 1
    c.dot(x, y + 3.5, gray(0.10, 1), r=5)
    c.dot(x, y + 3.5, AMBER, r=3.5)


def metric_color(base, v):
    s = limits.severity(v)
    return CRIT if s == 2 else rgb(1, 0.62, 0.04) if s == 1 else base


def scoped_color(pct):
    if pct >= 80:
        return rgb(0.98, 0.22, 0.56)
    if pct >= 50:
        return rgb(0.99, 0.47, 0.38)
    return SCOPED


def shows_scoped_row(d):
    return d.present and d.scoped is not None and d.auth == limits.OK and not limits.is_stale(d)


def simple_height(m):
    prods = products(m)
    extra = SCOPED_ROW_H if any(shows_scoped_row(d) for d, *_ in prods) else 0
    return PANEL_H + extra + (FEEDBACK_H if prods else 0)


def products(m):
    out = []
    if common.product_enabled("claude"):
        out.append((m.claude, "Claude Code", "claude_128.png", CLAUDE_URL, "claude"))
    if common.product_enabled("codex"):
        out.append((m.codex, "Codex", "codex_128.png", CODEX_URL, "codex"))
    return out


def feedback_countdown(until, now):
    seconds = max(0, until - now)
    if seconds >= 86400 * 100000:
        return tr("долго", "a long time")
    for unit, ru, en in ((86400, " д", " d"), (3600, " ч", " h"), (60, " мин", " min")):
        if seconds >= unit:
            return str(math.ceil(seconds / unit)) + tr(ru, en)
    return str(math.ceil(seconds)) + tr(" с", " s")


def feedback_action(m, d, product, now=None):
    now = time.time() if now is None else now
    if product in m.pending_products or d.refresh_in_flight:
        return None, ""
    if d.auth != limits.OK:
        return "feedbackfix:" + product, tr("Восстановить доступ", "Restore access")
    if ((quota_refresh.finite(d.server_retry_at) and now < d.server_retry_at)
            or now < d.local_retry_at):
        return None, ""
    if limit_poll_failed(d):
        return "feedbackretry:" + product, tr("Повторить", "Retry")
    return None, ""


def feedback_moment(value):
    try:
        return fmt.fmt_moment(value)
    except (OverflowError, OSError, ValueError):
        return tr("позже", "later")  # Huge valid delta-seconds need not fit localtime().


def feedback_copy(m, d, product):
    """Compact request state; observation time and automatic deadline stay distinct."""
    now = time.time()
    known = quota_refresh.finite(d.as_of) and 0 <= d.as_of <= now
    data = tr("Данные ", "Data ") + (fmt.hhmm(d.as_of) if known else "—")
    detail = [data]
    if known:
        detail.append(tr("Снимок: ", "Snapshot: ") + fmt.fmt_moment(d.as_of))
    if d.auth != limits.OK:
        detail.append(limit_auth_badge(d.auth))
    if limit_poll_failed(d):
        detail.append(limit_retry_notice(d))
        if d.error:
            detail.append(str(d.error))
    if quota_refresh.finite(d.next_poll_at):
        detail.append(tr("Автопроверка: ", "Automatic check: ") + feedback_moment(d.next_poll_at))
    server_wait = quota_refresh.finite(d.server_retry_at) and d.server_retry_at > now
    local_wait = d.local_retry_at > now
    if server_wait:
        detail.append(tr("Сервис разрешит повтор через ", "Service allows retry in ")
                      + feedback_countdown(d.server_retry_at, now))
    elif d.http_status == 429 and d.server_retry_at is None:
        detail.append(tr("Сервис не сообщил срок повтора.", "The service did not specify a retry time."))
    if local_wait:
        detail.append(tr("Защита от частых запросов: повтор через ", "Local request guard: retry in ")
                      + feedback_countdown(d.local_retry_at, now))
    if product in m.pending_products or d.refresh_in_flight:
        first, second, color = tr("Обновляем…", "Refreshing…"), "", TEXT_MID
    elif d.auth != limits.OK:
        first, second, color = limit_auth_badge(d.auth), "", AMBER
    elif server_wait:
        first = tr("Пауза сервиса · ", "Service wait · ") + feedback_countdown(d.server_retry_at, now)
        second, color = "", AMBER
    elif d.api_fresh and not limit_poll_failed(d):
        first = (tr("Повтор через ", "Retry in ") + feedback_countdown(d.local_retry_at, now)) if local_wait else ""
        second, color = "", TEXT_MID
    elif local_wait:
        first = (tr("Сбой · повтор ", "Failed · retry ") if limit_poll_failed(d) else
                 tr("Повтор через ", "Retry in ")) + feedback_countdown(d.local_retry_at, now)
        second, color = "", AMBER if limit_poll_failed(d) else TEXT_MID
    elif limit_poll_failed(d):
        first, second, color = tr("Сбой обновления", "Update failed"), "", AMBER
    else:
        first, second, color = "", "", TEXT_MID
    if d.api_fresh and not limit_poll_failed(d):
        detail.insert(0, tr("Проверено ", "Checked ") + (fmt.hhmm(d.as_of) if known else "—"))
        detail.append(tr("Получен свежий ответ; значения могли не измениться.",
                         "Live response received; values may be unchanged."))
    action, title = feedback_action(m, d, product, now)
    if action:
        # The action occupies row two; timestamps remain in the tooltip.
        if action.startswith("feedbackretry:"):
            first = tr("Сбой", "Failed")
        second = title
    if first:
        detail.insert(0, first)
    if limits.is_stale(d):
        detail.append(tr("Данные устарели · темп не считаем", "Stale data · pace paused"))
    return first, second, color, "\n".join(detail)


def draw_feedback(c, m, d, product, x, top, w, hits):
    first, second, color, _ = feedback_copy(m, d, product)
    area = rect_tl(x, top, w, FEEDBACK_H)
    # Tooltip region precedes the whole-card link; actions get their own native hit.
    hits.append(("feedback:" + product, area))
    def fit(text, weight, ink, width):
        label = Attr(text, 10, weight, ink)
        if label.width() <= width:
            return label
        while text and Attr(text + "…", 10, weight, ink).width() > width:
            text = text[:-1]
        return Attr(text + "…", 10, weight, ink)
    if first:
        c.text_c(fit(first, "regular", color, w), x, top + 2, 12)
    action, title = feedback_action(m, d, product)
    if action:
        label = fit(title, "medium", LINK, w - 8)
        c.text_c(label, x + 4, top + 16, 14)
        hits.insert(0, (action, rect_tl(x, top + 8, min(w, label.width() + 8), 24)))
    elif second:
        c.text_c(fit(second, "regular", TEXT_MID, w), x, top + 16, 14)


def credit_line(c, W, top, hits):
    pre = Attr(CREDIT, 9.5, "regular", gray(1, 0.32))
    link = Attr("GitHub", 9.5, "semibold", with_alpha(LINK, 0.95))
    pw, lw = pre.width(), link.width()
    x = (W - pw - lw) / 2
    c.text_c(pre, x, top, 12)
    c.text_c(link, x + pw, top, 12)
    hits.append(("open:" + REPO_URL, rect_tl(x + pw - 3, top - 2, lw + 6, 16)))


# ---- simple view ---------------------------------------------------------------------------

def draw_simple(c, W, H, m):
    hits = []
    background(c, W, H, (54, 26))
    pad = 16
    prods = products(m)
    subtitle = " · ".join(x[1] for x in prods) if prods else tr("выберите подписки в настройках", "choose subscriptions in Settings")
    c.image("appicon.png", rect_tl(pad, pad - 1, 30, 30))
    c.text(Attr(tr("Лимиты", "Limits"), 15, "semibold", TEXT_HI), pad + 40, pad - 1)
    c.text(Attr(subtitle, 11, "regular", TEXT_LO), pad + 40, pad + 17)
    rf = rect_tl(W - pad - 24, pad - 2, 24, 24)
    refresh_color = TEXT_MID if prods else TEXT_LO
    c.icon("refresh", rf.adjusted(4, 4, -4, -4), refresh_color, 1.7)
    hits.append(("refresh", rf))
    gear = rect_tl(W - pad - 24 - 26, pad - 2, 24, 24)
    c.icon("gear", gear.adjusted(4, 4, -4, -4), TEXT_MID, 1.5)
    hits.append(("settings", gear))
    if m.update_available:
        update_badge(c, gear.adjusted(4, 4, -4, -4))

    cards_top = 58
    card_h = 152 + (simple_height(m) - PANEL_H)
    gap = 12
    card_w = (W - pad * 2 - gap) / 2

    def draw_card(x, w, d, name, icon, url, product):
        r = rect_tl(x, cards_top, w, card_h)
        c.round_fill(r, 14, gray(1, 0.04))
        c.round_stroke(r, 14, gray(1, 0.06), 1)
        draw_feedback(c, m, d, product, x + 14, cards_top + card_h - FEEDBACK_H, w - 28, hits)
        can_fix = limit_can_fix(product, d.auth)
        hits.append(("settings" if not d.present else "claudefix" if can_fix else "open:" + url, r))
        c.image(icon, rect_tl(x + 14, cards_top + 13, 18, 18))
        c.text(Attr(name, 12.5, "semibold", gray(1, 0.9)), x + 39, cards_top + 15)

        def problem(title, sub):
            cx = x + w / 2
            c.icon("warning", rect_tl(cx - 11, cards_top + 46, 22, 22), AMBER)
            c.text(Attr(title, 12.5, "semibold", gray(1, 0.92)), cx, cards_top + 78, align=1)
            if sub:
                c.text(Attr(sub, 9.5, "regular", TEXT_LO), cx, cards_top + 97, align=1)

        if not d.present:
            c.text_c(Attr(tr("Загрузка…", "Loading…") if not m.loaded else tr("Не настроен", "Not set up"),
                          12, "regular", TEXT_MID), x + w / 2, cards_top + 65, 20, align=1)
            return

        if d.auth == limits.LOGGED_OUT:
            problem(tr("Вход не выполнен", "Not signed in"),
                    tr("нужен вход Claude Code CLI", "sign in via Claude Code CLI") if can_fix else None)
            return
        if d.auth == limits.READ_ERROR:
            sub = (tr("проверьте ~/.claude/.credentials.json", "check ~/.claude/.credentials.json")
                   if product == "claude" else tr("проверьте доступ к данным", "check data access"))
            problem(tr("Сбой доступа к входу", "Sign-in access issue"), sub)
            return
        if d.auth == limits.EXPIRED and d.session is None and d.weekly is None:
            problem(tr("Вход устарел", "Sign-in expired"),
                    (tr("данные от ", "as of ") + fmt.fmt_reset(d.as_of)) if d.as_of is not None else None)
            return
        if d.auth == limits.OK:
            c.icon("arrow_ne", rect_tl(x + w - 21, cards_top + 11, 11, 11), gray(1, 0.22), 1.5)
        cx, cy = x + w / 2, cards_top + 84
        stale = limits.is_stale(d)
        s_col = gray(1, 0.3) if limits.metric_is_stale(d, "session") else metric_color(BLUE, d.session)
        w_col = gray(1, 0.3) if limits.metric_is_stale(d, "weekly") else metric_color(PURPLE, d.weekly)
        # Codex no longer has a 5-hour window: when the backend reports none, one ring for the
        # week instead of an empty inner ring and a "Session —" row.
        single = d.session is None and d.session_reset is None and d is m.codex
        w_txt = "—" if d.weekly is None else fmt.num_text(d.weekly) + "%"
        if single:
            c.gauge(cx, cy, 34, 7, d.weekly, w_col)
            c.text(Attr(w_txt, 19, "semibold", w_col), cx, cy - 10, align=1)
        else:
            c.gauge(cx, cy, 38, 6, d.weekly, w_col)
            c.gauge(cx, cy, 26, 6, d.session, s_col)
            c.text(Attr("—" if d.session is None else fmt.num_text(d.session) + "%", 15, "semibold", s_col), cx, cy - 18, align=1)
            c.text(Attr(w_txt, 15, "semibold", w_col), cx, cy + 1, align=1)

        def pill(symbol, label, color, tinted=False):
            a = Attr(label, 10, "semibold", color)
            ico = 0 if symbol is None else 9
            mid = 0 if symbol is None else 2.5
            pl, pr_ = (8, 8) if symbol is None else (6, 7)
            ph = 16
            pw = pl + ico + mid + a.width() + pr_
            top = cy + 22
            r = rect_tl(cx - pw / 2, top, pw, ph)
            c.round_fill(r, ph / 2, with_alpha(color, 0.16) if tinted else gray(1, 0.09))
            if tinted:
                c.round_stroke(r, ph / 2, with_alpha(color, 0.42), 1)
            if symbol:
                c.icon(symbol, QRectF(r.left() + pl, r.center().y() - ico / 2, ico, ico), color, 1.3)
            c.text_c(a, r.left() + pl + ico + mid, top, ph)

        sc_col = gray(1, 0.3) if limits.metric_is_stale(d, "model") else scoped_color(d.scoped.percent)
        if not stale and d.reset_credits is not None and d.reset_credits >= 1:
            pill("refresh", str(d.reset_credits), AMBER)
        elif not stale and d.scoped:
            pill(None, fmt.num_text(d.scoped.percent) + "%", sc_col, tinted=True)
        l1, l2 = cards_top + 124, cards_top + 139
        if not can_fix:
            lx = x + 16
            if single:
                l2 = l1
            else:
                c.dot(lx + 3, l1 + 5, s_col)
                c.text(Attr(tr("Сессия", "Session"), 10.5, "regular", TEXT_MID), lx + 11, l1)
                c.text(Attr(limit_reset_text(d.session_reset), 10, "regular", TEXT_LO), x + w - 14, l1, align=2)
            c.dot(lx + 3, l2 + 5, w_col)
            c.text(Attr(tr("Неделя", "Week"), 10.5, "regular", TEXT_MID), lx + 11, l2)
            c.text(Attr(limit_reset_text(d.weekly_reset), 10, "regular", TEXT_LO), x + w - 14, l2, align=2)
            if shows_scoped_row(d):
                l3 = l2 + SCOPED_ROW_H
                c.dot(lx + 3, l3 + 5, sc_col)
                c.text(Attr(d.scoped.name, 10.5, "regular", TEXT_MID), lx + 11, l3)
                c.text(Attr(limit_reset_text(d.scoped.reset), 10, "regular", TEXT_LO), x + w - 14, l3, align=2)

    if len(prods) >= 2:
        draw_card(pad, card_w, *prods[0])
        draw_card(pad + card_w + gap, card_w, *prods[1])
    elif len(prods) == 1:
        draw_card(pad, W - pad * 2, *prods[0])
    else:
        paused = not any(common.product_enabled(p) for p in ("claude", "codex"))
        message = tr("Сбор статистики выключен", "Statistics collection is off") if paused else tr("Выбранные подписки не найдены", "Selected subscriptions not found")
        c.text(Attr(message, 12, "regular", TEXT_MID),
               W / 2, cards_top + 70, align=1)

    foot = cards_top + card_h + 14
    footer_simple(c, W, foot, m, hits)
    div = foot + 24 + 8
    c.hline(pad, W - pad, div, gray(1, 0.06))
    credit_line(c, W, div + 7, hits)
    return hits


def footer_simple(c, W, foot, m, hits, advanced=False):
    pad = 16
    auto = common.settings().get("autoPoll")
    segs = poll_segments()[:-1]
    selected = highlighted_intervals(m)
    sw, sh = 40, 24
    c.round_fill(rect_tl(pad, foot, sw * len(segs), sh), 8, gray(1, 0.06))
    for i, (label, sec) in enumerate(segs):
        r = rect_tl(pad + i * sw, foot, sw, sh)
        on = sec in selected
        if on:
            c.round_fill(r.adjusted(2, 2, -2, -2), 6, gray(1, 0.18 if advanced else 0.13))
        c.text_c(Attr(label, 12 if advanced else 11, "semibold" if on else "medium" if advanced else "regular",
                      TEXT_HI if on else TEXT_MID), r.center().x(), foot, sh, align=1)
        hits.append(("iv%d" % sec, r))
    auto_hit = rect_tl(176, foot, 40, 24)
    capsule = rect_tl(181, foot + 2, 30, 20)
    if auto:
        gradient = QLinearGradient(capsule.topLeft(), capsule.bottomRight())
        gradient.setColorAt(0, rgb(52 / 255, 121 / 255, 239 / 255))
        gradient.setColorAt(1, rgb(121 / 255, 104 / 255, 232 / 255))
        c.p.setPen(Qt.NoPen)
        c.p.setBrush(QBrush(gradient))
        c.p.drawRoundedRect(capsule, 10, 10)
    else:
        c.round_fill(capsule, 10, rgb(38 / 255, 50 / 255, 74 / 255))
    outline = rgb(184 / 255, 207 / 255, 1, 0.35) if auto else rgb(130 / 255, 154 / 255, 213 / 255)
    c.round_stroke(capsule.adjusted(0.5, 0.5, -0.5, -0.5), 9.5, outline)
    label_color = rgb(217 / 255, 229 / 255, 1)
    c.text_c(Attr(tr("А", "A"), 12, "semibold", gray(1, 1) if auto else label_color),
             auto_hit.center().x(), foot, sh, align=1)
    hits.append(("iv0", auto_hit))
    pwr = rect_tl(W - pad - 24, foot, 24, 24)
    c.icon("power", pwr.adjusted(5, 5, -5, -5), gray(1, 0.5 if advanced else 0.6), 1.6 if advanced else 1.7)
    hits.append(("quit", pwr))


# ---- advanced view («Темп») ------------------------------------------------------------------

ADV_CX, ADV_CW = 15, 330
ADV_IX, ADV_IW = 26, 308
ROW_FULL, ROW_SHORT, ROW_CREDITS = 62, 50, 24
NOTICE, PLACEHOLDER = 19, 40
HIST_EXPANDED, HIST_COLLAPSED, HIST_EMPTY_EXTRA = 187, 35, 44
CREDIT_H = 24
ADV_SESSION, ADV_WEEK, ADV_ACCENT = BLUE, PURPLE, AMBER


def adv_window_color(kind, used):
    u = used or 0
    if kind == 2:
        return MODEL[2] if u >= 80 else MODEL[1] if u >= 50 else MODEL[0]
    if u >= 80:
        return CRIT
    if u >= 50:
        return WARN
    return ADV_SESSION if kind == 0 else ADV_WEEK


def adv_model_family(mid, product):
    if product == "claude":
        if mid.startswith("claude-fable"):
            return "Fable", MODEL[0]
        if mid.startswith("claude-opus"):
            return "Opus", ADV_WEEK
        if mid == "other":
            return tr("прочие", "other"), ADV_SESSION
        return usage.model_display_name(mid).split(" ")[0], ADV_SESSION
    if mid.startswith("gpt-6-astra"):
        return "Astra", MODEL[1]
    if mid.startswith("gpt-5.6"):
        return "Sol 5.6", LINK
    if mid.startswith("gpt-6-sol"):
        return "Sol 6", MODEL[2]
    return tr("прочие", "other"), gray(1, 0.28)


def limit_can_fix(product, auth):
    return product == "claude" and auth in (limits.LOGGED_OUT, limits.EXPIRED)


def limit_auth_badge(auth):
    if auth == limits.LOGGED_OUT:
        return tr("нет входа", "signed out")
    if auth == limits.EXPIRED:
        return tr("вход истёк", "sign-in expired")
    if auth == limits.READ_ERROR:
        return tr("сбой доступа", "access issue")
    return tr("данные устарели", "stale data")


def limit_paused_notice(as_of):
    if as_of is None or not math.isfinite(as_of) or as_of > time.time():
        return tr("Нет свежих данных · темп не считаем", "No fresh data · pace paused")
    return tr("Данные от ", "Data as of ") + fmt.moment_lower(as_of) + tr(" · темп не считаем", " · pace paused")


def limit_reset_text(reset):
    if reset is not None and reset <= time.time():
        return tr("окно сброшено", "window reset")
    return fmt.fmt_reset(reset)


def limit_poll_failed(d):
    return d.poll_failed or d.error is not None


def limit_retry_notice(d, compact=False):
    prefix = tr("Сбой · ", "Failed · ") if compact else ""
    if d.next_poll_at is None:
        return prefix + tr("повтор по расписанию", "scheduled retry")
    if d.next_poll_at <= time.time():
        return prefix + tr("повтор ожидается", "retry due")
    try:
        moment = time.strftime("%H:%M", time.localtime(d.next_poll_at))
    except (OverflowError, OSError, ValueError):
        return prefix + tr("повтор позже", "retry later")
    return prefix + tr("повтор в ", "retry at ") + moment


def limit_data_badge(d):
    if d.auth == limits.OK and limit_poll_failed(d):
        return tr("сбой обновления", "update failed")
    return limit_auth_badge(d.auth)


def adv_cards(m):
    out = []
    for d, product in ((m.claude, "claude"), (m.codex, "codex")):
        if not common.product_enabled(product):
            continue
        paused = d.auth != limits.OK or limits.is_stale(d)
        lims = limits.paced_limits(d, product, m.history) if d.present else []
        if product == "codex":
            lims.sort(key=lambda l: 0 if l["id"] == "weekly" else 1)
        rows = []
        for l in lims:
            p = l["pace"]
            if p is None:
                kind = "inactive"
            elif d.auth != limits.OK or d.as_of > time.time() or p.reset <= time.time():
                kind = "stale"
            elif p.used >= 100:
                kind = "exhausted"
            elif p.elapsed_h < 10.0 / 60 or p.used < 2:
                kind = "tooEarly"
            else:
                kind = "full"
            rows.append({"limit": l, "kind": kind})
        if product == "codex" and d.present:
            rows.append({"limit": None, "kind": "credits", "credits": d.reset_credits or 0})
        out.append({"product": product, "data": d, "paused": paused, "rows": rows,
                    "name": "Claude Code" if product == "claude" else "Codex",
                    "icon": "claude_128.png" if product == "claude" else "codex_128.png",
                    "url": CLAUDE_URL if product == "claude" else CODEX_URL})
    return out


def row_h(row):
    k = row["kind"]
    return ROW_FULL if k in ("full", "tooEarly", "exhausted") else ROW_SHORT if k in ("inactive", "stale") else ROW_CREDITS


def notice_h(card):
    # Keep an actual sign-in instruction; snapshot/retry details live in the card footer.
    return NOTICE if card["data"].present and card["data"].auth != limits.OK else 0


def card_h(card):
    if not card["data"].present:
        return PLACEHOLDER + FEEDBACK_H
    rows = card["rows"]
    body = sum(row_h(r) for r in rows) + max(0, len(rows) - 1) if rows else PLACEHOLDER
    return 38 + body + notice_h(card) + FEEDBACK_H


def hist_product(m, present):
    p = common.settings().get("advHistProduct")
    return p if p in present else (present[0] if present else "claude")


def hist_empty(m, product):
    return not m.days.get(product)


def hist_height(m, cards):
    warn = NOTICE if m.sync_warning else 0          # orange sync line under the header
    if not common.settings().get("advHistExpanded"):
        return HIST_COLLAPSED + warn
    p = hist_product(m, [c["product"] for c in cards if c["data"].present])
    return HIST_EXPANDED + (HIST_EMPTY_EXTRA if hist_empty(m, p) else 0) + warn


def advanced_height(m):
    cards = adv_cards(m)
    if not any(cd["data"].present for cd in cards):
        return simple_height(m)
    h = 94
    for cd in cards:
        h += 5 + card_h(cd)
    h += 5 + hist_height(m, cards)
    return h + CREDIT_H


def adv_verdict(row, as_of):
    if row["kind"] == "stale":
        pace = row["limit"]["pace"] if row["limit"] else None
        prefix = tr("Окно сброшено · снимок ", "Window reset · snapshot ") if pace and pace.reset <= time.time() else tr("по данным на ", "as of ")
        return prefix + fmt.moment_lower(as_of) if as_of is not None else limit_paused_notice(None)
    lim = row["limit"]
    p = lim["pace"] if lim else None
    if p is None:
        if lim and lim.get("used") is not None:
            return tr("Нет времени окна · темп не считаем", "Window timing unknown · pace paused")
        return tr("Окно не активно · откроется с первым запросом", "Window inactive · opens with the first request")
    if as_of is not None and time.time() - as_of > limits.SNAPSHOT_MAX_AGE:
        return (tr("Прогноз на снимке: ", "Snapshot forecast: ") + fmt.fmt_pct(p.projected, 0)
                if p.projected is not None else tr("На снимке мало данных для темпа", "Not enough pace data in snapshot"))
    k = row["kind"]
    if k == "exhausted":
        return tr("Лимит исчерпан · сброс в ", "Limit reached · resets at ") + fmt.moment_lower(p.reset)
    if k == "tooEarly":
        return tr("Мало данных для темпа · сброс в ", "Not enough data for pace · resets at ") + fmt.moment_lower(p.reset)
    if p.runs_out_at is not None:
        before = (p.reset - p.runs_out_at) / 3600
        return (tr("Кончится в ", "Runs out at ") + fmt.moment_lower(p.runs_out_at) + tr(", за ", ", ")
                + fmt.fmt_span(before) + tr(" до сброса", " before reset"))
    if p.projected is not None:
        if fmt.rnd(p.projected) >= 85:
            return tr("Хватит впритык (прогноз ", "Barely lasts (forecast ") + fmt.fmt_pct(p.projected, 0) + ")"
        return tr("Хватит до сброса (прогноз ", "Lasts until reset (forecast ") + fmt.fmt_pct(p.projected, 0) + ")"
    return tr("Хватит до сброса", "Lasts until reset")


def draw_advanced(c, W, H, m):
    if not any(cd["data"].present for cd in adv_cards(m)):
        return draw_simple(c, W, H, m)
    hits = []
    p = c.p
    background(c, W, H, (30, 20))

    def pill(label, x, top, h, padx, fill, stroke=None, right=False):
        w = c.width(label) + padx * 2
        r = rect_tl(x - w if right else x, top, w, h)
        c.round_fill(r, h / 2, fill)
        if stroke is not None:
            c.round_stroke(r.adjusted(0.5, 0.5, -0.5, -0.5), h / 2, stroke, 1)
        c.text_c(label, r.center().x(), top, h, align=1)
        return r

    # header
    c.image("appicon.png", rect_tl(15, 13, 40, 40))
    title = Attr(tr("Лимиты", "Limits"), 16, "semibold", TEXT_HI)
    c.text_c(title, 65, 15.5, 20)
    pill(caps("Advanced", 9, gray(1, 0.55)), 65 + title.width() + 7, 18, 15, 7, gray(1, 0.09))
    x, ly, lh = 65.0, 37.5, 13
    c.round_fill(rect_tl(x + 2, ly + 1.5, 2, 10), 1, gray(1, 0.55))
    x += 10
    a = Attr(tr("план сейчас", "plan now"), 10.5, "regular", TEXT_MID)
    c.text_c(a, x, ly, lh)
    x += a.width() + 4
    dot = Attr("·", 10.5, "regular", TEXT_MID)
    c.text_c(dot, x + 2, ly, lh)
    x += dot.width() + 8
    c.round_fill(rect_tl(x, ly + 4, 16, 5), 2.5, gray(1, 0.30))
    x += 20
    c.text_c(Attr(tr("прогноз к сбросу", "forecast to reset"), 10.5, "regular", TEXT_MID), x, ly, lh)
    gear, rf = rect_tl(297, 24, 18, 18), rect_tl(328, 25, 16, 16)
    c.icon("gear", gear, TEXT_MID, 1.4)
    if m.update_available:
        update_badge(c, gear)
    c.icon("refresh", rf, TEXT_MID, 1.7)
    hits.append(("settings", rect_tl(294, 21, 24, 24)))
    hits.append(("refresh", rect_tl(324, 21, 24, 24)))

    cards = adv_cards(m)
    y = 58.0

    def draw_row(row, yr, dimmed, as_of):
        if row["kind"] == "credits":
            n = row.get("credits") or 0
            on = n > 0
            c.dot(ADV_IX + 3, yr + 14.5, ADV_ACCENT if on else gray(1, 0.22))
            c.text_c(caps(tr("Сбросы в запасе", "Resets in reserve"), 9.5, TEXT_MID if on else TEXT_LO), ADV_IX + 12, yr + 6, 17)
            num = Attr(str(n), 11, "semibold", ADV_ACCENT if on else TEXT_LO)
            pw = 6 + 11 + 4 + num.width() + 7
            pr = rect_tl(ADV_IX + ADV_IW - pw, yr + 6, pw, 17)
            c.round_fill(pr, 8.5, with_alpha(ADV_ACCENT, 0.16) if on else gray(1, 0.09))
            if on:
                c.round_stroke(pr.adjusted(0.5, 0.5, -0.5, -0.5), 8.5, with_alpha(ADV_ACCENT, 0.42), 1)
            c.icon("refresh", QRectF(pr.left() + 6, pr.center().y() - 5.5, 11, 11), ADV_ACCENT if on else TEXT_LO, 1.4)
            c.text_c(num, pr.left() + 21, yr + 6, 17)
            return
        lim = row["limit"]
        pace = lim["pace"]
        k = row["kind"]
        live = k in ("full", "exhausted", "tooEarly", "stale")
        col = adv_window_color(lim["color"], pace.used if pace else None) if live else gray(1, 0.22)
        if dimmed:
            p.save()
            p.setOpacity(0.42)
        c.dot(ADV_IX + 3, yr + 11, col if live else gray(1, 0.22))
        c.text_c(caps(lim["name"], 9.5, TEXT_LO if k == "inactive" else TEXT_MID), ADV_IX + 12, yr + 4, 14)
        used = pace.used if pace else lim.get("used")
        if used is not None and math.isfinite(used):
            c.text_c(Attr(fmt.fmt_pct(used, 0), 14, "semibold", col, kern=-0.14), ADV_IX + ADV_IW, yr + 4, 14, align=2)
        else:
            c.text_c(Attr("—", 14, "semibold", TEXT_LO), ADV_IX + ADV_IW, yr + 4, 14, align=2)
        if k == "full":
            if pace and pace.runs_out_at is not None:
                vcol, vw = CRIT, "semibold"
            elif pace and pace.projected is not None and fmt.rnd(pace.projected) >= 85:
                vcol, vw = WARN, "semibold"
            else:
                vcol, vw = TEXT_HI, "semibold"
        elif k == "exhausted":
            vcol, vw = CRIT, "semibold"
        else:
            vcol, vw = TEXT_MID, "regular"
        verdict = adv_verdict(row, as_of)
        va = Attr(verdict, 12.5, vw, vcol)
        if va.width() > ADV_IW:
            s = verdict.replace(tr(" до сброса", " before reset"), "")
            va = Attr(s, 12.5, vw, vcol)
            while va.width() > ADV_IW and len(s) > 8:
                s = s[:-2] + "…"
                va = Attr(s, 12.5, vw, vcol)
        c.text_c(va, ADV_IX, yr + 19, 16)
        bar_top = yr + 38
        c.round_fill(rect_tl(ADV_IX, bar_top, ADV_IW, 5), 2.5, gray(1, 0.08))
        if pace and live:
            used_w = min(100.0, max(0.0, pace.used)) / 100 * ADV_IW
            if k in ("full", "exhausted"):
                if pace.runs_out_at is not None and k == "full":
                    c.round_fill(rect_tl(ADV_IX, bar_top, ADV_IW, 5), 2.5, with_alpha(CRIT, 0.22))
                elif k == "full" and pace.projected is not None and pace.projected > pace.used:
                    gw = min(100.0, pace.projected) / 100 * ADV_IW
                    c.round_fill(rect_tl(ADV_IX, bar_top, gw, 5), 2.5, with_alpha(col, 0.30))
            if used_w >= 1:
                c.round_fill(rect_tl(ADV_IX, bar_top, max(5, used_w), 5), 2.5, col)
            if k != "stale":
                tx = ADV_IX + pace.plan_pct / 100 * ADV_IW - 1
                c.round_fill(rect_tl(tx, bar_top - 3, 2, 11), 1, gray(1, 0.55))
        if k in ("full", "exhausted", "tooEarly") and pace:
            rate = "—" if k == "tooEarly" else fmt.fmt_rate(pace)
            runs = [Attr(tr("план ", "plan ") + fmt.fmt_pct(pace.plan_pct) + " · ", 10.5, "regular", TEXT_MID),
                    Attr(fmt.fmt_signed_pts(pace.delta_pts), 10.5, "regular", WARN if pace.delta_pts >= 0 else TEXT_MID),
                    Attr(" · " + rate + " · " + tr("сброс ", "reset ") + fmt.reset_short(pace.reset), 10.5, "regular", TEXT_MID)]
            c.text_c(runs, ADV_IX, yr + 46, 12)
        if dimmed:
            p.restore()

    for cd in cards:
        ch = card_h(cd)
        d = cd["data"]
        rect = rect_tl(ADV_CX, y, ADV_CW, ch)
        c.round_fill(rect, 14, gray(1, 0.04))
        draw_feedback(c, m, d, cd["product"], ADV_IX, y + ch - FEEDBACK_H, ADV_IW, hits)
        if not d.present:
            p.save()
            pen = QPen(gray(1, 0.14), 1)
            pen.setDashPattern([4, 3])
            p.setPen(pen)
            p.setBrush(Qt.NoBrush)
            p.drawRoundedRect(rect.adjusted(0.5, 0.5, -0.5, -0.5), 14, 14)
            p.restore()
            label = cd["name"] + (tr(" · загрузка…", " · loading…") if not m.loaded else
                                   tr(" не настроен", " not set up"))
            c.text_c(Attr(label, 13, "medium", TEXT_MID), ADV_IX + 4, y, PLACEHOLDER)
            hits.append(("settings", rect_tl(ADV_CX, y, ADV_CW, PLACEHOLDER)))
            y += ch + 5
            continue
        c.round_stroke(rect.adjusted(0.5, 0.5, -0.5, -0.5), 14, gray(1, 0.06), 1)
        can_fix = limit_can_fix(cd["product"], d.auth)
        y0 = y + 9
        c.image(cd["icon"], rect_tl(ADV_IX, y0 + 1, 16, 16))
        name = Attr(cd["name"], 13, "semibold", TEXT_HI)
        c.text_c(name, ADV_IX + 23, y0, 18)
        px = ADV_IX + 23 + name.width() + 7
        if cd["paused"] or limit_poll_failed(d):
            label = limit_data_badge(d)
            r = pill(Attr(label, 9.5, "semibold", WARN, kern=0.19), px, y0 + 1, 16, 7,
                     with_alpha(WARN, 0.16), with_alpha(WARN, 0.42))
            px = r.right() + 5
        if d.plan:
            if cd["product"] == "claude":
                tier = common.state().get("claudeTier") or ""
                label = ("Max 20x" if "20x" in tier else "Max 5x" if "5x" in tier else "Max") if d.plan == "max" else d.plan.capitalize()
            else:
                label = d.plan
            pill(Attr(label, 9.5, "semibold", gray(1, 0.60), kern=0.19), px, y0 + 1, 16, 7, gray(1, 0.09))
        arrow = rect_tl(322, y0 + 3, 12, 12)
        c.icon("arrow_ne", arrow, gray(1, 0.34), 1.5)
        hits.append(("claudefix" if can_fix else "open:" + cd["url"], rect if can_fix else arrow.adjusted(-8, -8, 8, 8)))
        ry = y + 29
        if notice_h(cd):
            instruction = ("claude → /login" if can_fix else
                           tr("Проверьте доступ к входу", "Check sign-in access"))
            c.text_c(Attr(instruction, 10, "regular", TEXT_MID), ADV_IX, ry, 14)
            ry += notice_h(cd)
        if not cd["rows"]:
            label = tr("Нет данных об окнах", "No window data")
            c.text_c(Attr(label, 12, "regular", TEXT_MID), ADV_IX, ry, PLACEHOLDER)
        for i, row in enumerate(cd["rows"]):
            draw_row(row, ry, (cd["paused"] or row["kind"] == "stale") and row["kind"] != "credits", d.as_of)
            ry += row_h(row)
            if i < len(cd["rows"]) - 1:
                c.hline(ADV_IX, ADV_IX + ADV_IW, ry, gray(1, 0.06))
                ry += 1
        y += ch + 5

    # history & money
    present = [cd["product"] for cd in cards if cd["data"].present]
    hp = hist_product(m, present)
    expanded = bool(common.settings().get("advHistExpanded"))
    hh = hist_height(m, cards)
    hc = rect_tl(ADV_CX, y, ADV_CW, hh)
    c.round_fill(hc, 14, gray(1, 0.04))
    c.round_stroke(hc.adjusted(0.5, 0.5, -0.5, -0.5), 14, gray(1, 0.06), 1)
    hy = y + 8
    c.icon("chevron_down" if expanded else "chevron_right", rect_tl(ADV_IX, hy + 4.5, 8, 9), TEXT_LO, 1.5)
    cap = tr("История и деньги", "History & money")
    if m.other_machines > 0:
        cap += tr(" · %d ПК" % (m.other_machines + 1), " · %d PCs" % (m.other_machines + 1))
    c.text_c(caps(cap, 9.5, TEXT_LO), ADV_IX + 14, hy, 18)
    # stops above the orange sync line when there is one (hit-test takes the first match)
    hits.append(("hist:toggle", rect_tl(ADV_CX, y, 200, hy + 18 - y if m.sync_warning else 35)))
    if present:
        items = [(x, "Claude" if x == "claude" else "Codex") for x in present]
        widths = [Attr(t, 10.5, "semibold", TEXT_HI).width() + 16 for _, t in items]
        total = sum(widths) + (len(items) - 1) + 4
        tx = ADV_IX + ADV_IW - total
        c.round_fill(rect_tl(tx, hy, total, 18), 9, gray(1, 0.07))
        sx = tx + 2
        for i, (pid, t) in enumerate(items):
            r = rect_tl(sx, hy + 2, widths[i], 14)
            on = pid == hp
            if on:
                c.round_fill(r, 7, gray(1, 0.18))
            c.text_c(Attr(t, 10.5, "semibold" if on else "medium", TEXT_HI if on else TEXT_MID), r.center().x(), hy + 2, 14, align=1)
            hits.append(("hist:" + pid, r.adjusted(-2, -4, 2, 4)))
            sx += widths[i] + 1
    # Sync stalled / revoked: one orange line under the header, collapsed or expanded — the
    # totals below silently miss the other computers otherwise. Click → Settings.
    warn_h = 0
    if m.sync_warning:
        s = m.sync_warning
        wa = Attr(s, 10.5, "regular", WARN)
        while wa.width() > ADV_IW and len(s) > 8:
            s = s[:-2] + "…"
            wa = Attr(s, 10.5, "regular", WARN)
        c.text_c(wa, ADV_IX, hy + 18 + 1, NOTICE - 2)
        hits.append(("settings", rect_tl(ADV_IX, hy + 18, ADV_IW, NOTICE)))
        warn_h = NOTICE
    if expanded:
        draw_history(c, m, cards, hp, hy + 22 + warn_h, hits)
    y += hh + 6

    # footer
    foot = H - 35 - CREDIT_H
    footer_simple(c, W, foot, m, hits, advanced=True)
    div = foot + 22 + 8
    c.hline(ADV_CX, ADV_CX + ADV_CW, div, gray(1, 0.06))
    credit_line(c, W, div + 7, hits)
    return hits


def draw_history(c, m, cards, hp, by, hits):
    p = c.p
    d = m.claude if hp == "claude" else m.codex
    rows42 = usage.daily_usage(m.days, hp, 42)
    last7 = rows42[-7:]
    today = common.today_key()
    spend = {}
    for dd in last7:
        for model, _tok, usd in dd["byModel"]:
            spend[model] = spend.get(model, 0) + usd
    top = [k for k, _ in sorted(spend.items(), key=lambda kv: -kv[1])][:3]

    cx0, cy0 = ADV_IX, by
    c.text_c(caps(tr("7 дней · $ по API", "7 days · $ at API"), 8.5, TEXT_LO), cx0, cy0, 12)
    lg = Attr(tr("окно недели", "week window"), 8.5, "regular", TEXT_MID)
    c.text_c(lg, cx0 + 190, cy0, 12, align=2)
    c.round_fill(rect_tl(cx0 + 190 - lg.width() - 4 - 10, cy0 + 5, 10, 2), 1, with_alpha(ADV_WEEK, 0.7))
    gx, gy = cx0, cy0 + 12
    c.hline(gx + 2, gx + 188, gy + 40, gray(1, 0.08))
    max_usd = max([dd["usd"] for dd in last7] + [0])
    week_start = d.weekly_reset - 168 * 3600 if d.weekly_reset else None
    underline_from = None
    families, order = {}, []
    for i, dd in enumerate(last7):
        bx = gx + 6 + 26 * i
        if dd["usd"] > 0 and max_usd > 0:
            h = max(2.0, 28 * dd["usd"] / max_usd)
            parts, other = [], 0.0
            for model, _tok, usd in dd["byModel"]:
                if model in top and usd / dd["usd"] >= 0.03:
                    parts.append((model, usd))
                else:
                    other += usd
            if other > 0:
                parts.append(("other", other))
            fam = []
            for model, usd in parts:
                name, color = adv_model_family(model, hp)
                for f in fam:
                    if f[0] == name:
                        f[2] += usd
                        break
                else:
                    fam.append([name, color, usd])
            fam.sort(key=lambda f: -f[2])
            topy = gy + 40
            p.save()
            clip = QPainterPath()
            clip.addRoundedRect(rect_tl(bx, gy + 40 - h, 18, h), 1.5, 1.5)
            p.setClipPath(clip)
            for name, color, usd in fam:
                sh = max(0.6, h * usd / dd["usd"])
                p.fillRect(rect_tl(bx, topy - sh, 18, sh), color)
                topy -= sh
                if name not in families:
                    families[name] = color
                    order.append(name)
            p.restore()
            c.text_base(Attr("$" + str(int(fmt.rnd(dd["usd"]))), 8.5, "semibold", gray(1, 0.7)), bx + 9, gy + 40 - h - 3, align=1)
        else:
            c.round_fill(rect_tl(bx, gy + 38.5, 18, 1.5), 0.75, gray(1, 0.12))
        day_t = time.mktime(time.strptime(dd["day"] + " 12", "%Y-%m-%d %H"))
        is_today = dd["day"] == today
        c.text_base(Attr(fmt.weekday(day_t), 9, "semibold" if is_today else "regular", ADV_ACCENT if is_today else TEXT_MID),
                    bx + 9, gy + 50, align=1)
        day_start = day_t - 12 * 3600
        if week_start is not None and underline_from is None and day_start + 86400 > week_start:
            underline_from = bx
    if underline_from is not None:
        c.round_fill(rect_tl(underline_from, gy + 53.5, gx + 6 + 26 * 6 + 18 - underline_from, 1.5), 0.75, with_alpha(ADV_WEEK, 0.55))
    names = ["Fable", "Opus", tr("прочие", "other")] if hp == "claude" else ["Astra", "Sol 5.6", "Sol 6", tr("прочие", "other")]
    probe = {"Fable": "claude-fable", "Opus": "claude-opus", "Astra": "gpt-6-astra", "Sol 5.6": "gpt-5.6-sol", "Sol 6": "gpt-6-sol"}
    lx = cx0
    for name in names:
        color = families.get(name) or adv_model_family(probe.get(name, "other"), hp)[1]
        seen = name in families
        c.round_fill(rect_tl(lx, cy0 + 73, 7, 7), 2, color if seen else with_alpha(color, 0.25))
        a = Attr(name, 8.5, "regular", TEXT_MID if seen else TEXT_LO)
        c.text_c(a, lx + 11, cy0 + 71, 11)
        lx += 11 + a.width() + 7

    # 35-day calendar
    kx, ky = ADV_IX + 204, cy0
    cal = rows42[-35:]
    total35 = usage.clamp_number(sum(dd["usd"] for dd in cal))
    c.text_c(caps(tr("35 дней · ", "35 days · ") + fmt.fmt_usd(total35), 8.5, TEXT_LO), kx, ky, 12)
    letters = ["п", "в", "с", "ч", "п", "с", "в"] if common.app_lang() == "ru" else ["M", "T", "W", "T", "F", "S", "S"]
    for i, l in enumerate(letters):
        c.text_base(Attr(l, 7, "regular", TEXT_LO), kx + 9.5 * i + 4, ky + 19, align=1)
    levels = [10, 30, 60] if hp == "claude" else [5, 30, 100]
    first_t = time.mktime(time.strptime(cal[0]["day"] + " 12", "%Y-%m-%d %H"))
    col, row = time.localtime(first_t).tm_wday, 0
    labelled = set()
    mon = (["янв", "фев", "мар", "апр", "мая", "июн", "июл", "авг", "сен", "окт", "ноя", "дек"] if common.app_lang() == "ru"
           else ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"])
    for i, dd in enumerate(cal):
        cell_x, cell_y = kx + 9.5 * col, ky + 22 + 9.5 * row
        u = dd["usd"]
        if u <= 0:
            color = gray(1, 0.06)
        else:
            a = 0.28 if u <= levels[0] else 0.50 if u <= levels[1] else 0.75 if u <= levels[2] else 1.0
            color = with_alpha(ADV_ACCENT, a)
        cell = rect_tl(cell_x, cell_y, 7.5, 7.5)
        c.round_fill(cell, 2, color)
        if dd["day"] == today:
            c.round_stroke(cell.adjusted(0.5, 0.5, -0.5, -0.5), 2, gray(1, 0.7), 1)
        mday = int(dd["day"][8:10])
        if (i == 0 or mday == 1) and row not in labelled:
            labelled.add(row)
            c.text_base(Attr(mon[int(dd["day"][5:7]) - 1], 7, "regular", TEXT_LO), kx + 71, cell_y + 7)
        col += 1
        if col == 7:
            col, row = 0, row + 1

    # money table
    my = by + 82
    if hist_empty(m, hp):
        box = rect_tl(ADV_IX, my + 2, ADV_IW, HIST_EMPTY_EXTRA - 6)
        c.round_fill(box, 8, gray(1, 0.04))
        msg = tr("Расхода по логам пока нет — ни на этой машине, ни в синхронизации. Столбики и календарь "
                 "заполнятся, как только CLI поработает. Темп выше работает и без истории.",
                 "No usage in the logs yet — neither here nor from synced machines. Bars and the calendar fill "
                 "in once the CLI has been used. Pace above works without history.")
        p.setFont(Attr(msg, 10.5).font)
        p.setPen(QPen(TEXT_MID))
        p.drawText(box.adjusted(8, 4, -8, -4), Qt.TextWordWrap | Qt.AlignVCenter, msg)
        my += HIST_EMPTY_EXTRA
    c.hline(ADV_IX, ADV_IX + ADV_IW, my + 4, gray(1, 0.06))
    colx = [ADV_IX, ADV_IX + 120, ADV_IX + 203, ADV_IX + ADV_IW]
    c.text_c(caps(tr("по подписке", "on subscription"), 8.5, TEXT_LO), colx[1], my + 10, 11)
    c.text_c(caps(tr("по API было бы", "at API price"), 8.5, TEXT_LO), colx[2], my + 10, 11)
    c.text_c(caps("×", 8.5, TEXT_LO), colx[3], my + 10, 11, align=2)
    ry = my + 23
    notes = []
    for cd in cards:
        ms = usage.money_summary(m.days, cd["product"], cd["data"].plan)
        nm = [Attr("Claude" if cd["product"] == "claude" else "Codex", 10.5, "semibold", TEXT_HI),
              Attr(" · " + ("≈" if ms["subEstimated"] else "") + "$" + str(int(ms["subMonthly"])) + tr("/мес", "/mo"),
                   10.5, "regular", TEXT_MID)]
        c.text_c(nm, colx[0], ry, 13)
        if ms["subEstimated"]:
            c.icon("pencil", rect_tl(colx[0] + c.width(nm) + 4, ry + 1.5, 10, 10), LINK, 1.3)
            hits.append(("settings", rect_tl(colx[0], ry - 1, 120, 15)))
        c.text_c(Attr("≈ " + fmt.fmt_usd(ms["subPerDay"]) + tr("/день", "/day"), 10.5, "regular", TEXT_HI), colx[1], ry, 13)
        if ms["usdApi"] > 0:
            c.text_c(Attr("≈ " + fmt.fmt_usd(ms["perCalendarDay"]) + tr("/день", "/day"), 10.5, "regular", TEXT_HI), colx[2], ry, 13)
            c.text_c(Attr(fmt.fmt_num(ms["ratio"]), 10.5, "regular", TEXT_HI), colx[3], ry, 13, align=2)
            notes.append(("Claude" if cd["product"] == "claude" else "Codex") + " ≈ " + fmt.fmt_usd(ms["perActiveDay"]))
        else:
            c.text_c(Attr(tr("пока нет", "none yet"), 10.5, "regular", TEXT_LO), colx[2], ry, 13)
            c.text_c(Attr("—", 10.5, "regular", TEXT_LO), colx[3], ry, 13, align=2)
        ry += 15
    if notes:
        c.text_c(Attr(tr("в активный день по API: ", "on an active day at API price: ") + " · ".join(notes), 9.5, "regular", TEXT_LO),
                 colx[0], my + 55, 11)
