"""Helper for test_gui_layout: build the settings page offscreen for one style / language /
sync state (+ optionally "deb": installed from the package with an update waiting) and print
"OK" or "OVERFLOW …". Everything outside the process is stubbed — the
keyring (NOT isolated by XDG dirs), the gist, the limits APIs and the log index."""

import os
import shutil
import sys
import tempfile

style, lang, signed = sys.argv[1], sys.argv[2], sys.argv[3] == "in"
deb = "deb" in sys.argv[4:]
tmp = tempfile.mkdtemp()
os.environ["QT_QPA_PLATFORM"] = "offscreen"
os.environ["XDG_CONFIG_HOME"] = os.path.join(tmp, "config")
os.environ["XDG_STATE_HOME"] = os.path.join(tmp, "state")
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
if signed:
    sync.sync_state().update(login="someone")
if deb:
    update.is_packaged = lambda: True
    common.state().update(updateAvailable="99.0", updateDebUrl="https://example.invalid/x_all.deb")

import ccl.gui.app as A  # noqa: E402

qapp = QApplication(sys.argv)
qapp.setStyle(style)
app = A.TrayApp(qapp)
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
