"""Independent FRESH-4H contract/regression checks. Only synthetic observations."""
if __package__:
    from ._freshness_env import *
else:
    from _freshness_env import *

import copy
import json
from types import MethodType


class TestFreshness(OfflineCase):
    def test_inclusive_four_hour_boundary_even_after_single_network_failure(self):
        for age, stale in ((14399, False), (14400, False), (14401, True)):
            for error in (None, 'offline fixture'):
                for weekly_only in (False, True):
                    with self.subTest(age=age, error=error, weekly_only=weekly_only):
                        d = reading(age, weekly_only)
                        d.error = error
                        self.assertEqual(limits.is_stale(d, now=NOW), stale)
                        self.assertEqual(limits.metric_is_stale(d, 'weekly', now=NOW), stale)
                        self.assertEqual(d.auth, limits.OK)

    def test_missing_future_or_invalid_asof_never_fabricates_pace(self):
        for at in (None, NOW + 1, float('nan'), float('inf')):
            with self.subTest(at=at):
                d = reading(); d.as_of = at
                self.assertTrue(limits.is_stale(d, now=NOW))
                if at is None or not math.isfinite(at):
                    self.assertTrue(all(row['pace'] is None for row in limits.paced_limits(d, 'codex')))
                model = SimpleNamespace(pending_products=set())
                detail = panel_helpers()['feedback_copy'](model, d, 'codex')[3]
                self.assertIn('pace paused', detail)

    def test_each_window_expires_at_reset_without_hiding_the_other_windows(self):
        for metric in ('session', 'weekly', 'model'):
            for delta, expired in ((1, False), (0, True), (-1, True)):
                with self.subTest(metric=metric, delta=delta):
                    d = reading()
                    d.scoped = limits.Scoped('fixture-model', 25, d.weekly_reset)
                    if metric == 'model': d.scoped.reset = NOW + delta
                    else: setattr(d, metric + '_reset', NOW + delta)
                    self.assertEqual(limits.metric_is_stale(d, metric, NOW), expired)
                    self.assertFalse(limits.is_stale(d, NOW))
                    other = 'weekly' if metric != 'weekly' else 'session'
                    self.assertFalse(limits.metric_is_stale(d, other, NOW))

    def test_snapshot_pace_remains_identical_when_wall_clock_moves(self):
        d = reading(3600, weekly_only=True)
        history = limits.History()
        history.samples = [{'p': 'codex', 't': d.as_of - 900, 'w': 40},
                           {'p': 'codex', 't': d.as_of, 'w': 47},
                           {'p': 'codex', 't': d.as_of + 900, 'w': 99}]
        snapshots = []
        for now in (NOW, NOW + 7200, NOW + 86400):
            with patch.object(limits.time, 'time', return_value=now):
                rows = limits.paced_limits(d, 'codex', history)
                self.assertEqual([r['id'] for r in rows], ['weekly'])
                p = rows[0]['pace']; self.assertIsNotNone(p)
                self.assertAlmostEqual(p.plan_pct, 50)
                self.assertAlmostEqual(p.projected, 94)
                self.assertAlmostEqual(p.recent_rate_h, 28)
                snapshots.append(vars(p).copy())
        self.assertEqual(snapshots[0], snapshots[1]); self.assertEqual(snapshots[1], snapshots[2])

    def test_unknown_or_impossible_window_timing_does_not_project(self):
        d = reading()
        for used, reset in ((31, None), (31, d.as_of), (31, d.as_of - 1),
                            (31, d.as_of + 5 * 3600 + 1), (-1, NOW + 1),
                            (float('nan'), NOW + 1), (31, float('inf'))):
            with self.subTest(used=used, reset=reset):
                d.session, d.session_reset = used, reset
                self.assertIsNone(limits.paced_limits(d, 'codex')[0]['pace'])


class TestPresentation(OfflineCase):
    def test_simple_and_tray_dim_only_the_reset_metric(self):
        d = reading(); d.session_reset = NOW
        before = copy.deepcopy(vars(d))
        c = simple_card(d)
        colors = dict(c.gauges)
        self.assertEqual(colors[31.0], ('gray', 1, 0.3))
        self.assertNotEqual(colors[47.0], ('gray', 1, 0.3))
        self.assertIn('window reset', [s for s, _ in c.texts])
        values = dict(tray_values(d, ['session', 'weekly']))
        self.assertEqual(values[31.0], (255, 255, 255, 110))
        self.assertNotEqual(values[47.0], (255, 255, 255, 110))
        self.assertEqual(vars(d), before)

    def test_weekly_only_simple_and_tray_stay_active_at_four_hours(self):
        d = reading(14400, weekly_only=True)
        c = simple_card(d)
        self.assertEqual(len(c.gauges), 1)
        self.assertEqual(c.gauges[0][0], 47)
        self.assertNotEqual(c.gauges[0][1], ('gray', 1, 0.3))
        self.assertEqual([v for v, _ in tray_values(d, ['session'])], [47])
        self.assertNotEqual(tray_values(d, ['session'])[0][1], (255, 255, 255, 110))
        cards = panel_helpers()['adv_cards'](SimpleNamespace(claude=limits.absent_limits(), codex=d, history=None))
        rows = next(c for c in cards if c['product'] == 'codex')['rows']
        self.assertEqual([r['limit']['id'] for r in rows if r['limit']], ['weekly'])
        self.assertEqual(rows[0]['kind'], 'full')

    def test_old_snapshot_is_labeled_with_asof_and_keeps_historical_projection(self):
        d = reading(14401, weekly_only=True)
        h = panel_helpers()
        cards = h['adv_cards'](SimpleNamespace(claude=limits.absent_limits(), codex=d, history=None))
        card = next(c for c in cards if c['product'] == 'codex')
        self.assertTrue(card['paused'])
        self.assertIsNotNone(card['rows'][0]['limit']['pace'])
        detail = h['feedback_copy'](SimpleNamespace(pending_products=set()), d, 'codex')[3]
        self.assertIn('Snapshot:', detail)
        self.assertNotIn('sign-in', detail)
        self.assertEqual(h['notice_h'](card), 0, 'stale annotation must not reserve an empty row')

    def test_confirmed_auth_is_separate_from_fresh_snapshot_and_network_error(self):
        h = panel_helpers()
        for auth in (limits.EXPIRED, limits.LOGGED_OUT, limits.READ_ERROR):
            d = reading(); d.auth = auth
            self.assertFalse(limits.is_stale(d, NOW))
            card = h['adv_cards'](SimpleNamespace(claude=d, codex=limits.absent_limits(), history=None))[0]
            self.assertTrue(card['paused'])
            self.assertFalse(any(r['kind'] == 'full' for r in card['rows']))
            self.assertEqual(h['limit_can_fix']('claude', auth), auth in (limits.EXPIRED, limits.LOGGED_OUT))
            self.assertFalse(h['limit_can_fix']('codex', auth))
        d = reading(7200); d.error = 'offline fixture'; d.next_poll_at = NOW + 1800
        c = simple_card(d)
        detail = h['feedback_copy'](SimpleNamespace(pending_products=set()), d, 'codex')[3]
        self.assertIn('retry at', detail)
        self.assertFalse(any('sign-in' in s for s, _ in c.texts))
        self.assertTrue(all(color != ('gray', 1, 0.3) for _, color in c.gauges))


class TestHistory(OfflineCase):
    def test_record_uses_observation_time_in_memory_on_disk_and_recent_rate(self):
        history = limits.History()
        first = reading(); first.as_of = NOW - 1800; first.weekly = 40
        second = reading(); second.as_of = NOW - 900; second.weekly = 47
        history.record(first, 'codex'); history.record(second, 'codex')
        self.assertEqual([s['t'] for s in history.samples], [NOW - 1800, NOW - 900])
        self.assertAlmostEqual(history.recent_rate('codex', 'w', 180, now=second.as_of), 28)
        with open(common.HISTORY_PATH) as stream:
            disk = [json.loads(line) for line in stream]
        self.assertEqual(disk, history.samples)
        history.record(second, 'codex'); history.record(first, 'codex')
        self.assertEqual(history.samples, disk)  # duplicate fallback must not flatten pace

    def test_record_rejects_unknown_future_failed_and_cached_observations(self):
        for kind in ('unknown', 'future', 'error', 'cache', 'failed', 'auth', 'absent', 'disabled'):
            with self.subTest(kind=kind):
                d = reading(); history = limits.History()
                self.settings.set('monitor_codex', kind != 'disabled')
                if kind == 'unknown': d.as_of = None
                if kind == 'future': d.as_of = NOW + 1
                if kind == 'error': d.error = 'offline fixture'
                if kind == 'cache': d.from_cache = True
                if kind == 'failed': d.poll_failed = True
                if kind == 'auth': d.auth = limits.EXPIRED
                if kind == 'absent': d.present = False
                history.record(d, 'codex')
                self.assertEqual(history.samples, [])
                self.assertFalse(os.path.exists(common.HISTORY_PATH))


class TestFailedLive(OfflineCase):
    def test_failed_live_survives_rollout_or_cache_fallback_and_enters_backoff(self):
        for cached in (False, True):
            with self.subTest(cached=cached):
                fallback = reading(7200, weekly_only=True)
                rollout = reading(8000, weekly_only=True) if cached else fallback
                cache = {'codex': fallback.to_dict()} if cached else {}
                common.write_json(common.CACHE_PATH, cache)
                attempt = limits.LimitData(); attempt.error = 'offline fixture'
                with patch.object(limits, 'codex_usage_live', return_value=attempt) as live, \
                     patch.object(limits, 'codex_from_rollout', return_value=rollout):
                    result = limits.fetch_codex(live=True)
                live.assert_called_once_with()
                self.assertEqual((result.weekly, result.as_of), (fallback.weekly, fallback.as_of))
                self.assertFalse(result.api_fresh)
                self.assertFalse(limits.is_stale(result, NOW))
                state = polling.PollState({'interval': 900}); state.begin(NOW - 10)
                ns = publish_callbacks()
                fake = SimpleNamespace(busy_limits=True, selection_generation=1,
                    model=SimpleNamespace(claude=limits.absent_limits(), codex=result, history=limits.History(), pending_products={'codex'}),
                    poll_states={'codex': state}, update_sync_warning=Mock(), check_alarms=Mock(), update_tray=Mock(),
                    win=SimpleNamespace(view=SimpleNamespace(update=Mock()), page0_changed=Mock()))
                bind_owner(fake, ns)
                fake.refresh_states['codex'] = quota_refresh.RefreshState()
                ticket = fake.refresh_states['codex'].admit('manual', NOW - 10, monotonic_now=NOW - 10).ticket
                fake.save_poll_states = MethodType(ns['publish_auto_intervals'], fake)
                ns['on_limits'](fake, 'codex', ticket, result)
                self.assertTrue(state.failed); self.assertEqual(state.interval, 1800)
                self.assertTrue(fake.model.codex.poll_failed, 'failed live status was erased before UI')
                self.assertEqual(fake.model.codex.next_poll_at, NOW + 1800)
                self.assertEqual(fake.model.history.samples, [], 'failed fallback invented a history observation')
                self.assertIn('retry at', panel_helpers()['limit_retry_notice'](result, compact=True))
                self.assertEqual(common.read_json(common.CACHE_PATH), cache)
                self.assertNotIn('poll_failed', result.to_dict())
                self.assertNotIn('next_poll_at', result.to_dict())
                good = reading(0, weekly_only=True); good.api_fresh = True
                with patch.object(limits.time, 'time', return_value=NOW + 30):
                    ticket = fake.refresh_states['codex'].admit('manual', NOW + 30, monotonic_now=NOW + 30).ticket
                    ns['on_limits'](fake, 'codex', ticket, good)
                self.assertFalse(fake.model.codex.poll_failed)
                self.assertGreater(fake.model.codex.next_poll_at, NOW + 30)

    def test_fixed_retry_uses_provider_attempt_deadline_not_global_timer_and_does_not_leak(self):
        self.settings.set('autoPoll', False)
        failed = polling.PollState({'failed': True, 'interval': 14400, 'last_attempt': NOW - 810})
        healthy = polling.PollState({'failed': False, 'last_attempt': NOW - 100})
        fake = SimpleNamespace(model=SimpleNamespace(claude=reading(), codex=reading(), interval=900, pending_products=set()),
            poll_states={'claude': healthy, 'codex': failed}, timer=SimpleNamespace(remainingTime=lambda: 90000))
        ns = publish_callbacks(); bind_owner(fake, ns)
        ns['publish_auto_intervals'](fake)
        self.assertEqual(fake.model.codex.next_poll_at, NOW + 90)
        self.assertTrue(fake.model.codex.poll_failed)
        self.assertEqual(fake.model.claude.next_poll_at, NOW + 800)
        self.assertFalse(fake.model.claude.poll_failed)
        failed.last_attempt = NOW - 900
        fake.timer.remainingTime = lambda: 0
        ns['publish_auto_intervals'](fake)
        self.assertIn('retry due', panel_helpers()['limit_retry_notice'](fake.model.codex))
        fake.timer.remainingTime = lambda: -1
        ns['publish_auto_intervals'](fake)
        self.assertEqual(fake.model.codex.next_poll_at, NOW)
        unknown = reading(); unknown.poll_failed = True
        self.assertIn('scheduled retry', panel_helpers()['limit_retry_notice'](unknown))

    def test_offline_only_read_is_not_labeled_failed_live(self):
        with patch.object(limits, 'codex_usage_live', side_effect=AssertionError('offline must not call live')), \
             patch.object(limits, 'codex_from_rollout', return_value=reading(60, True)):
            d = limits.fetch_codex(live=False)
        self.assertFalse(d.poll_failed); self.assertIsNone(d.error)


class TestDeadlines(OfflineCase):
    def test_scheduled_four_hour_boundary_and_local_activity_cannot_bypass_error_backoff(self):
        state = polling.PollState({'interval': 14400, 'last_attempt': NOW})
        for age, due in ((14399, False), (14400, True), (14401, True)):
            self.assertEqual(state.due(NOW + age), due)
        state.failed = True
        self.assertFalse(state.due(NOW + 900))
        self.assertFalse(state.local_activity([NOW + 10, NOW + 20, NOW + 30], NOW + 40))
        self.assertEqual(state.interval, 14400)
        restored = polling.PollState(json.loads(json.dumps(state.saved())))
        self.assertTrue(restored.due(NOW + 14400))

    def test_backoff_cap_request_duration_and_busy_worker(self):
        state = polling.PollState({'interval': 900})
        d = reading(); d.error = 'offline fixture'
        for interval in (1800, 3600, 14400, 14400):
            state.begin(NOW); state.observe(d, NOW + 30)
            self.assertEqual(state.interval, interval)
            self.assertFalse(state.due(NOW + 30 + interval - 1))
            self.assertTrue(state.due(NOW + 30 + interval))
        ns = refresh_method()
        fake = SimpleNamespace(busy_limits=True, poll_states={p: polling.PollState({'last_attempt': NOW - 14400, 'interval': 14400})
                                                            for p in ('claude', 'codex')},
                               model=SimpleNamespace(claude=reading(), codex=reading(), interval=14400), save_poll_states=Mock())
        bind_owner(fake, ns)
        for state in fake.refresh_states.values():
            state.admit('manual', NOW, monotonic_now=NOW)
        ns['refresh_limits'](fake, scheduled=True)
        ns['threading'].Thread.assert_not_called()

    def test_actual_worker_callback_attempts_only_due_product_once(self):
        ns = refresh_method()
        fake = SimpleNamespace(busy_limits=False, selection_generation=7, save_poll_states=Mock(),
                               model=SimpleNamespace(claude=reading(), codex=reading(), pending_products=set()),
                               poll_states={'claude': polling.PollState({'interval': 14400, 'last_attempt': NOW - 14399}),
                                            'codex': polling.PollState({'interval': 14400, 'last_attempt': NOW - 14400})},
                               bridge=SimpleNamespace(limits_done=SimpleNamespace(emit=Mock())),
                               win=SimpleNamespace(view=SimpleNamespace(update=Mock())))
        bind_owner(fake, ns)
        ns['threading'].Thread = Mock(side_effect=lambda target, **kw: SimpleNamespace(start=target))
        with patch.object(limits, 'fetch_claude', side_effect=AssertionError('Claude not due')), \
             patch.object(limits, 'fetch_codex', return_value=reading()) as fetch, \
             patch.object(limits, 'apply_provider_cache', side_effect=AssertionError('worker cache publication')):
            ns['refresh_limits'](fake, scheduled=True)
            ns['refresh_limits'](fake, scheduled=True)  # busy guard, no second attempt
        fetch.assert_called_once_with(live=True)
        ns['threading'].Thread.assert_called_once()
        self.assertIsNotNone(fake.refresh_states['codex'].flight)
        self.assertIsNone(fake.refresh_states['claude'].flight)
        self.assertEqual(fake.poll_states['codex'].last_attempt, NOW)
        self.assertEqual(fake.poll_states['claude'].last_attempt, NOW - 14399)
        fake.bridge.limits_done.emit.assert_called_once()
        fake.save_poll_states.assert_called_with()

    def test_weekly_only_live_observation_recovers_backoff(self):
        state = polling.PollState({'interval': 3600, 'failed': True})
        d = reading(0, weekly_only=True); d.api_fresh = True
        state.begin(NOW); state.observe(d, NOW)
        self.assertFalse(state.failed)
        self.assertEqual(state.observed_at, NOW)


class TestIntervalTransitions(OfflineCase):
    def fake_owner(self, auto=True):
        self.settings.set('autoPoll', auto)
        ns = interval_handlers()
        d = reading(60, weekly_only=True)
        failed = polling.PollState({'failed': True, 'interval': 14400, 'last_attempt': NOW})
        fake = SimpleNamespace(model=SimpleNamespace(claude=limits.absent_limits(), codex=d, interval=900),
                               poll_states={'codex': failed}, busy_limits=False, timer=RecordingTimer(),
                               scan_activity=Mock(), refresh_limits=Mock())
        win = SimpleNamespace(view=SimpleNamespace(update=Mock()), page0_changed=Mock())
        fake.win = win
        bind_owner(fake, ns)
        for name in ('start_poll_timer', 'publish_auto_intervals', 'scheduled_at'):
            setattr(fake, name, MethodType(ns[name], fake))
        fake.start_poll_timer(); fake.publish_auto_intervals()
        return ns, fake

    def test_real_interval_handler_updates_canonical_retry_for_auto_fixed_and_fixed_fixed(self):
        ns, fake = self.fake_owner()
        self.assertEqual(fake.model.codex.next_poll_at, NOW + 14400)
        for hid, delay in (('iv900', 900), ('iv3600', 3600), ('iv1800', 1800), ('iv14400', 14400), ('iv0', 14400), ('iv900', 900)):
            with self.subTest(hid=hid):
                ns['action'](fake, hid)
                self.assertEqual(fake.model.codex.next_poll_at, NOW + delay)
                self.assertTrue(fake.model.codex.poll_failed)
                self.assertEqual(fake.model.codex.as_of, NOW - 60)
                self.assertEqual(fake.model.codex.weekly, 47)
                self.assertGreater(fake.timer.remainingTime(), 0)
                self.assertLessEqual(fake.timer.remainingTime(), 60000)
        fake.scan_activity.assert_called_once_with()
        fake.refresh_limits.assert_called_once_with(scheduled=True)
        ns['threading'].Thread.assert_not_called()

    def test_fixed_to_fixed_updates_provider_deadline_with_safe_timer_checkpoint(self):
        ns, fake = self.fake_owner(auto=False)
        self.assertEqual(fake.model.codex.next_poll_at, NOW + 900)
        ns['action'](fake, 'iv3600')
        self.assertGreater(fake.timer.remainingTime(), 0)
        self.assertLessEqual(fake.timer.remainingTime(), 60000)
        self.assertEqual(fake.model.codex.next_poll_at, NOW + 3600)

    def test_fixed_to_auto_restores_product_backoff_deadline(self):
        ns, fake = self.fake_owner(auto=False)
        ns['action'](fake, 'iv0')
        self.assertEqual(fake.model.codex.next_poll_at, NOW + 14400)
        self.assertTrue(fake.model.codex.poll_failed)
        fake.refresh_limits.assert_called_once_with(scheduled=True)

    def test_reopen_after_interval_change_keeps_deadline_from_canonical_model(self):
        ns, fake = self.fake_owner()
        ns['action'](fake, 'iv900')
        # Real popup handler, fake geometry/windows; reopens must see the same canonical data.
        visible = [False]
        window = SimpleNamespace(last_hide=NOW - 1, isVisible=lambda: visible[0],
            hide=lambda: visible.__setitem__(0, False), show=lambda: visible.__setitem__(0, True),
            stack=SimpleNamespace(setCurrentIndex=Mock()), place=Mock(), raise_=Mock(), activateWindow=Mock())
        for _ in range(2):
            ns['toggle'](window)
            self.assertTrue(visible[0])
            self.assertEqual(fake.model.codex.next_poll_at, NOW + 900)
            self.assertIn('retry at', panel_helpers()['limit_retry_notice'](fake.model.codex))
            ns['toggle'](window)
        ns['threading'].Thread.assert_not_called()


if __name__ == '__main__':
    unittest.main()
