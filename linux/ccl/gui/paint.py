"""QPainter helpers that mirror the CoreGraphics/CoreText helpers of the macOS panel, with the
same top-left coordinate conventions, so the drawing code can follow the Swift almost line by
line. Sizes are logical pixels (the Mac's points)."""

import math
import os

from PyQt5.QtCore import QPointF, QRectF, Qt
from PyQt5.QtGui import QBrush, QColor, QFont, QFontMetricsF, QImage, QPainterPath, QPen

RES_DIRS = []


def res_path(name):
    for d in RES_DIRS:
        p = os.path.join(d, name)
        if os.path.exists(p):
            return p
    return None


_img_cache = {}


def image(name):
    if name not in _img_cache:
        p = res_path(name)
        _img_cache[name] = QImage(p) if p else None
    return _img_cache[name]


def rgb(r, g, b, a=1.0):
    return QColor.fromRgbF(r, g, b, a)


def gray(w, a):
    return QColor.fromRgbF(w, w, w, a)


def with_alpha(c, a):
    c = QColor(c)
    c.setAlphaF(a)
    return c


TEXT_HI, TEXT_MID, TEXT_LO = gray(1, 0.95), gray(1, 0.5), gray(1, 0.34)
BLUE = rgb(0.22, 0.55, 1.0)
PURPLE = rgb(0.78, 0.42, 0.98)
AMBER = rgb(1, 0.62, 0.18)
WARN = rgb(1.00, 0.63, 0.04)
CRIT = rgb(1.00, 0.27, 0.23)
LINK = rgb(0.42, 0.62, 0.96)
SCOPED = rgb(0.20, 0.85, 0.70)
MODEL = [rgb(0.20, 0.85, 0.70), rgb(0.99, 0.47, 0.38), rgb(0.98, 0.22, 0.56)]

WEIGHTS = {"regular": QFont.Normal, "medium": QFont.Medium, "semibold": QFont.DemiBold, "bold": QFont.Bold}
FAMILY = [None]
MONO = [None]


def font(size, weight="regular", kern=0.0, mono=False):
    f = QFont(MONO[0] if mono and MONO[0] else FAMILY[0] or "")
    f.setPixelSize(max(1, int(round(size))))
    f.setWeight(WEIGHTS.get(weight, QFont.Normal))
    if kern:
        f.setLetterSpacing(QFont.AbsoluteSpacing, kern)
    f.setHintingPreference(QFont.PreferNoHinting)
    return f


class Attr(object):
    """One run of styled text (the NSAttributedString of the Swift)."""

    def __init__(self, s, size, weight="regular", color=TEXT_HI, kern=0.0, mono=False):
        self.s, self.size, self.color = s, size, color
        self.font = font(size, weight, kern, mono)

    def width(self):
        return QFontMetricsF(self.font).horizontalAdvance(self.s)


def caps(s, size, color):
    return Attr(s.upper(), size, "semibold", color, kern=size * 0.06)


class Canvas(object):
    """Drawing primitives in top-left coordinates."""

    def __init__(self, p):
        self.p = p

    # -- text --
    @staticmethod
    def width(a):
        if isinstance(a, (list, tuple)):
            return sum(x.width() for x in a)
        return a.width()

    def _runs(self, a):
        return a if isinstance(a, (list, tuple)) else [a]

    def text_base(self, a, x, base_y, align=0):
        runs = self._runs(a)
        w = self.width(runs)
        dx = x - w / 2 if align == 1 else x - w if align == 2 else x
        for r in runs:
            self.p.setFont(r.font)
            self.p.setPen(QPen(r.color))
            self.p.drawText(QPointF(dx, base_y), r.s)
            dx += r.width()
        return w

    def text(self, a, x, top, align=0):
        """Cap-top (≈ ascender) at `top`, as the Mac's CoreText helper does."""
        size = self._runs(a)[0].size
        return self.text_base(a, x, top + size * 0.95, align)

    def text_c(self, a, x, top, h, align=0):
        """Vertically centre one line in a box of height `h` whose top is `top`."""
        size = self._runs(a)[0].size
        asc, desc = size * 0.95, size * 0.24
        return self.text(a, x, top + (h - asc - desc) / 2 + desc * 0.15, align)

    # -- shapes --
    def round_fill(self, r, rad, color):
        rad = min(rad, r.height() / 2, r.width() / 2)
        self.p.setPen(Qt.NoPen)
        self.p.setBrush(QBrush(color))
        self.p.drawRoundedRect(r, rad, rad)

    def round_stroke(self, r, rad, color, lw=1.0):
        rad = min(rad, r.height() / 2, r.width() / 2)
        self.p.setBrush(Qt.NoBrush)
        self.p.setPen(QPen(color, lw))
        self.p.drawRoundedRect(r, rad, rad)

    def hline(self, x0, x1, top, color):
        self.p.setPen(QPen(color, 1))
        self.p.drawLine(QPointF(x0, top + 0.5), QPointF(x1, top + 0.5))

    def dot(self, cx, cy, color, r=3.0):
        self.p.setPen(Qt.NoPen)
        self.p.setBrush(QBrush(color))
        self.p.drawEllipse(QPointF(cx, cy), r, r)

    def image(self, name, r, opacity=1.0):
        img = image(name)
        if img is None or img.isNull():
            return
        self.p.save()
        self.p.setOpacity(opacity)
        self.p.setRenderHint(self.p.SmoothPixmapTransform, True)
        self.p.drawImage(r, img)
        self.p.restore()

    # -- the SF Symbols the panel uses, drawn as vectors --
    def icon(self, name, r, color, weight=1.6):
        p = self.p
        p.save()
        pen = QPen(color, weight)
        pen.setCapStyle(Qt.RoundCap)
        pen.setJoinStyle(Qt.RoundJoin)
        p.setPen(pen)
        p.setBrush(Qt.NoBrush)
        cx, cy = r.center().x(), r.center().y()
        s = min(r.width(), r.height())
        if name == "refresh":
            rad = s * 0.38
            path = QPainterPath()
            path.arcMoveTo(QRectF(cx - rad, cy - rad, 2 * rad, 2 * rad), 60)
            path.arcTo(QRectF(cx - rad, cy - rad, 2 * rad, 2 * rad), 60, 300)
            p.drawPath(path)
            a = math.radians(60)
            tip = QPointF(cx + rad * math.cos(a), cy - rad * math.sin(a))
            p.setPen(Qt.NoPen)
            p.setBrush(QBrush(color))
            head = QPainterPath()
            hs = s * 0.26
            head.moveTo(tip + QPointF(hs * 0.55, -hs * 0.05))
            head.lineTo(tip + QPointF(-hs * 0.5, -hs * 0.6))
            head.lineTo(tip + QPointF(-hs * 0.25, hs * 0.55))
            head.closeSubpath()
            p.drawPath(head)
        elif name == "gear":
            outer, inner, hole = s * 0.46, s * 0.33, s * 0.14
            path = QPainterPath()
            teeth = 8
            for i in range(teeth * 2):
                ang = math.pi * 2 * i / (teeth * 2)
                rr = outer if i % 2 == 0 else inner
                for da in (-0.17, 0.17):
                    pt = QPointF(cx + rr * math.cos(ang + da), cy + rr * math.sin(ang + da))
                    if path.elementCount() == 0:
                        path.moveTo(pt)
                    else:
                        path.lineTo(pt)
            path.closeSubpath()
            path.addEllipse(QPointF(cx, cy), hole, hole)
            pen.setWidthF(weight * 0.8)
            p.setPen(pen)
            p.drawPath(path)
        elif name == "arrow_ne":
            a, b = QPointF(r.left() + s * 0.2, r.bottom() - s * 0.2), QPointF(r.right() - s * 0.2, r.top() + s * 0.2)
            p.drawLine(a, b)
            p.drawLine(b, QPointF(b.x() - s * 0.5, b.y()))
            p.drawLine(b, QPointF(b.x(), b.y() + s * 0.5))
        elif name == "warning":
            p.setPen(Qt.NoPen)
            p.setBrush(QBrush(color))
            tri = QPainterPath()
            tri.moveTo(cx, r.top() + s * 0.06)
            tri.lineTo(r.right() - s * 0.02, r.bottom() - s * 0.08)
            tri.lineTo(r.left() + s * 0.02, r.bottom() - s * 0.08)
            tri.closeSubpath()
            p.drawPath(tri)
            p.setBrush(QBrush(QColor(20, 20, 20)))
            p.drawRoundedRect(QRectF(cx - s * 0.055, r.top() + s * 0.34, s * 0.11, s * 0.30), s * 0.05, s * 0.05)
            p.drawEllipse(QPointF(cx, r.bottom() - s * 0.22), s * 0.065, s * 0.065)
        elif name == "chevron_down":
            p.drawPolyline(QPointF(r.left() + s * 0.1, cy - s * 0.2), QPointF(cx, cy + s * 0.2),
                           QPointF(r.right() - s * 0.1, cy - s * 0.2))
        elif name == "chevron_right":
            p.drawPolyline(QPointF(cx - s * 0.2, r.top() + s * 0.1), QPointF(cx + s * 0.2, cy),
                           QPointF(cx - s * 0.2, r.bottom() - s * 0.1))
        elif name == "pencil":
            p.drawLine(QPointF(r.left() + s * 0.2, r.bottom() - s * 0.2), QPointF(r.right() - s * 0.15, r.top() + s * 0.15))
            p.drawLine(QPointF(r.left() + s * 0.12, r.bottom() - s * 0.12), QPointF(r.left() + s * 0.3, r.bottom() - s * 0.12))
        elif name == "power":
            rad = s * 0.42
            path = QPainterPath()
            path.arcMoveTo(QRectF(cx - rad, cy - rad, 2 * rad, 2 * rad), 110)
            path.arcTo(QRectF(cx - rad, cy - rad, 2 * rad, 2 * rad), 110, -320)
            p.drawPath(path)
            p.drawLine(QPointF(cx, cy - rad * 0.15), QPointF(cx, cy - rad * 1.15))
        p.restore()

    def gauge(self, cx, cy, r, th, pct, color):
        """A 270° ring open at the bottom (start at 225°, sweeping clockwise)."""
        p = self.p
        rect = QRectF(cx - r, cy - r, 2 * r, 2 * r)
        pen = QPen(gray(1, 0.08), th)
        pen.setCapStyle(Qt.RoundCap)
        p.setBrush(Qt.NoBrush)
        p.setPen(pen)
        p.drawArc(rect, 225 * 16, -270 * 16)
        if pct is not None and pct > 0:
            frac = min(100.0, max(0.0, pct)) / 100
            glow = QPen(with_alpha(color, 0.18), th + 5)
            glow.setCapStyle(Qt.RoundCap)
            p.setPen(glow)
            p.drawArc(rect, 225 * 16, int(-270 * 16 * frac))
            pen = QPen(color, th)
            pen.setCapStyle(Qt.RoundCap)
            p.setPen(pen)
            p.drawArc(rect, 225 * 16, int(-270 * 16 * frac))


def rect_tl(x, top, w, h):
    return QRectF(x, top, w, h)
