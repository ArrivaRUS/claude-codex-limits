"""One headless quota pass: durable reservation, announcement, provider, result.

All process state lives on disk under local account identities. Gist labels are
computed only for the outgoing snapshot and coordination; remote observations
never feed Auto or the local provider Retry-After. No GUI imports or bound paths.
"""

import contextlib
import copy
import json
import os
import time

from . import accounts, common, coordination, limits, polling, sync, usage


PRODUCTS = ("claude", "codex")


def _dict(value):
    return value if isinstance(value, dict) else {}


def _time(value):
    return value if limits.quota_refresh.finite(value) else None


def _failed(result, exc):
    result["error"] = type(exc).__name__
    try:
        common.o1_event("pass_failed", **{"class": type(exc).__name__})
    except Exception:
        # Even failure to journal must not escape a timer pass. BaseException
        # (including process termination) deliberately remains outside this fence.
        pass


def _skip(result, product, reason, until=None):
    result["skipped"][product] = reason
    if _time(until) is not None:
        result["next_at"][product] = until
    common.o1_event("poll_skipped", product=product, reason=reason)


def _load_product(saved, product, local_id, state):
    root = saved.setdefault(product, {})
    if not isinstance(root, dict):
        root = saved[product] = {}
    first_account = "accountId" not in root
    previous_id = root.get("accountId")
    buckets = root.setdefault("accounts", {})
    if not isinstance(buckets, dict):
        buckets = root["accounts"] = {}
    bucket = buckets.setdefault(local_id, {}) if local_id else {}
    if not isinstance(bucket, dict):
        bucket = buckets[local_id] = {}
    mirror = _dict(_dict(state.get("autoPollState")).get(product))
    poll = polling.PollState(bucket.get("poll"))
    # The mirror is also a write-ahead reservation if the process died between
    # the two durable files. An unlabelled legacy schedule may constrain the
    # first account, but must never migrate onto a later account switch.
    same = mirror.get("accountId") == local_id if "accountId" in mirror else first_account
    if local_id and same:
        if "poll" not in bucket or (_time(mirror.get("last_attempt")) is not None
                                    and mirror["last_attempt"] > poll.last_attempt):
            poll = polling.PollState(mirror)
        deadlines = [_time(bucket.get("retryUntil")),
                     _time(_dict(state.get("quotaServerRetryAt")).get(product))]
        bucket["retryUntil"] = max((v for v in deadlines if v is not None), default=None)
    root["accountId"] = local_id
    if previous_id != local_id:
        common.o1_event("label_changed", product=product)
    return bucket, poll


def _mirrors(current):
    polls, retries = {}, {}
    for product, (local_id, _reason, bucket, poll) in current.items():
        if local_id:
            bucket["poll"] = poll.saved()
            polls[product] = dict(poll.saved(), accountId=local_id)
            if _time(bucket.get("retryUntil")) is not None:
                retries[product] = bucket["retryUntil"]
    return polls, retries


def _save(saved, current):
    polls, retries = _mirrors(current)
    # A crash after this first write retains the attempt via the account-fenced
    # mirror. Failure of either write prevents provider I/O.
    common.state().update(autoPollState=polls, quotaServerRetryAt=retries)
    common.write_json(os.path.join(common.STATE_DIR, "publisher-state.json"), saved)


def _remote(session, product, label):
    out = []
    for machine in _dict(session.remote).get("machines", []) if session else []:
        if not isinstance(machine, dict):
            continue
        for record in machine.get("accounts", []):
            if not isinstance(record, dict) or record.get("product") != product or record.get("label") != label:
                continue
            schedule = _dict(record.get("schedule"))
            out.append(dict(machineId=machine.get("id"), status=record.get("status"),
                            lastSeenAt=machine.get("lastSeenAt"),
                            interval=schedule.get("interval"),
                            **{key: common.parse_iso(value) for key, value in
                               (("asOf", record.get("asOf")), ("attemptAt", record.get("attemptAt")),
                                ("retryUntil", record.get("retryUntil")), ("nextAt", schedule.get("nextAt")))}))
    return out


def _entry(product, local_id, reason, bucket, poll, auto):
    data = {} if bucket.get("status") == "signed_out" else _dict(bucket.get("snapshot"))
    out = dict(product=product, localId=local_id, status=bucket.get("status", "error"), days={})
    if reason:
        out["labelReason"] = reason
        out["status"] = "signed_out" if reason == "no_login" else "error"
    for key in ("plan", "resetCredits"):
        if key in data:
            out[key] = data[key]
    if _time(data.get("asOf")) is not None:
        out["asOf"] = common.iso_utc(data["asOf"])
    windows = {}
    for name, reset in (("session", "sReset"), ("weekly", "wReset")):
        if name in data:
            win = windows[name] = {"pct": data[name]}
            if _time(data.get(reset)) is not None:
                win["resetAt"] = common.iso_utc(data[reset])
    if windows:
        out["windows"] = windows
    scoped = _dict(data.get("scoped"))
    if scoped:
        model = dict(name=scoped.get("name"), pct=scoped.get("percent"))
        if _time(scoped.get("reset")) is not None:
            model["resetAt"] = common.iso_utc(scoped["reset"])
        out["models"] = [model]
    if bucket.get("expiredReason"):
        out["expiredReason"] = bucket["expiredReason"]
    if poll.last_attempt:
        out["attemptAt"] = common.iso_utc(poll.last_attempt)
        out["attemptKind"] = bucket.get("attemptKind", "auto")
    retry = _time(bucket.get("retryUntil"))
    out["retryUntil"] = common.iso_utc(retry) if retry is not None else None
    schedule = out["schedule"] = dict(mode="auto" if auto else "fixed", interval=poll.interval, backoff=poll.failed)
    if poll.last_attempt:
        schedule["nextAt"] = common.iso_utc(poll.last_attempt + poll.interval)
    return out


def _text(saved, current, ix, gist_id, auto):
    entries = { (p, values[0]): _entry(p, *values, auto) for p, values in current.items() }
    unattributed = {}
    attribution = _dict(ix.get("accountByDay"))
    for product, days in usage.snapshot_days(ix).items():
        for day, models in days.items():
            local_id = _dict(attribution.get(product)).get(day)
            if not isinstance(local_id, str) or not local_id:
                unattributed.setdefault(product, {})[day] = models
                continue
            key = product, local_id
            if key not in entries:
                # An old account contributes historical usage, never a live
                # reading resurrected after logout or an account switch.
                entries[key] = dict(product=product, localId=local_id, status="signed_out", days={})
            entries[key]["days"][day] = models
    block = accounts.build(gist_id=gist_id, entries=list(entries.values()),
                           unattributed_days=unattributed, captions={})
    if block.pop("dropped", None) == "counter_overflow":
        common.o1_event("accounts_days_dropped", reason="counter_overflow")
    obj = json.loads(sync.machine_file(block["days"]))
    obj.update(block)
    obj["lastSeenAt"] = common.iso_utc()
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def _publish(session, text, result):
    try:
        ok = sync.write(session, text)
    except Exception as exc:
        _failed(result, exc)
        ok = False
    common.o1_event("publish", result="ok" if ok else "failed")
    return ok


def _publish_failed(result):
    result["error"] = "publish_failed"
    try:
        sync.sync_state().update(lastError="Publisher publication failed", lastErrorAt=time.time())
    except OSError:
        # Diagnostic storage must not prevent the reservation rollback. The
        # caller still receives an error even when status cannot be persisted.
        pass


def _recover_rollback(saved, state):
    """Complete an interrupted rollback, only after a confirmed PATCH failure.

    The marker is written before either restored file. A crash before a PATCH
    outcome or after a successful PATCH keeps the original conservative attempt.
    """
    rollback = saved.get("_rollback")
    if not isinstance(rollback, dict):
        return saved
    restored = rollback["saved"]
    state.update(autoPollState=rollback["autoPollState"], quotaServerRetryAt=rollback["quotaServerRetryAt"])
    common.write_json(os.path.join(common.STATE_DIR, "publisher-state.json"), restored)
    return restored


def _rollback(saved, old_saved, old_auto, old_retry, state):
    saved["_rollback"] = dict(saved=old_saved, autoPollState=old_auto, quotaServerRetryAt=old_retry)
    common.write_json(os.path.join(common.STATE_DIR, "publisher-state.json"), saved)
    _recover_rollback(saved, state)
    saved.pop("_rollback", None)


def _accept(product, local_id, bucket, data):
    """C3 fallback and cache writes are restricted to this identity's snapshot.

    The GUI cache helper predates account fencing. Keep its fresh-only rule but
    never let its product-wide fallback cross account identities.
    """
    fresh = (data.api_fresh and data.present and data.error is None and data.auth == limits.OK
             and not data.from_cache and not data.stale and _time(data.as_of) is not None)
    if fresh:
        bucket["snapshot"] = data.to_dict()
    bucket["status"] = ("ok" if fresh else "signed_out" if not data.present or data.auth == limits.LOGGED_OUT
                        else "expired" if data.auth == limits.EXPIRED else
                        "rate_limited" if data.http_status == 429 else "error")
    bucket["expiredReason"] = data.expired_reason
    bucket["retryUntil"] = _time(data.server_retry_at)
    bucket["errorClass"] = data.failure_kind if data.failure_kind in (
        "network", "http", "auth", "credentials", "invalid_response", "busy") else None
    cache = _dict(common.read_json(common.CACHE_PATH, {}))
    snapshot = {} if bucket["status"] == "signed_out" else _dict(bucket.get("snapshot"))
    cache[product] = dict(snapshot, accountId=local_id)
    common.write_json(common.CACHE_PATH, cache)


def _locked(kind, ix, result, reopened=False):
    state = common.state()
    state.reload()
    saved = _dict(common.read_json(os.path.join(common.STATE_DIR, "publisher-state.json"), {}))
    saved = _recover_rollback(saved, state)
    settings = common.settings()
    settings.reload()
    auto = bool(settings.get("autoPoll"))
    current = {}
    for product in PRODUCTS:
        if not common.product_enabled(product):
            continue
        local_id, reason = accounts.read_local_id(product)
        bucket, poll = _load_product(saved, product, local_id, state)
        if auto:
            poll.local_activity(_dict(ix.get("activity")).get(product, []), time.time())
        else:
            poll.interval = polling.normalize_interval(settings.get("interval"))
        current[product] = local_id, reason, bucket, poll

    now = time.time()
    locally_due = any(local_id and poll.due(now, manual=kind == "manual")
                      and now >= (_time(bucket.get("retryUntil")) or 0)
                      for local_id, _reason, bucket, poll in current.values())
    last_read_attempt = _time(sync.sync_state().get("lastAttemptAt"))
    guarded_read = (kind == "manual" and not locally_due and last_read_attempt is not None
                    and 0 <= now - last_read_attempt < 30)
    session = None if guarded_read else sync.open_cycle(auto=True)
    st = sync.sync_state()
    gist_id = session.gist_id if session else st.get("gistId")
    now = time.time()
    due = []
    for product, (local_id, reason, bucket, poll) in current.items():
        if not local_id or not gist_id:
            _skip(result, product, "no_login" if reason == "no_login" else "no_label")
            continue
        if product == "claude" and limits.claude_token_policy_blocks(now):
            _skip(result, product, "token_policy")
            continue
        local_due = poll.due(now, manual=kind == "manual")
        interval = polling.MINIMUM if kind == "manual" and not poll.failed else poll.interval
        own_next = poll.last_attempt + interval if poll.last_attempt else now
        remote = _remote(session, product, accounts.label(product=product, local_id=local_id, gist_id=gist_id))
        decision = coordination.decide(now, dict(interval=poll.interval, last_attempt=poll.last_attempt,
                                                server_until=bucket.get("retryUntil"), manual=kind == "manual",
                                                remote_retry=bucket.get("remote_retry")), remote,
                                       common.machine_id(), bucket.get("tie_wait")) if local_due else None
        if decision:
            bucket["remote_retry"], bucket["tie_wait"] = decision.remote_retry, decision.tie_wait
            for ev in decision.events:
                common.o1_event(ev, product=product)
        retry = _dict(bucket.get("remote_retry"))
        next_at = max(own_next, _time(bucket.get("retryUntil")) or 0)
        if _time(retry.get("until")) is not None and _time(retry.get("firstSeenAt")) is not None:
            next_at = max(next_at, min(retry["until"], retry["firstSeenAt"] + coordination.RETRY_CAP))
        if decision and decision.reason == "remote_attempt":
            # Use precisely the records admitted by B2, including its time fences.
            valid = coordination.records(now, remote, common.machine_id())
            next_at = max([next_at] + [r["attemptAt"] + coordination.ATTEMPT_WINDOW
                                      for r in valid if r["attemptAt"] is not None])
        result["next_at"][product] = next_at
        if not local_due or now < (_time(bucket.get("retryUntil")) or 0):
            reason = "retry_after" if now < (_time(bucket.get("retryUntil")) or 0) else "not_due"
            _skip(result, product, reason, next_at)
        elif decision.action == "skip":
            _skip(result, product, decision.reason, next_at)
        else:
            due.append(product)

    if due:
        old_saved = copy.deepcopy(saved)
        old_polls = {p: copy.deepcopy(v[3].saved()) for p, v in current.items()}
        old_auto = copy.deepcopy(state.get("autoPollState"))
        old_retry = copy.deepcopy(state.get("quotaServerRetryAt"))
        for product in due:
            _local_id, _reason, bucket, poll = current[product]
            poll.begin(now)
            bucket.update(attemptAt=now, attemptKind=kind, attemptPublished=False)
        try:
            _save(saved, current)
        except OSError:
            for product in due:
                _skip(result, product, "state_unsaved")
            return
        if session and not _publish(session, _text(saved, current, ix, gist_id, auto), result):
            if not reopened and getattr(session, "write_error", None) in ("stale", "busy"):
                _rollback(saved, old_saved, old_auto, old_retry, state)
                return _locked(kind, ix, result, reopened=True)
            _publish_failed(result)
            count = saved.get("_publishFailures", 0)
            count = min(count + 1, 3) if type(count) is int and count >= 0 else 1
            saved["_publishFailures"] = old_saved["_publishFailures"] = count
            fallback = [p for p in due if count >= 3 or
                        (old_polls[p]["last_attempt"] > 0 and
                         now - old_polls[p]["last_attempt"] >= max(old_polls[p]["interval"], coordination.RETRY_CAP))]
            if not fallback:
                # Journal before restoring either file. Store.update preserves
                # unrelated keys that other components may have changed.
                _rollback(saved, old_saved, old_auto, old_retry, state)
                for product in due:
                    _skip(result, product, "publish_failed")
                    result["next_at"][product] = old_polls[product]["last_attempt"] + old_polls[product]["interval"]
                return
            # A failed announcement is treated like an unavailable gist only
            # for products whose own schedule has exhausted the failure budget.
            for product in due:
                if product not in fallback:
                    local_id, reason, bucket, _poll = current[product]
                    bucket.clear()
                    bucket.update(old_saved[product]["accounts"][local_id])
                    current[product] = local_id, reason, bucket, polling.PollState(old_polls[product])
                    _skip(result, product, "publish_failed")
            due, session = fallback, None
            # Mixed fallback still rolls back the excluded products. Journal
            # the complete target (retaining the fallback reservations) before
            # either mirror is restored, exactly as for a full rollback.
            polls, retries = _mirrors(current)
            _rollback(saved, copy.deepcopy(saved), polls, retries, state)
        elif session:
            saved["_publishFailures"] = 0
        for product in due:
            local_id, _reason, bucket, poll = current[product]
            bucket["attemptPublished"] = session is not None
            # CLI sign-in can change while GET/PATCH is in flight. Do not send
            # a request for B using the reservation we just announced for A.
            if accounts.read_local_id(product)[0] != local_id:
                common.o1_event("identity_changed", product=product)
                bucket["status"] = "error"
                _save(saved, current)
                continue
            common.o1_event("poll_attempt", product=product, kind=kind, attemptAt=now)
            provider = getattr(limits, "fetch_" + product)
            error_class = None
            try:
                data = provider(live=True) if product == "codex" else provider()
            except Exception as exc:
                _failed(result, exc)
                data = limits.LimitData()
                data.error, data.poll_failed = "provider failed", True
                data.account = local_id
                error_class = type(exc).__name__
            result["polled"].append(product)
            after_id, _ = accounts.read_local_id(product)
            local_failure = (data.account is None and data.auth in (limits.LOGGED_OUT, limits.READ_ERROR)
                             and not data.api_fresh and data.http_status is None)
            if after_id != local_id or (data.account != local_id and not local_failure):
                common.o1_event("identity_changed", product=product)
                bucket["status"] = "error"
            else:
                poll.observe(data, time.time())
                if not auto:
                    poll.interval = polling.normalize_interval(settings.get("interval"))
                _accept(product, local_id, bucket, data)
                if error_class:
                    bucket["errorClass"] = error_class
                common.o1_event("poll_result", product=product, httpStatus=data.http_status,
                                result="ok" if bucket["status"] == "ok" else "failed")
            _save(saved, current)
            result["next_at"][product] = max(poll.last_attempt + poll.interval, _time(bucket.get("retryUntil")) or 0)
    else:
        _save(saved, current)

    if session:
        text = _text(saved, current, ix, gist_id, auto)
        pending = any(poll.last_attempt and bucket.get("attemptPublished") is False
                      for _local_id, _reason, bucket, poll in current.values())
        if sync.write_due(session, text, force=bool(due) or pending):
            if _publish(session, text, result):
                saved["_publishFailures"] = 0
                for _local_id, _reason, bucket, poll in current.values():
                    if poll.last_attempt:
                        bucket["attemptPublished"] = True
                _save(saved, current)
            else:
                _publish_failed(result)


@sync.clock_observation()
def run_pass(kind="auto"):
    """Run once; return {polled, skipped, next_at, error} for CLI/status callers.

    Ordinary exceptions are journalled by class only. Termination is propagated.
    Pending rotations are flushed exactly once, after provider attempt scopes,
    while quota is still held when this pass acquired it.
    """
    result = dict(polled=[], skipped={}, next_at={}, error=None)
    try:
        with contextlib.ExitStack() as stack:
            try:
                if kind not in ("auto", "manual"):
                    raise ValueError("unknown publisher pass kind")
                ix, _changed, _fresh = usage.refresh()
                st = sync.sync_state()
                if not st.get("login") or st.get("revoked"):
                    for product in PRODUCTS:
                        if common.product_enabled(product):
                            _skip(result, product, "no_github")
                    return result
                held = stack.enter_context(common.file_lock("quota", timeout=30))
                if not held:
                    common.o1_event("pass_skipped", reason="busy")
                    result["skipped"] = {p: "busy" for p in PRODUCTS if common.product_enabled(p)}
                    return result
                _locked(kind, ix, result)
            except Exception as exc:
                _failed(result, exc)
            finally:
                try:
                    limits.flush_pending()
                except Exception as exc:
                    _failed(result, exc)
    except Exception as exc:
        # ExitStack releases quota after the flush; __exit__/close failures
        # belong to the pass failure contract just like acquisition failures.
        _failed(result, exc)
    return result
