"""The orange line on the main screen (docs/sync-protocol.md → Errors → Visibility) and the time
format it uses. Offline."""

if __package__:
    from . import _sync_env as env
else:
    import _sync_env as env

import time
import unittest

from ccl import sync
from ccl.gui import fmt

T = env.resp
MIN = 60


def tearDownModule():
    env.assert_real_files_untouched()


class TestWarning(env.SyncEnv):
    # Scenario 15
    def setUp(self):
        super().setUp()
        self.sign_in()
        self.now = time.time()

    def test_none_before_first_attempt_of_this_process(self):
        self.st().update(lastOkAt=self.now - 120 * MIN, lastError="старая ошибка", lastErrorAt=self.now - MIN)
        self.assertIsNone(sync.warning(now=self.now), "persisted state alone never warns")

    def test_skipped_cycles_do_not_count_as_attempts(self):
        self.st().update(lastOkAt=self.now - 120 * MIN, lastError="x", lastErrorAt=self.now - MIN,
                         backoffUntil=self.now + 600)
        self.assertEqual(self.cycle().skipped, "backoff")
        self.assertIsNone(sync.warning())

    def test_error_after_long_idle_warns(self):
        self.st().update(lastOkAt=self.now - 120 * MIN)
        self.gh.on("GET", "/gists/g1", T(500))
        self.assertFalse(self.cycle().ok)
        w = sync.warning(moment=lambda t: "HH:MM")
        self.assertEqual(w, "Синхронизация стоит с HH:MM: GET /gists/{id}: ответ 500")

    def test_short_idle_or_old_error_no_warning(self):
        self.gh.on("GET", "/gists/g1", T(500))
        self.cycle()
        st = self.st()
        st.update(lastOkAt=self.now - 20 * MIN, lastErrorAt=self.now - MIN)
        self.assertIsNone(sync.warning(now=self.now), "idle ≤ 30 min")
        st.update(lastOkAt=self.now - 120 * MIN, lastErrorAt=self.now - 121 * MIN)
        self.assertIsNone(sync.warning(now=self.now), "error older than the last success")
        st.update(lastError=None, lastErrorAt=None)
        self.assertIsNone(sync.warning(now=self.now), "no error, just quiet")

    def test_never_succeeded(self):
        self.gh.on("GET", "/gists/g1", T(0))
        self.cycle()
        self.assertTrue(sync.warning().startswith("Синхронизация не работает: "))

    def test_revoked_always_warns(self):
        self.st().update(revoked=True)
        self.assertEqual(sync.warning(), "GitHub отклонил вход — войдите заново")

    def test_signed_out_never_warns(self):
        self.gh.on("GET", "/gists/g1", T(500))
        self.cycle()
        self.st().update(login=None)
        self.assertIsNone(sync.warning())

    def test_three_week_idle_is_a_date_not_a_weekday(self):
        self.st().update(lastOkAt=self.now - 21 * 86400)
        self.gh.on("GET", "/gists/g1", T(500))
        self.cycle()
        w = sync.warning(moment=fmt.fmt_moment)
        moment = w.split("стоит с ", 1)[1].split(":", 1)[0]
        self.assertNotIn(moment.split()[0], fmt.RU_WD, w)
        self.assertRegex(moment, r"^\d{1,2} \S+")


class TestFmtMoment(unittest.TestCase):
    def test_weekday_only_within_six_days(self):
        now = time.time()
        old = fmt.fmt_moment(now - 21 * 86400)
        self.assertNotIn(old.split()[0], fmt.RU_WD, old)
        self.assertRegex(old, r"^\d{1,2} \S+, \d\d:\d\d$")
        recent = fmt.fmt_moment(now - 3 * 86400)
        self.assertIn(recent.split()[0], fmt.RU_WD, recent)
        self.assertRegex(fmt.fmt_moment(now), r"^\d\d:\d\d$")


if __name__ == "__main__":
    unittest.main()
