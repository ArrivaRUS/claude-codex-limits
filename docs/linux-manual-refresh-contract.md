# Linux manual refresh — integration contract

Python 3.7+, port of `Sources/QuotaRefresh.swift`; Auto progression remains in
`polling.PollState`. No new endpoints, credential stores or interactive auth.
Phase 1 pure/transport API and phase 2 GUI wiring are implemented. This is an author
handoff, not independent acceptance. Runtime/isolation/security verification is pending.

## Pure API (`linux/ccl/quota_refresh.py`)

- `RefreshState(last_attempt=0, server_until=None)`: one persistent instance per
  provider, exclusively mutated on the main thread. Public state: `enabled`,
  `generation`, `serial`, `flight`, `local_until`, `server_until`.
  `local_until` is a wall-time projection for UI only, initially 0. The actual
  30-second guard uses an in-memory monotonic deadline, never wall elapsed time.
- `set_enabled(bool)`: advance generation only on a selection change; retain any
  flight. Disable/re-enable must call this twice, not recreate the state.
- `admit("manual" | "scheduled", now, scheduled_at=0, *, monotonic_now)` returns
  `Admission(kind, ticket=None, until=None)`. Kinds: `disabled`, `in_flight`,
  `server_wait`, `local_wait`, `not_due`, `start`. Start reserves a
  `Ticket(serial, generation)` and a 30-second guard from admission. Manual ignores
  `scheduled_at` (including 900-second floor and local error backoff).
- `update_clock(now, monotonic_now)`: refresh the UI wall projection without changing
  an active monotonic guard. At the first call after construction, restore the saved
  attempt's remaining guard as `clamp(last_attempt + 30 - now, 0, 30)` (0 when there
  was no saved attempt). Restart cannot reuse a previous process's monotonic epoch;
  a future saved wall timestamp therefore waits at most 30 real seconds, not hours.
- `next_attempt(scheduled_at, *, now, monotonic_now)`: refresh the projection, then
  max(local guard, server deadline if known, otherwise
  scheduled_at). A real server deadline supersedes local Auto error backoff, matching
  the accepted Swift contract. Missing/malformed Retry-After supplies no deadline.
  Both this method and `admit` require injected monotonic time; there is no implicit
  fallback to wall time. UI/scheduling/admission must use the same clock domain.
  Forward/backward wall jumps do not expire or extend the active 30s guard. The
  server deadline remains its original absolute wall epoch: it is never clamped,
  rebased, or cleared by local clock correction, including on restart.
- `complete(ticket, retry_at=None)` retires only the matching flight. True permits
  applying the result. False forbids model/history/cache updates. An obsolete
  selection still retains a returned server deadline; a duplicate completion does
  nothing. Route tickets with provider identity; tickets are provider-local.
- `retry_after(raw, now)` parses delta-seconds or HTTP-date into epoch seconds;
  past dates clamp to now, invalid/overflow/unknown returns None, no one-hour cap.
- `http_failure(status, headers, now, token_endpoint=False, oauth_error=None)` returns
  `HTTPFailure(status, retry_at, authentication_required)`. Only 401 or token-endpoint
  `invalid_grant` proves expired auth. Generic 400/403/429/5xx/network does not.
- `has_readings(data)`, `fallback(result, previous)`,
  `select_snapshot(result, previous)` work on LimitData-like objects. They do not
  mutate inputs. Successful live result always wins, even unchanged percentages.
  Fallback prefers readings, then known/newer as_of, preserves snapshot fields
  together, and retains current attempt auth/error/retry/failure metadata.

## Transport/result API (`linux/ccl/limits.py`)

Existing `fetch_claude()` and `fetch_codex(live=True)` return LimitData. New transient
fields: `server_retry_at`, `http_status`, `failure_kind`, `refresh_in_flight`,
`local_retry_at`; existing `poll_failed`, `next_poll_at`, `api_fresh`, `auth` remain.
`failure_kind`: None or network/http/auth/credentials/invalid_response. No transient
fields are serialized by `to_dict()`. Raw server bodies/errors are not presented.

`codex_usage_live()` now returns a LimitData on failure too (formerly None).
`codex_access_token(result=None)` retains tuple-or-None return and optionally fills
failure metadata. Offline doubles must accept this optional result argument.
Existing token refresh/rotation/write-back mechanism stays in place; failed refresh
now returns truthful metadata immediately. Only confirmed rejection marks the
existing dead-refresh fingerprint; network/429/5xx/generic400 does not mark expired.
Enabled Codex without CLI credentials returns actionable loggedOut on live refresh.

Bounded security correction (requested after phase-1 review):
`_save_claude_tokens(path, old_rt, tok, t, first)` and
`_save_codex_tokens(old_rt, tok, first)` now return `"saved"`, `"pending"`, or
`"superseded"`. `first` supplies expected identity only; it is NEVER used as the
document to write. Missing/unreadable/corrupt current JSON or token block retains
the rotated pair in the existing in-memory `_PENDING` slot and does not write.
An empty or incomplete credential block also stays pending: completeness requires
nonempty, non-whitespace strings for Claude accessToken/refreshToken and Codex
access_token/refresh_token/account_id. Only a complete differing identity can yield
`superseded` and retire pending. The same check protects the initial read on a later
pending retry, so an incomplete block cannot silently discard the retained pair
before reaching write-back. Normal reads without pending keep their existing policy.
Failure of atomic write likewise retains pending. No usage request proceeds with
that pending pair until write-back succeeds; result reports READ_ERROR with sanitized
`credentials update unavailable`, and explicit recovery explains read/save access.
Pending is retried on a later admitted request, never by launching interactive auth.

On a readable current record, compare old refresh + access token identity (also
Codex account_id) with the identity saved when rotation started. A different current
pair wins: discard that pending candidate, perform no write or usage request from
the obsolete candidate, return a retryable `credentials` failure with auth OK.
With matching identity, merge into the CURRENT document, keeping concurrent metadata.
The pending identity remains the original identity across retries, not the newer
`first` argument of a retry. Existing token paths, mode-preserving atomic replacement
and CLI endpoints remain unchanged.

This closes the fail-open stale-document fallback. It is NOT full cross-process
CAS: an external CLI can still change/delete the file between validated re-read and
atomic replacement, and that race needs CLI cooperation or a separate design.
Pending remains memory-only and cannot survive process exit; no durability claim.

`fetch_codex(live=False)` remains an offline snapshot read, not a failed live attempt.
For live failure, rollout/cache fallback keeps its original as_of and the live error,
auth, HTTP status and retry deadline. Cache is never rewritten with failed fallback.

`apply_provider_cache(product, data, previous=None)` must run serially on the main
thread AFTER `complete` returns True. It merges current model and on-disk snapshots,
then persists only an api_fresh/auth-ok/non-error live response, modifying only this
provider's cache key. Return value is the merged LimitData. No worker may call it.
`apply_cache(claude, codex)` remains a compatibility wrapper for a serial caller.
This is main-thread serialization, not a new cross-process cache transaction system.

## Phase 2 GUI API (`linux/ccl/gui/app.py`, bounded `panel.py` adapter)

- `TrayApp.refresh_states`: provider -> RefreshState, created once from saved
  PollState.last_attempt and `quotaServerRetryAt` in the existing state store.
- `refresh_limits(scheduled=False, product=None)`: None requests both enabled
  providers; `product="claude"` or `"codex"` requests only that provider. Unknown
  provider is ignored. Manual uses the same admission path in Auto and fixed modes.
- `Bridge.limits_done`: three object arguments `(product, ticket, data)`, explicitly
  connected with Qt.QueuedConnection to `on_limits(product, ticket, data)`.
- `scheduled_at(product, now=None)`: last attempt + existing Auto interval or selected
  fixed interval (0 before any attempt). If last_attempt is ahead of now, normalize
  this LOCAL anchor to now, restoring `PollState.due`'s correction without changing
  PollState progression or server Retry-After. It is also applied before observe
  when a clock rollback occurred while a worker ran, so a new answer is not falsely
  treated as older than its admission. `start_poll_timer()` uses a single-shot timer,
  earliest enabled non-flight provider deadline, max 60-second wall-clock recheck.
  Qt `start()` milliseconds are independently capped to 60000 (below INT_MAX);
  full server deadline is retained for admission, including finite 1e300. Countdown
  text is bounded and date rendering catches localtime overflow; no early request.
- `publish_auto_intervals()`: projects each provider's flight/local/server deadlines
  into LimitData and Model.pending_products. `busy_limits` is informational only;
  it never gates admission. `next_poll_at` is populated on successful results too;
  disabled/in-flight providers have no next automatic time yet.
  It samples wall and monotonic time once per publication and calls update_clock,
  including while a flight is running, so painted local countdown stays truthful.
- `save_poll_states()`: persists PollState and actual server deadlines in the same
  existing state store; restarts the timer in both modes. An OSError/ValueError saving
  state leaves in-process guards active but cannot guarantee persistence on restart.
- `refresh_feedback()`: a one-second UI-only tick while the panel is visible,
  keeping local/server countdown and retry availability current.
- `panel.feedback_copy(m, d, product)` retains `(first, second, color, tooltip)`.
  `feedback_action(m, d, product, now=None)` returns `(hit_id, title)` or `(None, "")`.
  Native buttons/Tab/AX mirror `feedbackretry:<provider>` and
  `feedbackfix:<provider>`, with matching mouse hits. `draw_feedback` remains 32pt
  and elides painted text to the existing available width; tooltip keeps full text.
- `FixPage.build_access(product, auth)` shows CLI sign-in instructions or a file-read
  recovery step for READ_ERROR, then offers an explicit provider-only retry. No CLI,
  browser, permission request, credential read or write is performed by this page.
- `sound_baselines`: per-provider booleans, initially False. A subscription change
  clears only that provider's baseline. `check_alarms(product, data)` replaces the
  old two-result/global-baseline interface. Only the accepted completed provider's
  fresh, present, auth-OK, non-error/non-cache/non-failed result is compared; pass an
  empty LimitData for the other provider to the unchanged detect_alarms function.
  Establish this baseline only when that reading produces persisted alarm keys.
  Failed/fallback responses cannot establish it or modify alarm state. Thus the first
  live response of each provider suppresses reset events independently of completion
  order; the existing persisted "reached" crossing behavior remains enabled.

Each worker emits `(product, ticket, data)` independently. Main-thread admission calls
PollState.begin; accepted completion calls unchanged PollState.observe once. Worker
exceptions/launch failures must complete the reserved ticket with sanitized errors.
Do not copy or assign the other provider's captured model result. Derive busy/pending
from current flights. Disabled completion cannot update model/cache/history, even
after re-enable. It still releases that exact flight and honors Retry-After.
The fence applies to result/model/cache/history, not cancellation of an already
running request or the existing credential-rotation write-back.

Manual global refresh requests enabled providers; card retry requests only its
provider. Keep selected Auto/fixed mode. Recompute schedule from last attempt and
chosen interval, with server deadline and local guard. No immediate timer duplicate;
one provider's flight must not delay the other's completion or retry. Keep Auto local
activity/backoff progression and fixed 15m/30m/1h/4h selection unchanged.

Compact feedback stays within the existing 32pt card area. Distinguish refreshing,
fresh success (including unchanged), failed fallback with old data time, 30s local
guard, known server wait, unknown server delay, and explicit recovery action.
Recovery only explains the corresponding CLI/file-access step; no automatic CLI,
browser, login, permissions or GitHub auth action. Detailed timing goes in tooltip.

## Independent regression targets and author verification boundary

Required isolated checks: manual <900s and after Auto failure; 30s boundary;
double-click/scheduled overlap; reverse completion; partial retry; disable/re-enable
and duplicate completion; unchanged live; no/unknown/older fallback timestamp;
seconds/date/malformed/huge Retry-After; 401/invalid_grant vs 403/429/5xx/timeout;
token-refresh failure metadata; transient fields excluded from cache; cache keys
survive independent completions; rotation re-read missing/read-error/corrupt/new-pair/
metadata-only changes; pending retry retains original identity; both write-back
callers stop before usage on pending/superseded; huge server deadline with safe Qt
interval and feedback. All runtime checks require isolation review first.
Freeze-2 regression targets additionally include monotonic 29/30/31-second boundaries
under backward and forward wall jumps, restart with recent/old/future last_attempt,
server deadlines surviving all local correction, rollback during a worker, both
startup completion orders, first failed/fallback then live, one-provider disable/
re-enable, and subsequent real reset/reached events only for the completed provider.
Author performs source reading, Python 3.7 grammar parsing/compilation without
executing application code, and static AST boundary checks. No application imports,
credentials/keyring/log reads, network calls, Git commands or test runtime are used.
The reference revision fc794dc and branch codex/linux-compact-refresh were supplied
by the coordinator; Git status/HEAD are intentionally not queried in this assignment.
