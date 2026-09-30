# Usage sync protocol (v1)

How copies of Claude Codex Limits on different computers share **local usage** through one
secret GitHub gist. This file is the contract for the macOS app (`Sources/LimitsMonitor.swift`)
and the Linux port (`linux/`), including the platform differences below. Incompatible changes
to the shared file format require bumping `schema` and updating both sides.

## What is shared and what is not

- Limit **percentages and reset times** are already account‑wide: they come from the Anthropic /
  OpenAI servers. They are **not** synced.
- **Local usage** — tokens per day per model, read from the CLIs' own transcripts — exists only on
  the machine where the CLI ran. That is what this protocol shares, so the bars, calendar and
  money in the Advanced view can cover every computer.
- Only aggregates travel: counts per product → day → model. No prompts, no file paths, no project
  names, no session ids.

## Transport: one secret gist

- Auth: GitHub **OAuth Device Flow**, scope `gist`, one OAuth App shared by all ports
  (see *Client ID* below). The token is stored locally (macOS Keychain; Linux: Secret Service if
  available, else a `0600` file) and is never logged or printed.
- API request headers: `Authorization: Bearer <token>`, `Accept: application/vnd.github+json`,
  `X-GitHub-Api-Version: 2022-11-28`, `User-Agent: ClaudeCodexLimits`.
- **Token boundary.** Bearer authentication is allowed only on `https://api.github.com`:
  validate the scheme, ASCII host, port (absent or `443`) and absence of userinfo. Requests with
  Authorization do not follow redirects; `3xx` ends the cycle as an error. A truncated file's
  `raw_url` is fetched **without Authorization**; those unauthenticated requests may follow redirects.
- **Discovery.** `GET /gists?per_page=100`. Linux follows `Link: rel="next"` only to the same
  validated API origin, for at most 30 pages; macOS requests numbered pages, at most 10, stopping
  at a page with fewer than 100 entries. A sync gist must contain `ccl-sync.json` and have
  `public` equal to the JSON boolean `false` (missing or unknown visibility is not accepted).
  If several exist, use the one with the earliest `created_at`.
  If none exists, create it: `POST /gists` with `"public": false`, description
  `Claude Codex Limits — usage sync (do not edit)`, files `ccl-sync.json` and this machine's file.
  Cache the gist id locally; check discovery again once a day and just after creation to converge
  on the earliest gist. A gist switch clears the saved push hash.
- **Before PATCH**, GET the gist and require `public == false`. A `404` or public/unknown
  visibility clears the cached gist id and push hash for rediscovery. macOS ends the cycle with
  an error and rediscovers next time; Linux retries discovery/GET within a two-pass loop, then
  fails if no usable gist is found. A PATCH `404` ends the cycle on both platforms and clears
  the gist id/hash for the next cycle. No machine snapshot is patched into a public gist.
- **Manifest** `ccl-sync.json`: `{"schema": 1, "created": "<ISO-8601 UTC>", "about": "https://github.com/ArrivaRUS/claude-codex-limits/blob/main/docs/sync-protocol.md"}`.

## One file per machine

- Name: `machine-<id>.json`, where `<id>` is a random lowercase UUID v4 generated once per machine
  and kept outside the app bundle so a reinstall keeps it
  (macOS: `~/.claude-limits-monitor/machine-id`; Linux: `~/.config/claude-codex-limits/machine-id`).
- A machine writes **only its own file**, and always the **whole snapshot** (idempotent — never a
  delta), so a lost or repeated write can't double‑count.
- `schema` is the integer `1`; JSON boolean `true` is not a schema number. Readers apply the
  numeric checks described under *Read and merge*.

```json
{
  "schema": 1,
  "machine": { "id": "5f0c…", "name": "astra-desktop", "os": "Astra Linux SE 1.8", "app": "linux 0.1" },
  "updated": "2026-09-27T10:15:00Z",
  "tz": "Europe/Moscow",
  "days": {
    "claude": {
      "2026-09-24": {
        "claude-fable-5-1": { "input": 1200, "output": 3400, "cacheRead": 900000,
                              "cacheWrite5m": 0, "cacheWrite1h": 52000, "turns": 41 }
      }
    },
    "codex": {
      "2026-09-24": {
        "gpt-6-astra": { "input": 30000, "output": 8000, "cacheRead": 410000,
                         "cacheWrite5m": 0, "cacheWrite1h": 0, "turns": 12 }
      }
    }
  }
}
```

- `days` keys are **local calendar dates of that machine** (`yyyy-MM-dd`, its `tz`), last
  **45 days** only. Model ids are raw, exactly as they appear in the logs; the reader prices them.
- Field meaning matches `DayModelUsage` in the macOS source:
  - Claude (`~/.claude/projects/**.jsonl`, **including** `<session>/subagents/agent-*.jsonl`):
    `message.usage.input_tokens` → `input`, `output_tokens` → `output`,
    `cache_read_input_tokens` → `cacheRead`, `cache_creation.ephemeral_5m_input_tokens` →
    `cacheWrite5m`, `cache_creation.ephemeral_1h_input_tokens` → `cacheWrite1h`
    (if only `cache_creation_input_tokens` is present, count it as 5m). One assistant message id
    counts **once per day** — transcripts repeat messages after resume/compaction.
  - Codex (`~/.codex/sessions/**/rollout-*.jsonl`): each `token_count` event's
    `info.last_token_usage`; `input = input_tokens − cached_input_tokens`,
    `cacheRead = cached_input_tokens`, `cacheWrite5m = cache_write_input_tokens` (0 if absent),
    `output = output_tokens` (reasoning is inside output);
    model from the latest `turn_context.payload.model`.
  - Day = local date of the line's `timestamp`.

## Sync cycle

- Run one cycle **at start** and then **every 10 minutes**, whether or not local usage changed:
  other machines' data only arrives by reading, so a cycle must never depend on local changes.
- On **macOS**, normal sync scheduling requires the Advanced view to be enabled: startup,
  the 10-minute timer and wake all check `advancedEnabled()`. Enabling Advanced also starts a
  scan and sync. After wake, check Advanced inside a callback delayed by about **7 seconds**.
  A cycle that encounters transport status `0` or `5xx` schedules **one retry after 60 seconds**;
  that retry does not schedule another retry. A new cycle cancels a pending retry. The queued
  retry itself does not recheck Advanced. Linux's tray schedules sync independently of Advanced.
- Cycles require a usable sign-in and respect backoff. They are serialized on macOS's queue
  `q` (`ccl.sync`) and Linux's `file_lock("sync")`; a busy Linux cycle is skipped. Sign-in/out
  mutations use the same serialization (Linux waits up to 60 seconds and checks that it holds
  the lock before mutating state).
- A cycle = discover if needed → GET and validate the secret gist → write this machine's
  snapshot if needed → fetch any truncated remote files → merge the files from that GET.
- `ccl-sync status` reads the token and GETs the cached gist only while holding the nonblocking
  sync lock. If busy, it reads neither the token nor the network, shows cached state/machines,
  and prints «Sync is running in another process — showing cached machines».

## Write

- `PATCH /gists/{id}` with `{"files": {"machine-<id>.json": {"content": "<json>"}}}` — only when
  the usage snapshot changed since the last successful write (compare a hash), or a forced sync
  was requested. Linux also rewrites a missing own file and, in automatic mode, limits changed
  snapshots to roughly one write per 10 minutes (with 30 seconds of tolerance); forced or missing
  files bypass that interval. macOS has no separate write interval/missing-file rule. An unchanged
  snapshot normally skips the write, never the read.

## Read and merge

- `GET /gists/{id}` **every cycle**; for a file with `"truncated": true`, fetch its `raw_url`.
- Take every `machine-*.json` **except this machine's own id** (own data always comes from the local
  index, never from the gist). Require `schema` equal to integer `1`, never boolean `true`:
  Linux requires `type(schema) is int`; macOS uses `syncCount`, accepting numbers that bridge
  exactly to Swift `Int` (including `1.0`) and rejecting CFBoolean.
  Skip other schemas and unparsable JSON, including excessive nesting: Linux catches
  `RecursionError`; macOS skips `JSONSerialization` errors via `try?`. One bad file does not
  stop the merge.
  `machine` must be an object with a nonempty string `id`, and the filename must be exactly
  `machine-<id>.json`. Each id contributes at most once.
- An absent `updated` is accepted. If present, it must parse as an ISO-8601 timestamp;
  **fractional seconds are accepted** on both platforms. An invalid timestamp (including null)
  or one older than 45 days rejects the file.
- The six counters (`input`, `output`, `cacheRead`, `cacheWrite5m`, `cacheWrite1h`, `turns`) default
  to zero when missing. Each supplied value must be an integer in **0…10^15**; booleans are not
  numbers. An invalid counter rejects the entire model record. Linux requires a JSON integer
  (`type(n) is int`); macOS accepts values that bridge exactly to Swift `Int`, rejecting CFBoolean.
  Invalid nested usage structures are skipped: macOS requires the whole `days` object to cast to
  its nested dictionary type; Linux checks each product/day/model level separately. A valid
  machine can remain listed even when it contributes no usable usage records.
- Merge = sum per product → day → model. Both platforms clamp accumulated counters to `10^15`.
  Linux also bounds counts/display amounts before float arithmetic, including older caches.
  macOS `usageSum` ignores a contribution that would overflow `Int`, then clamps to `10^15`.
  Malformed remote counters/structures must not crash the app.
  Machines' transcripts are disjoint, so valid counts give the account total for what ran in the CLIs.
- **Truncated-file failure.** A `raw_url` response other than `200`, or a missing/empty body,
  fails the whole cycle: keep the previous remote merge/cache and do not advance the last-success
  time (`syncLastOkAt` / `lastOkAt`). macOS also fails on invalid UTF-8, recording
  `Empty or unreadable GET raw_url response`. Linux decodes nonempty bytes with UTF-8 replacement:
  invalid bytes alone do not fail the cycle; the resulting text goes through normal JSON/file
  validation and may be skipped. Invalid JSON in an otherwise readable file is a file-level skip
  on both platforms. If a truncated file has no `raw_url`, macOS fails the cycle; Linux keeps the
  inline content if present, otherwise skips it. Raw `403`/`429` uses the backoff rules below;
  raw `401` is an unauthenticated read error and never starts the token-revocation checks.
  A write already completed earlier in the cycle keeps its push hash/upload time even if reading fails.
- Show which machines are included and when each last reported (e.g. «2 компьютера · astra-desktop
  обновлён 10:15»).

## Errors

- A single `401` on a gist request is **not** proof of revocation (GitHub returns stray 401s).
  Use variant **a**: `401` on the gist → `GET https://api.github.com/user`; if that is also `401`,
  pause about **4 seconds**, then repeat `GET /user` with the **same captured token**. The pause
  stays inside the serialized cycle: macOS queue `q`, Linux `file_lock("sync")`.
  - Only **three consecutive 401s** (gist, user, user) mark the sign-in revoked. Persist the
    revoked flag **before deleting** the stored token, show «Войдите в GitHub заново», and stop
    syncing until a new sign-in. macOS rereads the Keychain: a different token aborts revocation;
    the same token may be deleted. If the store cannot be read, set the flag but leave the token.
    Linux captures `(tokenGeneration, tokenBackend)`, checks that it is still active after the
    pause and again before setting `revoked`, and adds the pair to `tokenDeletePending` in the
    same state update as `revoked=true`, before deleting only that captured generation/backend.
    Linux keeps «Sign out» available while revoked with pending deletions. macOS shows it while
    revoked if `keychainItemLeft` is true, including an unknown result after a read failure/timeout.
  - Any non-401 response ends the confirmation sequence immediately. `/user` `200` records
    «401 on <request>, sign-in confirmed» and still fails the cycle; `403`, `429`, `5xx`, network
    failure or any other response records an inconclusive-check error. Keep the token and retry
    later; apply backoff when the response indicates a rate limit. A non-401 gist error does not
    start confirmation at all.
- **Backoff.** Every `429`, and a `403` with `Retry-After` or `x-ratelimit-remaining: 0`, pauses
  sync. Prefer a finite, nonnegative numeric `Retry-After` (seconds), otherwise use
  `x-ratelimit-reset` only when `x-ratelimit-remaining == 0`; cap the delay at **one hour**, with
  **15 minutes** as the fallback. macOS falls through an invalid Retry-After to a valid reset
  and floors a past reset at zero delay. Linux adds 5 seconds to the reset epoch and falls back
  directly to 15 minutes if a present Retry-After is invalid. A `403` without rate-limit signals
  is an access error with **no pause**. macOS keeps HTTP backoff in memory; Linux persists it as
  `backoffUntil`.
- Network failure → keep the last merged result, retry next cycle. Sync must never block or break
  the limits display.
- The token store may hang (a locked Keychain / Secret Service waiting for an unlock prompt): every
  call to it gets a timeout (~15 s); a token-read timeout ends the cycle as an error. macOS also
  delays background Keychain work for 30 minutes after a timeout; explicit sign-in/out can bypass
  that delay. Linux never falls through to a file token after a Secret Service read timeout.
- On macOS, a Keychain `.token` without `syncLogin` loads as phase `off` unless `syncRevoked` is set.
- **Linux token generations.** A Secret Service item carries a `generation` attribute; sync state
  selects `tokenGeneration` plus `tokenBackend`. Reads use only the active pair and discard a
  result if the pair changed during the read.
  - Under the sync lock: store a fresh generation → verify → publish the active pair → retire
    the previous `(generation, backend)` and pending references by addressed deletion. No sweep
    deletes items by common application/service attributes; unrelated generations are left alone.
  - Failed deletions and generations of failed/timed-out Secret Service writes are retained in
    `tokenDeletePending`, deduplicated and retried on the next publication or sign-out. The newly
    published pair is excluded. An unavailable Secret Service (`ss_write` returns `None`) adds no reference.
  - A late `CreateItem` after timeout attempts to delete its own generation on the same connection; timeout
    during verification also triggers worker cleanup. A late delete cannot address a newer generation.
  - File fallback uses a different fresh generation in a `0600` staged file (token on the first
    line, generation on the second). Verify the staged file, then replace the main token file
    only at publication; cancellation deletes the staged generation without replacing the active file.
  - Items/files without a generation and state without `tokenGeneration` are treated as `legacy`,
    preserving existing sign-ins. Only legacy state with an unknown backend may discover a legacy
    copy across backends; legacy searches filter out newer generations. An empty generation disables reads.
  - Sign-out invalidates the active pair before deleting it and all pending references. With cleanup
    complete, two consecutive sign-ins leave one stored copy; sign-out leaves no tracked application
    items or token files, including staged files. Failed addressed deletions remain pending; late writes must
    finish their cleanup before this invariant holds. Unknown generations are not swept.
  - `sign_out_incomplete` means nonempty `tokenDeletePending` **and** (no login or a revoked login):
    show «Выход не завершён» / «Sign-out isn't complete» and allow retrying sign-out. Pending cleanup
    alone during a live sign-in does not mean sign-out is incomplete.
- **Visibility.** Keep the time of the last successful cycle (read included), the last attempt and
  the last error (text + time). A successful cycle clears the last error. Settings show
  «last upload · read» times and the last error, including in the revoked state. The Advanced
  main view shows «Синхронизация стоит с HH:mm: <причина>» with the following shared timing rule:
  - While signed in (macOS phase `on`; Linux login, not revoked), let `since` be the last OK cycle
    (`lastSync` / `syncLastOkAt` on macOS; `lastOkAt`, legacy `lastSync` fallback on Linux), or the
    last upload (`lastUploadAt` / `pushedAt`) if no OK time exists. Require both
    `now - since > 30 minutes` and `lastErrorAt > since + 30 minutes`. Time passing alone after an
    earlier error does not qualify. Linux also requires nonempty `lastError`; macOS does not check
    nonemptiness and uses «waiting for GitHub» if the text is nil.
  - Interactive apps (macOS and Linux tray) additionally require a first attempt **started in this
    process**, with `lastErrorAt` at or after that attempt. Busy/off/revoked/backoff skips do not
    start an attempt. `ccl-sync status` uses `require_attempt=False`, with no process-attempt requirement.
  - Without any success/upload time, an error produces «Синхронизация не работает: …» instead:
    macOS retains the attempt/error-time gate and requires non-nil text; Linux requires nonempty
    text and, in the tray, a process attempt, but does not check the error timestamp in this branch.
  - Revoked state produces «Войдите в GitHub заново — суммы без других компьютеров» without waiting
    for an attempt. `ccl-sync status` suppresses this warning when `sign_out_incomplete` is true
    and shows the cleanup/retry message instead. Main-view warnings are visible only in Advanced;
    transient read errors retain the previous merge, while revoked/off state excludes remote totals.

## Device Flow, step by step

1. `POST https://github.com/login/device/code` (`Accept: application/json`) with
   `client_id`, `scope=gist` → `device_code`, `user_code`, `verification_uri`, `interval`, `expires_in`.
2. Show `user_code`, open `verification_uri` in the browser.
3. Poll `POST https://github.com/login/oauth/access_token` with `client_id`, `device_code`,
   `grant_type=urn:ietf:params:oauth:grant-type:device_code` every `interval` seconds:
   `authorization_pending` → keep polling; `slow_down` → interval += 5; `expired_token` /
   `access_denied` → stop and say so.
4. Require `GET /user` to return `200` and a nonempty `login` before saving the token and showing
   the login («GitHub: ArrivaRUS»).
   - Each attempt has an identity: macOS `loginID`; Linux `begin_login` / `cancel_login` / `is_current`
     (process-local). Publish only a verified, current, noncancelled attempt; the final check and
     publication share the lock with begin/cancel. Cancelling A and starting B prevents late A from publishing.
   - Check cancellation after network responses and storage/verification. A cancelled attempt that
     already stored a token attempts addressed cleanup: Linux deletes its own generation (failed
     deletion stays pending); macOS deletes the Keychain item only if rereading returns the same token.
   - macOS `cancelledLoginPhase` is `revoked` if `syncRevoked` is set or `syncLogin` is known, otherwise `off`.
5. Sign-out deletes the local token (the gist stays). macOS leaves sign-in state intact and
   records an error if deletion fails; Linux disables the local sign-in even when deletion fails
   and reports the possibly retained token as described above.
   - «Sign out» / «Выйти» has a local-only sign-out note on both platforms, including revoked cleanup.
     Linux: «This signs out only this computer. To revoke the app's access entirely, visit github.com/settings/applications»;
     RU: «Вход удаляется только на этом компьютере. Отозвать доступ приложения полностью — github.com/settings/applications».
     The CLI prints the same note after successful sign-out.
   - macOS uses shorter wording, with the URL on the second line:
     «Signs out only this computer. Revoke app access:\ngithub.com/settings/applications»;
     RU: «Выход только на этом компьютере. Отзыв доступа:\ngithub.com/settings/applications» (`\n` = line break).
6. Neither sign-out nor confirmed local revocation calls **`POST /credentials/revoke`**.
   Deleting/disabling a local copy leaves the token alive on GitHub unless GitHub has already
   revoked it. Revoke it manually at **github.com/settings/applications**.

## Client ID

One GitHub OAuth App («Claude Codex Limits», Device Flow enabled) serves every port. Its Client ID
is public and goes into the code as `GITHUB_CLIENT_ID`; there is no client secret.

**Client ID: `Ov23lipk8voUWUAr59qS`** (OAuth App «Claude Codex Limits», owner ArrivaRUS, Device Flow enabled).
