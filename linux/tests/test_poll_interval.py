"""Refresh interval: 15/30/60 minutes (issue #6 — one account polled every minute
from two machines got 429 from /api/oauth/usage for hours). The saved 60 of older versions is lifted
to 30 minutes at start; that part runs in gui_width_probe (TrayApp) through test_gui_layout."""

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
    def test_default_is_thirty_minutes(self):
        self.assertEqual(common.SETTINGS_DEFAULTS["interval"], 1800)


@unittest.skipUnless(HAVE_QT, "PyQt5 not installed")
class TestChoices(unittest.TestCase):
    def test_choices(self):
        self.assertEqual(panel.POLL_CHOICES, (900, 1800, 3600))
        self.assertEqual([sec for _, sec in panel.poll_segments()], [900, 1800, 3600, 0])
        self.assertEqual(panel.Model().interval, 1800)

    def test_labels_follow_language(self):
        st = common.settings()
        saved = st.get("lang")
        try:
            st.set("lang", "ru")
            self.assertEqual([t for t, _ in panel.poll_segments()], ["15м", "30м", "1ч", "А"])
            st.set("lang", "en")
            self.assertEqual([t for t, _ in panel.poll_segments()], ["15m", "30m", "1h", "A"])
        finally:
            st.set("lang", saved)

    def test_clamp(self):
        for value, want in ((300, 1800), (900, 900), ("900", 900), (60, 1800), ("60", 1800), (0, 1800),
                            (None, 1800), ("junk", 1800), (1800, 1800), (3600, 3600), (-5, 1800),
                            (float("inf"), 1800), (float("nan"), 1800)):
            with self.subTest(value=value):
                self.assertEqual(panel.poll_interval(value), want)


if __name__ == "__main__":
    unittest.main()
