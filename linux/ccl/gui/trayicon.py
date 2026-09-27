"""The tray icon: the chosen percentages stacked in a small dark plate (Plasma / Fly trays are
square, so the Mac's "icon + 24/58%" strip becomes two rows of digits), coloured by severity,
with a thin product stripe along the bottom (Claude orange, Codex blue)."""

from PyQt5.QtCore import QRectF, Qt
from PyQt5.QtGui import QColor, QFont, QFontMetricsF, QIcon, QPainter, QPixmap

from .. import common, limits
from . import fmt, paint

SIZES = (16, 22, 24, 32, 44, 48, 64, 96, 128)
CLAUDE_MARK = QColor(217, 119, 87)
CODEX_MARK = QColor(110, 132, 255)


def metrics():
    raw = common.settings().get("trayMetrics") or "session,weekly"
    out = []
    for m in raw.split(","):
        m = m.strip()
        if m in ("session", "weekly", "model") and m not in out:
            out.append(m)
    return out or ["session", "weekly"]


def sev_color(v):
    s = limits.severity(v)
    return QColor(255, 69, 59) if s == 2 else QColor(255, 160, 10) if s == 1 else QColor(255, 255, 255)


def scoped_color(v):
    if v >= 80:
        return QColor(250, 56, 143)
    if v >= 50:
        return QColor(237, 107, 71)
    return QColor(77, 224, 194)


def values(d, picks=None):
    """[(number, colour)] for a product, following the user's picks; nil-safe like groupString."""
    if not d.present or d.auth == limits.LOGGED_OUT:
        return []
    stale = limits.is_stale(d)
    faint = QColor(255, 255, 255, 110)
    out = []
    for m in picks or metrics():
        if m == "session" and d.session is not None:
            out.append((d.session, faint if stale else sev_color(d.session)))
        elif m == "weekly" and d.weekly is not None:
            out.append((d.weekly, faint if stale else sev_color(d.weekly)))
        elif m == "model" and d.scoped is not None:
            out.append((d.scoped.percent, faint if stale else scoped_color(d.scoped.percent)))
    if not out:     # e.g. Codex has no per-model limit — show what it does have
        for v in (d.session, d.weekly):
            if v is not None:
                out.append((v, faint if stale else sev_color(v)))
    return out[:2]


def render(rows, mark, size, family):
    pm = QPixmap(size, size)
    pm.fill(Qt.transparent)
    p = QPainter(pm)
    p.setRenderHint(QPainter.Antialiasing)
    p.setRenderHint(QPainter.TextAntialiasing)
    r = QRectF(0.5, 0.5, size - 1, size - 1)
    p.setPen(Qt.NoPen)
    p.setBrush(QColor(24, 24, 26, 235))
    p.drawRoundedRect(r, size * 0.2, size * 0.2)
    if mark is not None:
        p.setBrush(mark)
        h = max(1.5, size * 0.08)
        p.drawRoundedRect(QRectF(size * 0.2, size - h - size * 0.04, size * 0.6, h), h / 2, h / 2)
    texts = [fmt.num_text(v) for v, _ in rows] or ["–"]
    colors = [c for _, c in rows] or [QColor(255, 255, 255, 140)]
    n = len(texts)
    usable_h = size * (0.86 if mark is None else 0.80)
    line_h = usable_h / n
    f = QFont(family or "")
    f.setWeight(QFont.Bold)
    px = line_h * (0.92 if n == 2 else 0.72)
    f.setPixelSize(max(6, int(px)))
    fm = QFontMetricsF(f)
    widest = max(fm.horizontalAdvance(t) for t in texts)
    if widest > size * 0.9:                     # "100" — shrink to fit
        f.setPixelSize(max(6, int(px * size * 0.9 / widest)))
        fm = QFontMetricsF(f)
    p.setFont(f)
    top = (usable_h - line_h * n) / 2 + size * 0.03
    for i, t in enumerate(texts):
        box = QRectF(0, top + i * line_h, size, line_h)
        p.setPen(colors[i])
        p.drawText(box, Qt.AlignCenter, t)
    p.end()
    return pm


def make_icon(rows, mark):
    icon = QIcon()
    fam = paint.FAMILY[0]
    for s in SIZES:
        icon.addPixmap(render(rows, mark, s, fam))
    return icon


def tooltip(claude, codex):
    def line(name, d):
        if not d.present:
            return None
        if d.auth == limits.LOGGED_OUT:
            return name + ": " + common.tr("нет входа Claude Code CLI", "Claude Code CLI not signed in")
        if d.auth == limits.EXPIRED and d.session is None and d.weekly is None:
            return name + ": " + common.tr("вход устарел", "sign-in expired")
        parts = []
        if d.session is not None:
            parts.append(common.tr("сессия ", "session ") + fmt.num_text(d.session) + "% (" + fmt.fmt_reset(d.session_reset) + ")")
        if d.weekly is not None:
            parts.append(common.tr("неделя ", "week ") + fmt.num_text(d.weekly) + "% (" + fmt.fmt_reset(d.weekly_reset) + ")")
        if d.scoped is not None:
            parts.append(d.scoped.name + " " + fmt.num_text(d.scoped.percent) + "%")
        s = name + ": " + (" · ".join(parts) if parts else "—")
        if limits.is_stale(d) and d.as_of:
            s += common.tr(" — данные от ", " — as of ") + fmt.fmt_reset(d.as_of)
        return s
    lines = [x for x in (line("Claude Code", claude), line("Codex", codex)) if x]
    return "\n".join(lines) if lines else common.tr("Claude Code и Codex не найдены", "Claude Code and Codex not found")
