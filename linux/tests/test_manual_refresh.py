"""Independent Linux manual-refresh regressions from the accepted user scenario.

Fixtures use fixed clocks, in-memory settings/cache/credentials and queued workers.
No real threads, sleeps, sockets, subprocesses, credential stores, logs or APIs.
This file is prepared for reviewed offline CI; preparation is not runtime evidence.
"""
if __package__:
    from . import _isolate  # noqa: F401
else:
    import _isolate  # noqa: F401

import builtins
import copy
import io
import json
import socket
import subprocess
import unittest
import urllib.request
from datetime import datetime, timezone
from email.utils import format_datetime
from types import MethodType, SimpleNamespace
from unittest.mock import Mock, patch

from ccl import common, limits, polling, quota_refresh, sync, usage, vault

NOW = 1_800_000_000.0
PROVIDERS = ("claude", "codex")


def snapshot(at=NOW - 60, weekly=47, live=False):
    d = limits.LimitData()
    d.session, d.weekly = 31, weekly
    d.as_of = at
    if at is not None:
        d.session_reset, d.weekly_reset = at + 2.5 * 3600, at + 84 * 3600
    d.scoped = limits.Scoped("fixture-model", 25, NOW + 10000)
    d.plan, d.reset_credits = "fixture-plan", 2
    d.api_fresh = live
    return d


class MemoryStore:
    """Recording data store, no persistence or scheduling policy."""
    def __init__(self, data=None):
        self.data = copy.deepcopy(data or {})
        self.writes = []

    def get(self, name, default=None): return self.data.get(name, default)
    def set(self, name, value):
        self.data[name] = copy.deepcopy(value)
        self.writes.append((name, copy.deepcopy(value)))
    def update(self, **values):
        for name, value in values.items(): self.set(name, value)
    def remove(self, name): self.data.pop(name, None)


class SyntheticCase(unittest.TestCase):
    def setUp(self):
        self.now = NOW
        self.settings = MemoryStore(dict(common.SETTINGS_DEFAULTS, lang="en", monitor_claude=True,
                                         monitor_codex=True, autoPoll=True, interval=14400))
        self.state = MemoryStore()
        self.files = {}
        self.file_writes = []
        self.credential_path = "fixture:claude-credentials"
        self.auth_path = "fixture:codex-auth"
        self.cache_path = "fixture:quota-cache"
        def forbidden(*args, **kwargs):
            raise AssertionError("unmocked file/credentials/keyring/network/process/log effect")
        self.forbidden = forbidden
        for owner, names in ((vault, ("_ss", "_ss_v2", "read", "_file_get")),
                             (sync, ("sync_cycle", "transport", "auth_owner")),
                             (usage, ("refresh", "load_index")),
                             (limits, ("_rollout_files", "_read_json_retry", "_rewrite_json")),
                             (socket, ("create_connection",)), (subprocess, ("Popen", "run")),
                             (urllib.request, ("urlopen",)), (builtins, ("open",))):
            for name in names: self.patch(owner, name, forbidden)
        self.patch(common, "_settings", self.settings)
        self.patch(common, "_state", self.state)
        self.patch(common, "CLAUDE_CREDENTIALS", self.credential_path)
        self.patch(common, "CODEX_AUTH", self.auth_path)
        self.patch(common, "CODEX_SESSIONS", "fixture:codex-rollouts")
        self.patch(common, "CACHE_PATH", self.cache_path)
        self.patch(common, "HISTORY_PATH", "fixture:quota-history")
        self.patch(common, "read_json", self.read_json)
        self.patch(common, "write_json", self.write_json)
        self.patch(common, "write_atomic", forbidden)
        self.patch(common, "http", forbidden)
        self.patch(limits, "_PENDING", {})
        self.patch(limits.time, "time", lambda: self.now)
        self.patch(limits.time, "monotonic", lambda: self.now)
        self.patch(limits.time, "sleep", forbidden)

    def patch(self, owner, name, value):
        p = patch.object(owner, name, value)
        p.start(); self.addCleanup(p.stop)

    def read_json(self, path, default=None):
        self.assertIn(path, (self.auth_path, self.cache_path))
        return copy.deepcopy(self.files.get(path, default))

    def write_json(self, path, value):
        self.assertEqual(path, self.cache_path, "only synthetic quota cache writes allowed")
        self.file_writes.append((path, copy.deepcopy(value)))
        self.files[path] = copy.deepcopy(value)

    def response(self, status, headers=None, body=None):
        return SimpleNamespace(status=status, headers=headers or {},
                               json=lambda: copy.deepcopy(body), error="synthetic transport failure")

    def install_claude_credentials(self, expires=NOW + 3600):
        record = {"claudeAiOauth": {"accessToken": "fixture-access", "refreshToken": "fixture-refresh",
                                   "expiresAt": expires * 1000}}
        def open_memory(path, mode="r", *args, **kwargs):
            self.assertEqual(path, self.credential_path)
            self.assertEqual(mode, "rb")
            return io.BytesIO(json.dumps(record).encode("utf-8"))
        self.patch(builtins, "open", open_memory)
        self.patch(limits.os.path, "exists", lambda path: path == self.credential_path)

    def install_codex_credentials(self, expires=NOW + 3600):
        self.files[self.auth_path] = {"tokens": {"access_token": "fixture-access",
                                                "refresh_token": "fixture-refresh", "account_id": "fixture-account"}}
        self.patch(limits, "_jwt_exp", lambda token: expires)


class TestManualAdmission(SyntheticCase):
    def test_manual_bypasses_nine_hundred_floor_and_all_local_error_backoffs(self):
        for interval in (900, 1800, 3600, 14400):
            with self.subTest(interval=interval):
                state = quota_refresh.RefreshState(last_attempt=NOW - 60)
                schedule = NOW - 60 + interval
                self.assertEqual(state.admit("scheduled", NOW, schedule, monotonic_now=NOW).kind, "not_due")
                admitted = state.admit("manual", NOW, schedule, monotonic_now=NOW)
                self.assertEqual(admitted.kind, "start")
                self.assertIsNotNone(admitted.ticket)
        failed = polling.PollState({"interval": 14400, "failed": True, "last_attempt": NOW - 60})
        state = quota_refresh.RefreshState(last_attempt=failed.last_attempt)
        self.assertEqual(state.admit("manual", NOW, failed.last_attempt + failed.interval, monotonic_now=NOW).kind, "start")
        self.assertTrue(failed.failed, "admission is not proof the old failed attempt recovered")

    def test_thirty_second_guard_is_from_admission_and_inclusive_in_both_modes(self):
        for scheduled in (NOW + 900, NOW + 14400):
            state = quota_refresh.RefreshState()
            first = state.admit("manual", NOW, scheduled, monotonic_now=NOW)
            self.assertTrue(state.complete(first.ticket))
            for offset in (0, 1, 29, 29.999):
                denied = state.admit("manual", NOW + offset, scheduled, monotonic_now=NOW + offset)
                self.assertEqual((denied.kind, denied.until), ("local_wait", NOW + 30))
                self.assertIsNone(denied.ticket)
            self.assertEqual(state.admit("manual", NOW + 30, scheduled, monotonic_now=NOW + 30).kind, "start")

    def test_double_click_and_timer_overlap_never_create_a_second_physical_flight(self):
        state = quota_refresh.RefreshState()
        first = state.admit("manual", NOW, monotonic_now=NOW)
        for intent, offset in (("manual", 0), ("scheduled", 1), ("manual", 31), ("scheduled", 1000)):
            self.assertEqual(state.admit(intent, NOW + offset, monotonic_now=NOW + offset).kind, "in_flight")
            self.assertEqual(state.flight, first.ticket)
        self.assertTrue(state.complete(first.ticket))
        self.assertEqual(state.admit("scheduled", NOW + 29, NOW + 900, monotonic_now=NOW + 29).kind, "local_wait")
        self.assertEqual(state.admit("scheduled", NOW + 30, NOW + 900, monotonic_now=NOW + 30).kind, "not_due")
        self.assertEqual(state.admit("scheduled", NOW + 900, NOW + 900, monotonic_now=NOW + 900).kind, "start")

    def test_two_provider_completion_and_failed_only_retry_are_independent(self):
        claude, codex = quota_refresh.RefreshState(), quota_refresh.RefreshState()
        c = claude.admit("manual", NOW, monotonic_now=NOW).ticket
        x = codex.admit("manual", NOW, monotonic_now=NOW).ticket
        self.assertTrue(codex.complete(x))  # failure outcome may be retried locally after 30s
        self.assertEqual(claude.flight, c, "Codex completion retired Claude's flight")
        self.assertEqual(claude.admit("manual", NOW + 30, monotonic_now=NOW + 30).kind, "in_flight")
        retry = codex.admit("manual", NOW + 30, monotonic_now=NOW + 30)
        self.assertEqual(retry.kind, "start")
        self.assertTrue(claude.complete(c))
        self.assertEqual(codex.flight, retry.ticket)

    def test_disable_reenable_fences_result_but_retains_physical_reservation(self):
        state = quota_refresh.RefreshState()
        old = state.admit("manual", NOW, monotonic_now=NOW).ticket
        state.set_enabled(False)
        self.assertEqual(state.admit("manual", NOW + 100, monotonic_now=NOW + 100).kind, "disabled")
        state.set_enabled(True)
        self.assertEqual(state.admit("manual", NOW + 100, monotonic_now=NOW + 100).kind, "in_flight")
        self.assertFalse(state.complete(old), "an obsolete generation was allowed to publish")
        current = state.admit("manual", NOW + 100, monotonic_now=NOW + 100)
        self.assertEqual(current.kind, "start")
        self.assertNotEqual(old, current.ticket)
        self.assertFalse(state.complete(old), "duplicate old completion released the current reservation")
        self.assertEqual(state.flight, current.ticket)
        self.assertTrue(state.complete(current.ticket))

    def test_obsolete_completion_keeps_server_ban_across_reenable_and_duplicates(self):
        for completion_while_disabled in (False, True):
            state = quota_refresh.RefreshState()
            ticket = state.admit("manual", NOW, monotonic_now=NOW).ticket
            state.set_enabled(False)
            if not completion_while_disabled: state.set_enabled(True)
            self.assertFalse(state.complete(ticket, retry_at=NOW + 7200))
            if completion_while_disabled: state.set_enabled(True)
            self.assertFalse(state.complete(ticket, retry_at=None))
            denied = state.admit("manual", NOW + 60, monotonic_now=NOW + 60)
            self.assertEqual((denied.kind, denied.until), ("server_wait", NOW + 7200))
            self.assertEqual(state.admit("manual", NOW + 7200, monotonic_now=NOW + 7200).kind, "start")

    def test_foreign_and_duplicate_tickets_cannot_release_or_clear_server_restriction(self):
        state = quota_refresh.RefreshState(server_until=NOW + 90)
        self.assertFalse(state.complete(None))
        self.assertEqual(state.server_until, NOW + 90)
        active = state.admit("manual", NOW + 90, monotonic_now=NOW + 90)
        foreign = quota_refresh.Ticket(active.ticket.serial + 1, active.ticket.generation)
        self.assertFalse(state.complete(foreign, retry_at=NOW + 5000))
        self.assertEqual(state.flight, active.ticket)
        self.assertEqual(state.server_until, NOW + 90)
        self.assertTrue(state.complete(active.ticket, retry_at=NOW + 200))
        self.assertFalse(state.complete(active.ticket))
        self.assertEqual(state.server_until, NOW + 200)


class TestClockGuard(SyntheticCase):
    def test_wall_rollback_and_forward_jump_neither_extend_nor_bypass_thirty_real_seconds(self):
        for jump in (-3600, 3600):
            for elapsed in (0, 29, 29.999, 30, 31):
                with self.subTest(jump=jump, elapsed=elapsed):
                    state = quota_refresh.RefreshState()
                    first = state.admit("manual", NOW, monotonic_now=10000)
                    self.assertTrue(state.complete(first.ticket))
                    wall = NOW + jump + elapsed
                    state.update_clock(wall, 10000 + elapsed)
                    result = state.admit("manual", wall, monotonic_now=10000 + elapsed)
                    if elapsed < 30:
                        self.assertEqual(result.kind, "local_wait")
                        self.assertAlmostEqual(result.until - wall, 30 - elapsed)
                        self.assertIsNone(result.ticket)
                    else:
                        self.assertEqual(result.kind, "start")

    def test_reload_recent_old_and_future_attempt_uses_new_monotonic_epoch_with_bounded_guard(self):
        for last, remaining in ((0, 0), (NOW - 300, 0), (NOW - 10, 20), (NOW + 3600, 30)):
            with self.subTest(last=last):
                saved = json.loads(json.dumps({"last_attempt": last}))
                state = quota_refresh.RefreshState(saved["last_attempt"])
                state.update_clock(NOW, 700)
                self.assertEqual(state.local_until, NOW + remaining if remaining else 0)
                if remaining:
                    denied = state.admit("manual", NOW, monotonic_now=700)
                    self.assertEqual((denied.kind, denied.until), ("local_wait", NOW + remaining))
                    # A second wall correction cannot restore a fresh 30s wait.
                    denied = state.admit("manual", NOW - 3600, monotonic_now=700 + remaining - .001)
                    self.assertEqual(denied.kind, "local_wait")
                    self.assertAlmostEqual(denied.until - (NOW - 3600), .001, places=5)
                self.assertEqual(state.admit("manual", NOW - 3600,
                                            monotonic_now=700 + remaining).kind, "start")

    def test_local_clock_correction_and_reload_never_clamp_or_rebase_true_server_deadline(self):
        deadline = NOW + 7200
        for last in (NOW - 300, NOW - 10, NOW + 3600):
            for jump in (-3600, 3600):
                with self.subTest(last=last, jump=jump):
                    saved = json.loads(json.dumps({"last_attempt": last, "server_until": deadline}))
                    state = quota_refresh.RefreshState(saved["last_attempt"], saved["server_until"])
                    state.update_clock(NOW, 700)
                    wall = NOW + jump
                    denied = state.admit("manual", wall, monotonic_now=731)
                    self.assertEqual((denied.kind, denied.until), ("server_wait", deadline))
                    self.assertEqual(state.server_until, deadline)
                    self.assertEqual(state.next_attempt(wall + 14400, now=wall, monotonic_now=731), deadline)
                    self.assertEqual(state.admit("manual", deadline - 1, monotonic_now=732).kind, "server_wait")
                    self.assertEqual(state.admit("manual", deadline, monotonic_now=733).kind, "start")


class TestServerRetryAndAuth(SyntheticCase):
    def test_seconds_dates_past_dates_and_long_deadlines_are_truthful(self):
        future = format_datetime(datetime.fromtimestamp(NOW + 90, timezone.utc), usegmt=True)
        past = format_datetime(datetime.fromtimestamp(NOW - 90, timezone.utc), usegmt=True)
        for raw, expected in (("0", NOW), (" 90 ", NOW + 90), ("7200", NOW + 7200),
                              (future, NOW + 90), (past, NOW)):
            with self.subTest(raw=raw):
                deadline = quota_refresh.retry_after(raw, NOW)
                self.assertEqual(deadline, expected)
                state = quota_refresh.RefreshState()
                first = state.admit("manual", NOW, monotonic_now=NOW)
                self.assertTrue(state.complete(first.ticket, retry_at=deadline))
                denied = state.admit("manual", NOW + 30, monotonic_now=NOW + 30)
                self.assertEqual(denied.kind, "server_wait" if expected > NOW + 30 else "start")
                if denied.kind == "server_wait":
                    self.assertEqual(denied.until, expected)
                    self.assertEqual(state.admit("manual", expected, monotonic_now=expected).kind, "start")

    def test_unknown_malformed_fractional_negative_and_overflow_never_invent_deadline(self):
        for raw in (None, "", " ", 90, "-1", "+90", "1.5", "NaN", "inf", "tomorrow", "9" * 400):
            with self.subTest(raw=raw):
                self.assertIsNone(quota_refresh.retry_after(raw, NOW))
                failure = quota_refresh.http_failure(429, {"Retry-After": raw}, NOW)
                self.assertIsNone(failure.retry_at)
                self.assertFalse(failure.authentication_required)
                state = quota_refresh.RefreshState()
                ticket = state.admit("manual", NOW, monotonic_now=NOW).ticket
                self.assertTrue(state.complete(ticket, retry_at=failure.retry_at))
                self.assertIsNone(state.server_until)
                self.assertEqual(state.admit("manual", NOW + 30, NOW + 14400, monotonic_now=NOW + 30).kind, "start")

    def test_known_server_deadline_and_local_guard_have_distinct_bounds(self):
        state = quota_refresh.RefreshState()
        ticket = state.admit("manual", NOW, monotonic_now=NOW).ticket
        self.assertTrue(state.complete(ticket, retry_at=NOW + 10))
        self.assertEqual(state.admit("manual", NOW + 9, monotonic_now=NOW + 9).kind, "server_wait")
        self.assertEqual(state.admit("manual", NOW + 10, monotonic_now=NOW + 10).kind, "local_wait")
        self.assertEqual(state.next_attempt(NOW + 14400, now=NOW + 10, monotonic_now=NOW + 10), NOW + 30)
        self.assertEqual(state.admit("scheduled", NOW + 30, NOW + 14400, monotonic_now=NOW + 30).kind, "start")

    def test_only_confirmed_auth_evidence_requires_recovery_and_does_not_erase_retry(self):
        cases = ((401, False, None, True), (400, True, "invalid_grant", True),
                 (400, False, "invalid_grant", False), (403, False, None, False),
                 (429, False, None, False), (503, False, None, False), (0, False, None, False),
                 (400, True, "server_error", False), (400, True, None, False))
        for status, token, error, recovery in cases:
            with self.subTest(status=status, token=token, error=error):
                failure = quota_refresh.http_failure(status, {"rEtRy-AfTeR": "90"}, NOW,
                                                     token_endpoint=token, oauth_error=error)
                self.assertEqual(failure.authentication_required, recovery)
                self.assertEqual(failure.retry_at, NOW + 90)
                self.assertEqual(failure.status, status)


class TestSnapshotsAndCache(SyntheticCase):
    def test_unchanged_successful_live_reading_advances_data_time_not_percentages(self):
        previous = snapshot(at=NOW - 7200)
        previous.error, previous.auth = "old failure", limits.EXPIRED
        live = snapshot(at=NOW, live=True)
        live.session_reset, live.weekly_reset = previous.session_reset, previous.weekly_reset
        before = copy.deepcopy(vars(previous))
        result = quota_refresh.select_snapshot(live, previous)
        self.assertIs(result, live)
        self.assertEqual((result.session, result.weekly, result.as_of), (31, 47, NOW))
        self.assertTrue(result.api_fresh)
        self.assertFalse(result.from_cache)
        self.assertIsNone(result.error)
        self.assertEqual(result.auth, limits.OK)
        self.assertEqual(previous.as_of, before["as_of"])
        self.assertEqual(previous.error, before["error"])

    def test_failed_fallback_preserves_old_or_unknown_asof_and_current_attempt_metadata(self):
        for at in (NOW - 7200, None):
            for auth in (limits.OK, limits.EXPIRED, limits.LOGGED_OUT, limits.READ_ERROR):
                with self.subTest(at=at, auth=auth):
                    previous = snapshot(at=at)
                    previous.error, previous.server_retry_at = "old error", NOW + 99999
                    failure = limits.LimitData()
                    failure.auth, failure.error = auth, "HTTP 429"
                    failure.http_status, failure.server_retry_at = 429, NOW + 90
                    failure.poll_failed, failure.failure_kind = True, "http"
                    merged = quota_refresh.select_snapshot(failure, previous)
                    self.assertEqual((merged.session, merged.weekly, merged.as_of), (31, 47, at))
                    self.assertEqual((merged.session_reset, merged.weekly_reset),
                                     (previous.session_reset, previous.weekly_reset))
                    self.assertEqual((merged.scoped.name, merged.scoped.percent, merged.plan, merged.reset_credits),
                                     ("fixture-model", 25, "fixture-plan", 2))
                    self.assertEqual((merged.auth, merged.error, merged.http_status, merged.server_retry_at),
                                     (auth, "HTTP 429", 429, NOW + 90))
                    self.assertTrue(merged.poll_failed)
                    self.assertTrue(merged.from_cache)
                    self.assertFalse(merged.api_fresh)
                    self.assertEqual(previous.error, "old error")
                    self.assertIsNone(failure.weekly)
                    self.assertIsNone(failure.as_of)

    def test_fallback_prefers_newer_known_snapshot_without_fabricating_missing_time(self):
        for result_at, previous_at, expected in ((NOW - 10, NOW - 20, NOW - 10),
                                                  (NOW - 20, NOW - 10, NOW - 10),
                                                  (None, NOW - 20, NOW - 20),
                                                  (NOW - 20, None, NOW - 20), (None, None, None)):
            attempt, previous = snapshot(result_at), snapshot(previous_at)
            attempt.error, attempt.server_retry_at = "network unavailable", NOW + 90
            selected = quota_refresh.select_snapshot(attempt, previous)
            self.assertEqual(selected.as_of, expected)
            self.assertEqual(selected.error, "network unavailable")
            self.assertEqual(selected.server_retry_at, NOW + 90)
            self.assertFalse(selected.api_fresh)

    def test_failed_or_auth_fallback_never_rewrites_cache_or_serializes_attempt_metadata(self):
        cache = {"claude": snapshot(NOW - 600).to_dict(), "codex": snapshot(NOW - 1200).to_dict()}
        for auth in (limits.OK, limits.EXPIRED, limits.READ_ERROR):
            for disk in (cache, {}, [], None):
                self.files[self.cache_path] = copy.deepcopy(disk)
                attempt = limits.LimitData()
                attempt.error, attempt.auth = "HTTP 429", auth
                attempt.server_retry_at, attempt.http_status = NOW + 90, 429
                attempt.poll_failed, attempt.failure_kind = True, "http"
                merged = limits.apply_provider_cache("codex", attempt, snapshot(NOW - 7200))
                self.assertEqual(merged.auth, auth)
                self.assertEqual(merged.error, "HTTP 429")
                self.assertEqual(merged.server_retry_at, NOW + 90)
                self.assertEqual(merged.http_status, 429)
                self.assertTrue(merged.poll_failed)
                self.assertFalse(merged.api_fresh)
                self.assertTrue(merged.from_cache)
                self.assertEqual(self.files[self.cache_path], disk)
                self.assertEqual(self.file_writes, [])
                serialized = merged.to_dict()
                self.assertEqual(serialized["asOf"], NOW - 1200 if disk == cache else NOW - 7200)
                for field in ("error", "auth", "http_status", "server_retry_at", "failure_kind",
                              "poll_failed", "next_poll_at", "api_fresh", "refresh_in_flight", "local_retry_at"):
                    self.assertNotIn(field, serialized)

    def test_independent_cache_writes_preserve_the_other_provider(self):
        for order in (("claude", "codex"), ("codex", "claude")):
            self.files[self.cache_path] = {"claude": snapshot(NOW - 7200, 10).to_dict(),
                                           "codex": snapshot(NOW - 7200, 20).to_dict()}
            for product, percent in zip(order, (61, 72)):
                result = snapshot(NOW, percent, live=True)
                before = copy.deepcopy(self.files[self.cache_path])
                merged = limits.apply_provider_cache(product, result)
                other = "codex" if product == "claude" else "claude"
                self.assertEqual(self.files[self.cache_path][other], before[other])
                self.assertEqual(self.files[self.cache_path][product]["weekly"], percent)
                self.assertTrue(merged.api_fresh)


class TestSyntheticProviderResponses(SyntheticCase):
    def test_usage_http_errors_preserve_retry_auth_failure_and_unknown_time(self):
        for product in PROVIDERS:
            for status, auth in ((401, limits.EXPIRED), (403, limits.OK), (429, limits.OK),
                                  (503, limits.OK), (0, limits.OK)):
                for header, expected in (("90", NOW + 90), ("bad delay", None), (None, None)):
                    with self.subTest(product=product, status=status, header=header):
                        response = self.response(status, {"Retry-After": header}, {"error": "fixture-sensitive-body"})
                        with patch.object(common, "http", return_value=response) as http:
                            if product == "claude":
                                self.install_claude_credentials()
                                result = limits.fetch_claude()
                            else:
                                with patch.object(limits, "codex_access_token", lambda result=None: ("fixture-access", "fixture-account")):
                                    result = limits.codex_usage_live()
                        http.assert_called_once()
                        self.assertEqual((result.http_status, result.auth, result.server_retry_at), (status, auth, expected))
                        self.assertTrue(result.poll_failed)
                        self.assertFalse(result.api_fresh)
                        self.assertIsNone(result.as_of)
                        self.assertNotIn("fixture-sensitive-body", result.error)
                        self.assertNotIn("fixture-access", result.error)

    def test_token_refresh_rejection_vs_timeout_does_not_invent_expired_login(self):
        for product in PROVIDERS:
            for status, body, auth in ((401, {}, limits.EXPIRED),
                                       (400, {"error": "invalid_grant"}, limits.EXPIRED),
                                       (400, {"error": "server_error"}, limits.OK),
                                       (429, {}, limits.OK), (503, {}, limits.OK), (0, {}, limits.OK)):
                with self.subTest(product=product, status=status, body=body):
                    self.state.data.clear()
                    response = self.response(status, {"Retry-After": "90"}, body)
                    if product == "claude":
                        self.install_claude_credentials(expires=NOW - 1)
                    else:
                        self.install_codex_credentials(expires=NOW - 1)
                    with patch.object(common, "http", return_value=response) as http:
                        if product == "claude": result = limits.fetch_claude()
                        else:
                            result = limits.LimitData()
                            self.assertIsNone(limits.codex_access_token(result))
                    http.assert_called_once()
                    self.assertEqual(result.auth, auth)
                    self.assertEqual(result.server_retry_at, NOW + 90)
                    self.assertEqual(result.http_status, status)
                    self.assertTrue(result.poll_failed)
                    self.assertFalse(result.api_fresh)
                    self.assertIsNone(result.as_of)
                    dead = "deadRefresh" if product == "claude" else "deadCodexRefresh"
                    self.assertEqual(self.state.get(dead) is not None, auth == limits.EXPIRED)

    def test_codex_failed_live_uses_rollout_or_cache_without_losing_attempt_metadata(self):
        self.patch(limits.os.path, "isdir", lambda path: path == common.CODEX_SESSIONS)
        self.patch(limits.os.path, "exists", lambda path: path == self.auth_path)
        for auth in (limits.OK, limits.EXPIRED, limits.READ_ERROR):
            for cache in ({}, {"codex": snapshot(NOW - 900, 60).to_dict()}):
                self.files[self.cache_path] = copy.deepcopy(cache)
                attempt = limits.LimitData()
                attempt.auth, attempt.error = auth, "HTTP 429"
                attempt.http_status, attempt.server_retry_at = 429, NOW + 90
                attempt.failure_kind = "http"
                with patch.object(limits, "codex_usage_live", return_value=attempt), \
                     patch.object(limits, "codex_from_rollout", return_value=snapshot(NOW - 7200, 47)):
                    result = limits.fetch_codex(live=True)
                self.assertEqual(result.as_of, NOW - 900 if cache else NOW - 7200)
                self.assertEqual(result.weekly, 60 if cache else 47)
                self.assertEqual(result.auth, auth)
                self.assertEqual(result.error, "HTTP 429")
                self.assertEqual(result.http_status, 429)
                self.assertEqual(result.server_retry_at, NOW + 90)
                self.assertTrue(result.poll_failed)
                self.assertFalse(result.api_fresh)
                self.assertTrue(result.from_cache)
                self.assertEqual(self.files[self.cache_path], cache)
                self.assertEqual(self.file_writes, [])

    def test_unchanged_live_codex_response_is_fresh_success_with_new_asof(self):
        body = {"rate_limit": {"primary_window": {"used_percent": 31, "limit_window_seconds": 18000,
                                                      "reset_at": NOW + 7200},
                                "secondary_window": {"used_percent": 47, "limit_window_seconds": 604800,
                                                       "reset_at": NOW + 86400}}}
        with patch.object(common, "http", return_value=self.response(200, body=body)), \
             patch.object(limits, "codex_access_token", lambda result=None: ("fixture-access", "fixture-account")):
            result = limits.codex_usage_live()
        self.assertEqual((result.session, result.weekly, result.as_of), (31, 47, NOW))
        self.assertTrue(result.api_fresh)
        self.assertFalse(result.poll_failed)
        self.assertIsNone(result.error)
        self.assertEqual(result.auth, limits.OK)


class TestCredentialWriteback(SyntheticCase):
    def original(self, product):
        if product == "claude":
            return {"claudeAiOauth": {"accessToken": "fixture-old-access", "refreshToken": "fixture-old-refresh",
                                       "expiresAt": (NOW - 1) * 1000, "cliMetadata": "old"}, "unrelated": {"old": True}}
        return {"tokens": {"access_token": "fixture-old-access", "refresh_token": "fixture-old-refresh",
                            "account_id": "fixture-account", "cliMetadata": "old"}, "unrelated": {"old": True}}

    def writeback(self, product, first, current, rotated, writer):
        path = self.credential_path if product == "claude" else self.auth_path
        with patch.object(limits, "_read_json_retry", return_value=copy.deepcopy(current)) as reader, \
             patch.object(limits, "_rewrite_json", writer):
            if product == "claude":
                outcome = limits._save_claude_tokens(path, "fixture-old-refresh", rotated, NOW, copy.deepcopy(first))
            else:
                outcome = limits._save_codex_tokens("fixture-old-refresh", rotated, copy.deepcopy(first))
        reader.assert_called_once_with(path)
        return outcome

    def test_missing_read_error_or_corrupt_current_never_resurrects_old_file_and_keeps_rotation(self):
        rotated = {"access_token": "fixture-new-access", "refresh_token": "fixture-new-refresh", "expires_in": 3600}
        for product in PROVIDERS:
            # _read_json_retry maps missing, read errors and malformed JSON to None.
            key = "claudeAiOauth" if product == "claude" else "tokens"
            for reason, current in (("missing", None), ("read error", None), ("invalid JSON", None),
                                    ("wrong shape", []), ("corrupt credential object", {}),
                                    ("corrupt nested credential", {key: []}),
                                    ("empty credential block", {key: {}})):
                with self.subTest(product=product, reason=reason):
                    limits._PENDING.clear()
                    writer = Mock()
                    self.assertEqual(self.writeback(product, self.original(product), current, rotated, writer), "pending")
                    writer.assert_not_called()
                    self.assertIn(product, limits._PENDING, "server-rotated credential pair was lost")
                    self.assertEqual(limits._PENDING[product]["tok"]["access_token"], "fixture-new-access")
                    self.assertEqual(limits._PENDING[product]["tok"]["refresh_token"], "fixture-new-refresh")

    def test_changed_cli_access_or_refresh_pair_wins_without_any_overwrite(self):
        rotated = {"access_token": "fixture-new-access", "refresh_token": "fixture-new-refresh", "expires_in": 3600}
        for product in PROVIDERS:
            for component in (("access", "refresh", "account") if product == "codex" else ("access", "refresh")):
                with self.subTest(product=product, component=component):
                    first = self.original(product); current = copy.deepcopy(first)
                    key = "claudeAiOauth" if product == "claude" else "tokens"
                    field = (("accessToken" if component == "access" else "refreshToken") if product == "claude" else
                             "account_id" if component == "account" else component + "_token")
                    current[key][field] = "fixture-cli-distinct-" + component
                    before = copy.deepcopy(current)
                    limits._PENDING[product] = {"old": "fixture-old-refresh", "tok": rotated, "t": NOW}
                    writer = Mock()
                    self.assertEqual(self.writeback(product, first, current, rotated, writer), "superseded")
                    writer.assert_not_called()
                    self.assertEqual(current, before)
                    self.assertNotIn(product, limits._PENDING, "stale rotation still competes with the distinct CLI login")

    def test_same_pair_preserves_reread_metadata_and_keeps_pending_when_write_fails(self):
        rotated = {"access_token": "fixture-new-access", "refresh_token": "fixture-new-refresh", "expires_in": 3600}
        for product in PROVIDERS:
            for fail_write in (False, True):
                with self.subTest(product=product, write_failure=fail_write):
                    limits._PENDING.clear()
                    first = self.original(product); current = copy.deepcopy(first)
                    key = "claudeAiOauth" if product == "claude" else "tokens"
                    current[key]["cliMetadata"] = "latest"
                    current["unrelated"] = {"current": True}
                    written = []
                    def write(path, obj):
                        written.append((path, copy.deepcopy(obj)))
                        if fail_write: raise OSError("synthetic readonly fixture")
                    writer = Mock(side_effect=write)
                    self.assertEqual(self.writeback(product, first, current, rotated, writer), "pending" if fail_write else "saved")
                    writer.assert_called_once()
                    path, obj = written[0]
                    self.assertEqual(path, self.credential_path if product == "claude" else self.auth_path)
                    self.assertEqual(obj[key]["cliMetadata"], "latest")
                    self.assertEqual(obj["unrelated"], {"current": True})
                    self.assertEqual(obj[key]["accessToken" if product == "claude" else "access_token"], "fixture-new-access")
                    self.assertEqual(obj[key]["refreshToken" if product == "claude" else "refresh_token"], "fixture-new-refresh")
                    self.assertEqual(product in limits._PENDING, fail_write)

    def test_pending_retry_keeps_original_identity_despite_new_initial_read(self):
        rotated = {"access_token": "fixture-new-access", "refresh_token": "fixture-new-refresh", "expires_in": 3600}
        for product in PROVIDERS:
            for changed_current in (False, True):
                with self.subTest(product=product, changed_current=changed_current):
                    limits._PENDING.clear()
                    original = self.original(product)
                    writer = Mock()
                    self.assertEqual(self.writeback(product, original, None, rotated, writer), "pending")
                    writer.assert_not_called()
                    key = "claudeAiOauth" if product == "claude" else "tokens"
                    field = "accessToken" if product == "claude" else "access_token"
                    retry_first = copy.deepcopy(original)
                    retry_first[key][field] = "fixture-different-initial-access"
                    current = copy.deepcopy(retry_first if changed_current else original)
                    current[key]["cliMetadata"] = "latest"
                    expected = "superseded" if changed_current else "saved"
                    self.assertEqual(self.writeback(product, retry_first, current, rotated, writer), expected)
                    self.assertNotIn(product, limits._PENDING)
                    if changed_current:
                        writer.assert_not_called()
                    else:
                        writer.assert_called_once()
                        written = writer.call_args[0][1]
                        self.assertEqual(written[key][field], "fixture-new-access")
                        self.assertEqual(written[key]["cliMetadata"], "latest")

    def test_rotation_callers_stop_before_usage_on_pending_or_superseded_pair(self):
        rotated = {"access_token": "fixture-new-access", "refresh_token": "fixture-new-refresh", "expires_in": 3600}
        for product in PROVIDERS:
            for existing_pending in (False, True):
                for outcome, auth in (("pending", limits.READ_ERROR), ("superseded", limits.OK)):
                    with self.subTest(product=product, existing_pending=existing_pending, outcome=outcome):
                        limits._PENDING.clear()
                        if product == "claude":
                            self.install_claude_credentials(expires=NOW - 1)
                            save_name = "_save_claude_tokens"
                        else:
                            self.install_codex_credentials(expires=NOW - 1)
                            save_name = "_save_codex_tokens"
                        if existing_pending:
                            limits._PENDING[product] = {"old": "fixture-refresh", "tok": rotated, "t": NOW}
                        with patch.object(limits, save_name, return_value=outcome) as save, \
                             patch.object(common, "http", return_value=self.response(200, body=rotated)) as http:
                            result = limits.fetch_claude() if product == "claude" else limits.codex_usage_live()
                        save.assert_called_once()
                        if existing_pending:
                            http.assert_not_called()
                        else:
                            http.assert_called_once()
                            self.assertEqual(http.call_args[0][1], "POST")
                            self.assertTrue(http.call_args[0][0].endswith("/oauth/token"))
                        self.assertEqual(result.auth, auth)
                        self.assertEqual(result.failure_kind, "credentials")
                        self.assertTrue(result.poll_failed)
                        self.assertFalse(result.api_fresh)
                        self.assertIsNone(result.as_of)
                        self.assertIsNone(result.server_retry_at)
                        self.assertNotIn("fixture-new-access", result.error)
                        self.assertNotIn("fixture-new-refresh", result.error)


try:
    from ccl.gui import app, panel
    HAVE_QT = True
except ImportError:
    HAVE_QT = False


class RecordingTimer:
    def __init__(self): self.milliseconds = -1
    def setSingleShot(self, value): self.single = value
    def setTimerType(self, value): pass
    def start(self, milliseconds): self.milliseconds = milliseconds
    def remainingTime(self): return self.milliseconds


@unittest.skipUnless(HAVE_QT, "PyQt5 absent: actual app methods unverified")
class TestSyntheticApp(SyntheticCase):
    def setUp(self):
        super().setUp()
        self.jobs, self.deliveries = [], []
        self.in_worker = False
        self.cache_calls = []
        model = panel.Model()
        model.claude, model.codex = snapshot(), snapshot()
        model.loaded, model.interval = True, 14400
        model.history.record = Mock()
        self.owner = SimpleNamespace(model=model, poll_states={}, refresh_states={}, busy_limits=False,
                                     selection_generation=0, sound_baselines={p: False for p in PROVIDERS}, activity_busy=False,
                                     timer=RecordingTimer(), load_local=Mock(), scan_activity=Mock(),
                                     refresh_logs=Mock(), update_sync_warning=Mock(), check_alarms=Mock(), update_tray=Mock(),
                                     win=SimpleNamespace(view=SimpleNamespace(update=Mock()), page0_changed=Mock(),
                                                         fix=SimpleNamespace(build_access=Mock(), build=Mock()),
                                                         show_page=Mock(), isVisible=lambda: False),
                                     bridge=SimpleNamespace(limits_done=SimpleNamespace(emit=self.emitted)))
        for product in PROVIDERS:
            self.owner.poll_states[product] = polling.PollState({"interval": 14400, "last_attempt": NOW - 60})
            self.owner.refresh_states[product] = quota_refresh.RefreshState(last_attempt=NOW - 60)
        for name in ("scheduled_at", "start_poll_timer", "publish_auto_intervals", "save_poll_states",
                     "refresh_limits", "on_limits", "set_product_enabled", "action", "auto_summary"):
            setattr(self.owner, name, MethodType(getattr(app.TrayApp, name), self.owner))
        self.fetches = {p: Mock(return_value=snapshot(NOW, live=True)) for p in PROVIDERS}
        self.patch(limits, "fetch_claude", self.fetches["claude"])
        self.patch(limits, "fetch_codex", self.fetches["codex"])
        self.patch(app.threading, "Thread", self.queue_worker)
        self.patch(app.QDesktopServices, "openUrl", self.forbidden)
        self.patch(limits, "apply_cache", self.forbidden)  # no combined cache publication by workers
        actual_cache = limits.apply_provider_cache
        def cache(product, data, previous=None):
            self.assertFalse(self.in_worker, "cache publication escaped to a worker")
            self.assertIsNone(self.owner.refresh_states[product].flight, "cache write happened before ticket retirement")
            self.cache_calls.append(product)
            return actual_cache(product, data, previous)
        self.patch(limits, "apply_provider_cache", cache)
        self.owner.publish_auto_intervals()

    def queue_worker(self, target, **kwargs):
        # start merely reserves a callback; no Python/native thread is created.
        return SimpleNamespace(start=lambda: self.jobs.append(target))

    def emitted(self, *args):
        self.assertTrue(self.in_worker)
        self.deliveries.append(args)

    def run_worker(self, index):
        self.in_worker = True
        try: self.jobs[index]()
        finally: self.in_worker = False
        return self.deliveries[-1]

    def finish(self, index):
        delivery = self.run_worker(index)
        self.owner.on_limits(*delivery)
        return delivery

    def install_alarm_sink(self):
        # Real app alarm routing with recording sinks; no tray notifications/audio.
        self.settings.update(notify=True, sound5h=True, sound7d=True, reachedOn=True,
                             sound5hChoice="fixture-session", sound7dChoice="fixture-week",
                             reachedChoice="fixture-reached")
        self.owner.check_alarms = MethodType(app.TrayApp.check_alarms, self.owner)
        self.owner.notify = Mock()
        self.sounds = Mock()
        self.patch(app, "play_sound", self.sounds)
        claude, codex = snapshot(), snapshot()
        claude.scoped = codex.scoped = None
        claude.session_reset, codex.session_reset = NOW + 7200, NOW - 3600
        claude.weekly_reset = codex.weekly_reset = NOW + 86400
        codex.session = 95
        self.owner.model.claude, self.owner.model.codex = claude, codex
        self.state.update(rst_c5=claude.session_reset, use_c5=claude.session, rch_c5=False,
                          rst_x5=codex.session_reset, use_x5=codex.session, rch_x5=False,
                          rst_c7=claude.weekly_reset, use_c7=claude.weekly, rch_c7=False,
                          rst_x7=codex.weekly_reset, use_x7=codex.weekly, rch_x7=False)
        live_claude, live_codex = copy.deepcopy(claude), copy.deepcopy(codex)
        for data in (live_claude, live_codex):
            data.api_fresh, data.as_of = True, NOW
        live_codex.session, live_codex.session_reset = 2, NOW + 18000
        self.fetches["claude"].return_value = live_claude
        self.fetches["codex"].return_value = live_codex

    def assert_no_alarm(self):
        self.sounds.assert_not_called()
        self.owner.notify.assert_not_called()

    def startup_alarm_roundtrip(self, order):
        self.install_alarm_sink()
        self.owner.refresh_limits()
        self.finish(order[0])
        self.assert_no_alarm()
        self.finish(order[1])
        self.assert_no_alarm()  # Codex reset while the app was closed is a baseline.
        self.assertEqual(self.state.get("rst_x5"), NOW + 18000)
        self.now += 30
        later = copy.deepcopy(self.fetches["codex"].return_value)
        later.as_of, later.session, later.session_reset = self.now, 1, NOW + 36000
        self.fetches["codex"].return_value = later
        self.owner.refresh_limits(product="codex")
        delivery = self.finish(2)
        self.sounds.assert_called_once_with("fixture-session")
        self.owner.notify.assert_called_once()
        event = self.owner.notify.call_args[0][0]
        self.assertEqual((event["kind"], event["product"], event["is5h"]), ("reset", "Codex", True))
        self.owner.on_limits(*delivery)  # Same completion must not replay the event.
        self.now += 30
        later.as_of = self.now
        self.owner.refresh_limits(product="codex")
        self.finish(3)
        self.sounds.assert_called_once()
        self.owner.notify.assert_called_once()

    def test_claude_first_codex_second_startup_does_not_sound_for_offline_reset(self):
        self.startup_alarm_roundtrip((0, 1))

    def test_codex_first_claude_second_startup_does_not_sound_for_offline_reset(self):
        self.startup_alarm_roundtrip((1, 0))

    def test_single_provider_completion_cannot_baseline_or_emit_for_disabled_other(self):
        self.install_alarm_sink()
        # Even an old reached reading for a disabled provider must not emit/baseline.
        self.owner.model.codex.session = 100
        self.settings.set("monitor_codex", False)
        self.owner.refresh_states["codex"].set_enabled(False)
        self.owner.refresh_limits()
        self.assertEqual(len(self.jobs), 1)
        self.finish(0)
        self.assert_no_alarm()
        self.assertEqual(self.state.get("rst_x5"), NOW - 3600)
        self.assertEqual(self.state.get("use_x5"), 95)
        self.assertFalse(self.state.get("rch_x5"))
        self.owner.set_product_enabled("codex", True)
        self.owner.refresh_limits(product="codex")
        self.assertEqual(len(self.jobs), 2)
        self.finish(1)
        self.assert_no_alarm()  # Enabling does not consume another provider's baseline.
        self.assertEqual(self.state.get("rst_x5"), NOW + 18000)
        self.now += 30
        later = copy.deepcopy(self.fetches["claude"].return_value)
        later.as_of, later.session, later.session_reset = self.now, 2, NOW + 25200
        self.fetches["claude"].return_value = later
        self.owner.refresh_limits(product="claude")
        self.finish(2)
        self.sounds.assert_called_once_with("fixture-session")
        self.owner.notify.assert_called_once()
        event = self.owner.notify.call_args[0][0]
        self.assertEqual((event["kind"], event["product"]), ("reset", "Claude Code"))

    def test_failed_fallback_cannot_consume_first_live_alarm_baseline(self):
        self.install_alarm_sink()
        before = {k: v for k, v in self.state.data.items() if k.startswith(("rst_", "use_", "rch_"))}
        live = self.fetches["codex"].return_value
        failure = limits.LimitData()
        failure.error, failure.failure_kind, failure.poll_failed = "network unavailable", "network", True
        self.fetches["codex"].return_value = failure
        self.owner.refresh_limits(product="codex")
        self.finish(0)
        self.assertTrue(self.owner.model.codex.from_cache)
        self.assertFalse(self.owner.sound_baselines["codex"])
        self.assertEqual({k: v for k, v in self.state.data.items() if k.startswith(("rst_", "use_", "rch_"))}, before)
        self.assert_no_alarm()
        self.now += 30
        live.as_of = self.now
        self.fetches["codex"].return_value = live
        self.owner.refresh_limits(product="codex")
        self.finish(1)
        self.assertTrue(self.owner.sound_baselines["codex"])
        self.assertFalse(self.owner.sound_baselines["claude"])
        self.assert_no_alarm()

    def test_manual_before_floor_and_error_backoff_keeps_mode_and_no_timer_duplicate(self):
        for auto in (True, False):
            self.settings.update(autoPoll=auto, interval=14400)
            self.jobs.clear(); self.deliveries.clear()
            self.owner.poll_states = {p: polling.PollState({"failed": True, "interval": 14400,
                                                            "last_attempt": self.now - 60}) for p in PROVIDERS}
            self.owner.refresh_states = {p: quota_refresh.RefreshState(self.now - 60) for p in PROVIDERS}
            self.owner.refresh_limits()
            self.assertEqual(len(self.jobs), 2, "manual request was denied by the old 900s/error schedule")
            self.assertEqual(self.owner.model.pending_products, set(PROVIDERS))
            self.owner.refresh_limits(); self.owner.refresh_limits(scheduled=True)
            self.assertEqual(len(self.jobs), 2)
            self.finish(0); self.finish(1)
            self.owner.refresh_limits(scheduled=True)
            self.assertEqual(len(self.jobs), 2)
            self.assertEqual(self.settings.get("autoPoll"), auto)
            self.assertEqual(self.settings.get("interval"), 14400)
            self.assertEqual(self.owner.model.interval, 14400)
            self.assertGreater(self.owner.scheduled_at("codex"), self.now)
            self.now += 60

    def test_future_saved_poll_anchor_normalizes_without_bypassing_true_retry_after(self):
        self.elapsed = 10000
        self.patch(app.time, "monotonic", lambda: self.elapsed)
        for auto in (False, True):
            with self.subTest(auto=auto):
                self.now, self.elapsed = NOW, 10000
                self.settings.set("autoPoll", auto)
                self.jobs.clear(); self.deliveries.clear()
                saved = json.loads(json.dumps({"last_attempt": NOW + 3600, "interval": 14400,
                                               "server_until": NOW + 7200}))
                self.owner.poll_states["codex"] = polling.PollState(saved)
                self.owner.refresh_states["codex"] = quota_refresh.RefreshState(saved["last_attempt"], saved["server_until"])
                self.owner.publish_auto_intervals()
                self.assertEqual(self.owner.poll_states["codex"].last_attempt, NOW)
                self.assertEqual(self.owner.scheduled_at("codex"), NOW + 14400)
                self.assertEqual(self.owner.model.codex.local_retry_at, NOW + 30)
                self.assertEqual(self.owner.model.codex.server_retry_at, NOW + 7200)
                self.owner.refresh_limits(product="codex")
                self.assertEqual(self.jobs, [])
                self.now, self.elapsed = NOW - 3600, 10031
                self.owner.publish_auto_intervals()
                self.assertEqual(self.owner.poll_states["codex"].last_attempt, self.now)
                self.assertEqual(self.owner.model.codex.local_retry_at, 0)
                self.assertEqual(self.owner.model.codex.next_poll_at, NOW + 7200)
                self.owner.refresh_limits(product="codex")
                self.assertEqual(self.jobs, [])
                self.now = NOW + 7200 - 1
                self.owner.refresh_limits(scheduled=True, product="codex")
                self.assertEqual(self.jobs, [])
                self.now += 1
                self.owner.refresh_limits(scheduled=True, product="codex")
                self.assertEqual(len(self.jobs), 1)
                self.assertEqual(self.owner.refresh_states["codex"].server_until, NOW + 7200)

    def test_rollback_during_worker_accepts_new_live_answer_and_keeps_real_guard(self):
        self.elapsed = 10000
        self.patch(app.time, "monotonic", lambda: self.elapsed)
        self.owner.refresh_limits(product="codex")
        self.now, self.elapsed = NOW - 3600, 10001
        self.fetches["codex"].return_value = snapshot(self.now, 48, live=True)
        self.finish(0)
        self.assertEqual(self.owner.poll_states["codex"].last_attempt, self.now)
        self.assertFalse(self.owner.poll_states["codex"].failed)
        self.assertTrue(self.owner.model.codex.api_fresh)
        self.assertFalse(self.owner.model.codex.poll_failed)
        self.assertEqual(self.owner.model.codex.as_of, self.now)
        self.assertEqual(self.owner.model.codex.local_retry_at, self.now + 29)
        self.now, self.elapsed = NOW - 3600 + 28, 10029
        self.owner.refresh_limits(product="codex")
        self.assertEqual(len(self.jobs), 1)
        self.now, self.elapsed = NOW - 3600 + 29, 10030
        self.owner.refresh_limits(product="codex")
        self.assertEqual(len(self.jobs), 2)

    def test_each_provider_publishes_immediately_in_either_completion_order(self):
        for order in ((0, 1), (1, 0)):
            self.jobs.clear(); self.deliveries.clear()
            self.owner.refresh_states = {p: quota_refresh.RefreshState() for p in PROVIDERS}
            self.fetches["claude"].return_value = snapshot(NOW, 61, live=True)
            self.fetches["codex"].return_value = snapshot(NOW, 72, live=True)
            self.owner.refresh_limits()
            first = PROVIDERS[order[0]]; second = PROVIDERS[order[1]]
            prior_second = getattr(self.owner.model, second)
            self.finish(order[0])
            self.assertEqual(getattr(self.owner.model, first).weekly, 61 if first == "claude" else 72)
            self.assertIs(getattr(self.owner.model, second), prior_second)
            self.assertEqual(self.owner.model.pending_products, {second})
            self.assertEqual(self.owner.model.history.record.call_args[0][1], first)
            self.finish(order[1])
            self.assertEqual((self.owner.model.claude.weekly, self.owner.model.codex.weekly), (61, 72))
            self.assertEqual(self.owner.model.pending_products, set())
            self.assertEqual((self.files[self.cache_path]["claude"]["weekly"],
                              self.files[self.cache_path]["codex"]["weekly"]), (61, 72))

    def test_failed_only_card_retry_can_start_while_other_provider_is_still_pending(self):
        failure = limits.LimitData()
        failure.error, failure.poll_failed, failure.failure_kind = "network unavailable", True, "network"
        self.fetches["codex"].return_value = failure
        self.owner.refresh_limits()
        self.finish(1)
        self.assertEqual(self.owner.model.codex.as_of, NOW - 60)
        self.assertFalse(self.owner.model.codex.api_fresh)
        claude_ticket = self.owner.refresh_states["claude"].flight
        self.owner.action("feedbackretry:codex")
        self.assertEqual(len(self.jobs), 2, "30s local guard was bypassed")
        self.now = NOW + 30
        self.fetches["codex"].return_value = snapshot(self.now, 49, live=True)
        self.owner.action("feedbackretry:codex")
        self.assertEqual(len(self.jobs), 3)
        self.assertEqual(self.owner.refresh_states["claude"].flight, claude_ticket)
        self.finish(2)
        self.assertEqual(self.owner.model.codex.weekly, 49)
        self.assertEqual(self.owner.model.pending_products, {"claude"})
        self.finish(0)
        self.assertEqual(self.owner.model.codex.weekly, 49, "late Claude overwrote the newer Codex response")
        self.assertEqual(self.fetches["claude"].call_count, 1)
        self.assertEqual(self.fetches["codex"].call_count, 2)

    def test_disable_reenable_reserves_old_physical_flight_and_rejects_stale_publication(self):
        self.owner.refresh_limits(product="codex")
        old_ticket = self.owner.refresh_states["codex"].flight
        self.owner.set_product_enabled("codex", False)
        self.owner.set_product_enabled("codex", True)
        self.now = NOW + 100
        before = (self.owner.model.codex, list(self.cache_calls), self.owner.model.history.record.call_count,
                  copy.deepcopy(self.files))
        self.owner.refresh_limits(product="codex")
        self.assertEqual(len(self.jobs), 1, "re-enable overlapped a still-running old worker")
        self.assertEqual(self.owner.refresh_states["codex"].flight, old_ticket)
        late = snapshot(NOW, 99, live=True)
        late.server_retry_at = NOW + 7200
        self.fetches["codex"].return_value = late
        delivery = self.finish(0)
        self.assertIs(self.owner.model.codex, before[0])
        self.assertEqual(self.cache_calls, before[1])
        self.assertEqual(self.owner.model.history.record.call_count, before[2])
        self.assertEqual(self.files, before[3])
        self.owner.on_limits(*delivery)  # duplicated obsolete completion
        self.owner.refresh_limits(product="codex")
        self.assertEqual(len(self.jobs), 1, "obsolete server restriction was lost")
        self.now = NOW + 7200
        self.owner.refresh_limits(product="codex")
        self.assertEqual(len(self.jobs), 2)
        new_ticket = self.owner.refresh_states["codex"].flight
        self.owner.on_limits(*delivery)
        self.assertEqual(self.owner.refresh_states["codex"].flight, new_ticket)

    def test_cache_exception_preserves_received_success_or_failed_auth_and_retry_metadata(self):
        for auth, live in ((limits.OK, True), (limits.EXPIRED, False), (limits.READ_ERROR, False)):
            self.owner.refresh_states["codex"] = quota_refresh.RefreshState()
            self.owner.refresh_limits(product="codex")
            result = snapshot(self.now, 47, live=live)
            if not live:
                result.session = result.weekly = result.as_of = None
                result.error, result.auth = "HTTP 429", auth
                result.server_retry_at, result.http_status = self.now + 90, 429
                result.failure_kind, result.poll_failed = "http", True
            self.fetches["codex"].return_value = result
            with patch.object(limits, "apply_provider_cache", side_effect=OSError("synthetic cache unavailable")):
                self.finish(len(self.jobs) - 1)
            current = self.owner.model.codex
            self.assertEqual(current.auth, auth)
            self.assertEqual(current.api_fresh, live)
            if live:
                self.assertEqual(current.as_of, self.now)
                self.assertIsNone(current.error)
            else:
                self.assertEqual(current.error, "HTTP 429")
                self.assertEqual(current.http_status, 429)
                self.assertEqual(current.server_retry_at, self.now + 90)
                self.assertTrue(current.poll_failed)
                self.assertTrue(current.from_cache)
                self.assertNotEqual(current.as_of, self.now)
            self.assertIsNone(self.owner.refresh_states["codex"].flight)
            self.now += 100

    def test_worker_exception_and_launch_failure_retire_only_their_ticket_with_safe_error(self):
        self.fetches["codex"].side_effect = RuntimeError("fixture-secret-in-exception")
        self.owner.refresh_limits(product="codex")
        self.finish(0)
        self.assertNotIn("fixture-secret-in-exception", self.owner.model.codex.error)
        self.assertTrue(self.owner.model.codex.poll_failed)
        self.assertFalse(self.owner.model.codex.api_fresh)
        self.assertEqual(self.owner.model.codex.as_of, NOW - 60)
        self.assertIsNone(self.owner.refresh_states["codex"].flight)
        self.now += 30
        with patch.object(app.threading, "Thread", side_effect=RuntimeError("fixture-launch-detail")):
            self.owner.refresh_limits(product="codex")
        self.assertIsNone(self.owner.refresh_states["codex"].flight)
        self.assertNotIn("fixture-launch-detail", self.owner.model.codex.error)
        self.assertEqual(self.owner.model.pending_products, set())

    def test_auth_refresh_does_not_automatically_launch_recovery_or_browser(self):
        result = limits.LimitData()
        result.auth, result.error, result.failure_kind = limits.EXPIRED, "CLI sign-in required", "auth"
        self.fetches["codex"].return_value = result
        self.owner.action("refresh")
        self.finish(1)
        self.owner.win.fix.build_access.assert_not_called()
        self.owner.win.fix.build.assert_not_called()
        self.owner.win.show_page.assert_not_called()
        self.assertEqual(self.owner.model.codex.auth, limits.EXPIRED)
        self.assertFalse(self.owner.model.codex.api_fresh)
        self.owner.action("feedbackfix:codex")  # explicit explanation, no new fetch/login
        self.owner.win.fix.build_access.assert_called_once_with("codex", limits.EXPIRED)
        self.owner.win.show_page.assert_called_once_with(2)
        self.assertEqual(len(self.jobs), 2)

    def test_server_seconds_date_and_unknown_delay_drive_scheduler_and_feedback(self):
        future = format_datetime(datetime.fromtimestamp(NOW + 90, timezone.utc), usegmt=True)
        for raw, deadline in (("90", NOW + 90), (future, NOW + 90), (None, None), ("bad", None)):
            self.now = NOW
            self.jobs.clear(); self.deliveries.clear()
            self.owner.refresh_states["codex"] = quota_refresh.RefreshState()
            self.owner.poll_states["codex"] = polling.PollState({"failed": True, "interval": 14400,
                                                                 "last_attempt": NOW - 60})
            result = limits.LimitData()
            result.error, result.http_status, result.poll_failed = "HTTP 429", 429, True
            result.server_retry_at = quota_refresh.http_failure(429, {"Retry-After": raw}, NOW).retry_at
            self.fetches["codex"].return_value = result
            self.owner.refresh_limits(product="codex")
            self.finish(0)
            for lang in ("ru", "en"):
                self.settings.set("lang", lang)
                detail = panel.feedback_copy(self.owner.model, self.owner.model.codex, "codex")[3]
                if deadline is None:
                    self.assertIn("не сообщил срок" if lang == "ru" else "did not specify a retry time", detail)
                    self.assertNotIn("Сервис разрешит" if lang == "ru" else "Service allows retry", detail)
                else:
                    self.assertIn("Сервис разрешит" if lang == "ru" else "Service allows retry", detail)
                self.assertIn("Автопроверка:" if lang == "ru" else "Automatic check:", detail)
                self.assertEqual(self.owner.model.codex.as_of, NOW - 60)
            self.now = NOW + 30
            self.owner.refresh_limits(product="codex")
            self.assertEqual(len(self.jobs), 1 if deadline is not None else 2)
            if deadline is not None:
                self.now = deadline
                self.owner.refresh_limits(scheduled=True, product="codex")
                self.assertEqual(len(self.jobs), 2)


    def test_huge_finite_server_deadline_uses_safe_qt_checkpoint_and_never_fetches_early(self):
        deadline = quota_refresh.retry_after("1" + "0" * 300, NOW)
        self.assertIsNotNone(deadline)
        self.assertGreater(deadline, NOW + 86400 * 100000)
        self.settings.update(monitor_claude=False, monitor_codex=True)
        self.owner.refresh_states["claude"].set_enabled(False)
        self.owner.refresh_states["codex"].server_until = deadline
        for auto in (True, False):
            self.settings.set("autoPoll", auto)
            self.owner.start_poll_timer()
            self.assertGreater(self.owner.timer.milliseconds, 0)
            self.assertLessEqual(self.owner.timer.milliseconds, 2 ** 31 - 1)
            self.assertLessEqual(self.owner.timer.milliseconds, 60000, "deadline must be revisited without overflow")
            for lang in ("ru", "en"):
                self.settings.set("lang", lang)
                detail = panel.feedback_copy(self.owner.model, self.owner.model.codex, "codex")[3]
                self.assertIn("Сервис разрешит" if lang == "ru" else "Service allows retry", detail)
                self.assertEqual(self.owner.model.codex.server_retry_at, deadline)
            self.owner.refresh_limits()
            self.owner.refresh_limits(scheduled=True)
            self.assertEqual(self.jobs, [])
            self.now += 60
            self.owner.refresh_limits(scheduled=True)
            self.assertEqual(self.jobs, [])
            self.assertEqual(self.owner.refresh_states["codex"].server_until, deadline)


if __name__ == "__main__":
    unittest.main()
