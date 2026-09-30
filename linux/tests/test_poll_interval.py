"""Refresh interval: 5 and 15 minutes only, no 1 minute (issue #6 — one account polled every minute
from two machines got 429 from /api/oauth/usage for hours). The saved 60 of older versions is lifted
to 5 minutes at start; that part runs in gui_width_probe (TrayApp) through test_gui_layout."""

if __package__:
    from . import _isolate  # noqa: F401
else:
    import _isolate  # noqa: F401

import unittest

from ccl import common

try:
    from ccl.gui import panel
    HAVE_QT = True
except ImportError:
    HAVE_QT = False


class TestDefault(unittest.TestCase):
    def test_default_is_five_minutes(self):
        self.assertEqual(common.SETTINGS_DEFAULTS["interval"], 300)


@unittest.skipUnless(HAVE_QT, "PyQt5 not installed")
class TestChoices(unittest.TestCase):
    def test_choices(self):
        self.assertEqual(panel.POLL_CHOICES, (300, 900))
        self.assertEqual([sec for _, sec in panel.poll_segments()], [300, 900])
        self.assertEqual(panel.Model().interval, 300)

    def test_labels_follow_language(self):
        st = common.settings()
        saved = st.get("lang")
        try:
            st.set("lang", "ru")
            self.assertEqual([t for t, _ in panel.poll_segments()], ["5м", "15м"])
            st.set("lang", "en")
            self.assertEqual([t for t, _ in panel.poll_segments()], ["5m", "15m"])
        finally:
            st.set("lang", saved)

    def test_clamp(self):
        for value, want in ((300, 300), (900, 900), ("900", 900), (60, 300), ("60", 300), (0, 300),
                            (None, 300), ("junk", 300), (3600, 300), (-5, 300)):
            with self.subTest(value=value):
                self.assertEqual(panel.poll_interval(value), want)


if __name__ == "__main__":
    unittest.main()
