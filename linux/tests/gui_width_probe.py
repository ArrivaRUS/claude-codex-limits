"""Helper for test_gui_layout: build the settings page offscreen for one style / language /
sync state (+ optionally "deb": installed from the package with an update waiting) and print
"OK" or "OVERFLOW …". Everything outside the process is stubbed — the
keyring (NOT isolated by XDG dirs), the gist, the limits APIs and the log index."""

if __package__:
    from . import _isolate  # noqa: F401
else:
    import _isolate  # noqa: F401


import os
import shutil
import sys

style, lang, signed = sys.argv[1], sys.argv[2], sys.argv[3] == "in"
deb = "deb" in sys.argv[4:]
tmp = _isolate.ROOT
os.environ["QT_QPA_PLATFORM"] = "offscreen"
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from PyQt5.QtCore import QPoint  # noqa: E402
from PyQt5.QtGui import QFontMetricsF  # noqa: E402
from PyQt5.QtWidgets import QApplication, QPushButton, QWidget  # noqa: E402

from ccl import common, limits, sync, update, usage, vault  # noqa: E402

vault._ss = lambda: None
vault.read = (lambda: ("stub", "secret-service")) if signed else (lambda: (None, None))
sync.sync_cycle = lambda *a, **k: sync.SyncResult()
limits.fetch_claude = lambda: limits.LimitData()
limits.fetch_codex = lambda live=True: limits.LimitData()
usage.refresh = lambda blocking=True, progress=None: (usage.new_index(), False, True)
common.settings().set("lang", lang)
common.settings().set("interval", 60)      # the removed 1-minute choice, saved by 0.3.2 and older
if signed:
    sync.sync_state().update(login="someone")
if deb:
    update.is_packaged = lambda: True
    common.state().update(updateAvailable="99.0", updateDebUrl="https://example.invalid/x_all.deb")

import ccl.gui.app as A  # noqa: E402

qapp = QApplication(sys.argv)
qapp.setStyle(style)
app = A.TrayApp(qapp)
iv = (app.model.interval, common.settings().get("interval"), app.timer.interval())
if iv != (1800, 1800, 1800000):
    print("INTERVAL %s" % (iv,))                          # issue #6: 1 minute must become 30 for good
# Check real Settings controls and timer wiring without network or real transcripts.
page = app.win.settings_page
page.products["claude"].setChecked(False)
if common.product_enabled("claude") or app.model.claude.present:
    print("SUBSCRIPTION Claude did not turn off")
page.products["codex"].setChecked(False)
if common.product_enabled("codex") or app.model.codex.present:
    print("SUBSCRIPTION Codex did not turn off")
page.products["codex"].setChecked(True)
if not common.product_enabled("codex"):
    print("SUBSCRIPTION Codex did not turn on")
for sec in (900, 1800, 3600):
    app.action("iv%d" % sec)
    if (app.model.interval, common.settings().get("interval"), app.timer.interval()) != (sec, sec, sec * 1000):
        print("INTERVAL click failed", sec)
w = app.win
w.anchor = QPoint(900, 900)
w.show_page(1)
w.place()
w.show()
qapp.processEvents()
page = w.settings_page
vp = page.scroll.viewport().width()
over = [(type(x).__name__, x.mapTo(page.body, QPoint(x.width(), 0)).x())
        for x in page.body.findChildren(QWidget) if x.isVisible() and x.mapTo(page.body, QPoint(x.width(), 0)).x() > vp]
bodymin = page.body.minimumSizeHint().width()
# pills are sized from their text (as on the Mac) — the text must still fit inside the padding
clipped = [b.text() for b in page.body.findChildren(QPushButton)
           if str(b.property("role")).startswith("pill") and b.isVisible()
           and QFontMetricsF(b.font()).horizontalAdvance(b.text()) + 2 * 9 > b.width()]
if clipped:
    print("CLIPPED %s" % clipped)
else:
    print("OK" if bodymin <= vp and not over else "OVERFLOW viewport=%d bodymin=%d %s" % (vp, bodymin, over[:3]))
shutil.rmtree(tmp, ignore_errors=True)
