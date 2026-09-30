"""Text formatting shared by the panel and the tray tooltip (ports of fmtReset, fmtSpan, …)."""

import math
import time

from .. import common
from ..common import app_lang, tr

RU_MON = ["янв.", "февр.", "мар.", "апр.", "мая", "июн.", "июл.", "авг.", "сент.", "окт.", "нояб.", "дек."]
EN_MON = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
RU_WD = ["пн", "вт", "ср", "чт", "пт", "сб", "вс"]
EN_WD = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]


def rnd(v):
    """Half away from zero, like Swift's `.rounded()` (Python's round() is banker's)."""
    return math.floor(v + 0.5) if v >= 0 else -math.floor(-v + 0.5)


def _is_today(t):
    return common.day_key(t) == common.today_key()


def hhmm(t):
    return time.strftime("%H:%M", time.localtime(t))


def clock(t):
    return time.strftime("%H:%M:%S", time.localtime(t))


def weekday(t):
    return (RU_WD if app_lang() == "ru" else EN_WD)[time.localtime(t).tm_wday]


def fmt_reset(t):
    """"18:16" today, else "1 окт., 18:16" / "Oct 1, 18:16"."""
    if t is None:
        return "—"
    if _is_today(t):
        return hhmm(t)
    lt = time.localtime(t)
    if app_lang() == "ru":
        return "%d %s, %s" % (lt.tm_mday, RU_MON[lt.tm_mon - 1], hhmm(t))
    return "%s %d, %s" % (EN_MON[lt.tm_mon - 1], lt.tm_mday, hhmm(t))


def fmt_num(v, decimals=1):
    """"13,4" in Russian, "13.4" in English — no trailing zero for whole numbers."""
    r = rnd(v * 10 ** decimals) / 10 ** decimals
    if r == rnd(r) and decimals <= 1:
        s = str(int(rnd(r)))
    else:
        s = ("%." + str(decimals) + "f") % r
    return s.replace(".", ",") if app_lang() == "ru" else s


def fmt_pct(v, decimals=1):
    return fmt_num(v, decimals) + "%"


def fmt_signed_pts(v):
    return ("+" if v >= 0 else "−") + fmt_num(abs(v)) + tr(" п.", " pts")


def fmt_usd(v):
    if v >= 100:
        return "$" + str(int(rnd(v)))
    return "$" + fmt_num(v, 2)


def fmt_span(hours):
    """"2 ч 13 мин" / "3,7 дня" / "45 мин"."""
    if hours >= 24:
        days = rnd(hours / 24 * 10) / 10
        if days == rnd(days):
            n = int(rnd(days))
            if app_lang() == "ru":
                return "%d %s" % (n, "день" if n == 1 else "дня" if 2 <= n <= 4 else "дней")
            return "%d %s" % (n, "day" if n == 1 else "days")
        return fmt_num(days) + tr(" дня", " days")
    if hours >= 1:
        h = int(hours)
        m = int(rnd((hours - h) * 60))
        return ("%d" % h + tr(" ч", " h")) if m == 0 else ("%d" % h + tr(" ч ", " h ") + "%d" % m + tr(" мин", " min"))
    return "%d" % max(1, int(rnd(hours * 60))) + tr(" мин", " min")


def fmt_moment(t):
    """"09:37" today, "сб 15:33" within the week, else "26 сент, 15:33"."""
    if _is_today(t):
        return hhmm(t)
    if t > time.time() - 6 * 86400:
        return weekday(t) + " " + hhmm(t)
    lt = time.localtime(t)
    if app_lang() == "ru":
        return "%d %s, %s" % (lt.tm_mday, RU_MON[lt.tm_mon - 1].rstrip("."), hhmm(t))
    return "%d %s, %s" % (lt.tm_mday, EN_MON[lt.tm_mon - 1], hhmm(t))


def moment_lower(t):
    s = fmt_moment(t)
    return s[:1].lower() + s[1:] if app_lang() == "ru" else s


def reset_short(t):
    """"11:50" today, else "пн, 03:00"."""
    if _is_today(t):
        return hhmm(t)
    return weekday(t) + ", " + hhmm(t)


def fmt_rate(pace):
    if pace.window_h <= 24:
        return fmt_num(pace.avg_rate_h) + tr("%/ч", "%/h")
    return fmt_num(pace.avg_rate_h * 24) + tr("%/день", "%/day")


def num_text(v):
    return "–" if v is None else str(int(rnd(v)))
