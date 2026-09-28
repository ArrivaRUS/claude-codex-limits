"""The settings page must fit the popup in every style, language and sync state — a wider
style (Breeze on KDE/Fly) once pushed its right edge under the scroll bar — and the About
row's pills must not clip their text."""

import os
import subprocess
import sys
import unittest

try:
    from PyQt5.QtWidgets import QStyleFactory  # noqa: F401
    HAVE_QT = True
except ImportError:
    HAVE_QT = False

PROBE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "gui_width_probe.py")


@unittest.skipUnless(HAVE_QT, "PyQt5 not installed")
class TestSettingsFit(unittest.TestCase):
    def test_fits(self):
        from PyQt5.QtWidgets import QStyleFactory
        styles = [s for s in ("Fusion", "Breeze") if s in QStyleFactory.keys()]
        for style in styles:
            for lang in ("ru", "en"):
                for state in ("out", "in", "in deb"):
                    with self.subTest(style=style, lang=lang, sync=state):
                        r = subprocess.run([sys.executable, PROBE, style, lang] + state.split(), stdout=subprocess.PIPE,
                                           stderr=subprocess.PIPE, timeout=120)
                        out = r.stdout.decode("utf-8", "replace").strip()     # Qt's warnings go to stderr
                        self.assertEqual(out, "OK", out + r.stderr.decode("utf-8", "replace")[-400:])


if __name__ == "__main__":
    unittest.main()
