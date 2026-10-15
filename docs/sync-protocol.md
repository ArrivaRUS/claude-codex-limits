# Usage sync protocol (v1 · v1.1)

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
- Since v1.1 a machine may also publish limit snapshots of its own signed-in accounts — see v1.1 below.

## Transport: one secret gist

- Auth: GitHub **OAuth Device Flow**, scope `gist offline_access` for a new explicit login,
  one OAuth App shared by all ports (see *Client ID* below). Healthy legacy access-only
  credentials remain usable without a new grant. Store optional refresh and issuer lifetimes
  exactly when supplied; missing lifetime fields do not acquire a guessed expiry.
- The credential is local (macOS Keychain; Linux Secret Service or its already selected
  `0600` file backend). Rotation is pinned to the active backend; a temporary secure-store
  failure never creates a new plaintext fallback. No credential values enter prefs, gist,
  logs, stdout, argv or UI. Legacy Linux explicit-login fallback is described below.
- API request headers: `Authorization: Bearer <token>`, `Accept: application/vnd.github+json`,
  `X-GitHub-Api-Version: 2022-11-28`, `User-Agent: ClaudeCodexLimits`.
- **Token boundary.** Bearer authentication is allowed only on `https://api.github.com`:
  validate the scheme, ASCII host, port (absent or `443`) and absence of userinfo. Requests with
  Authorization do not follow redirects; `3xx` ends the cycle as an error. A truncated file's
  `raw_url` is fetched **without Authorization**, under the *raw rule* (both ports; macOS adopts it in C1):
  - `raw_url` is accepted only if it starts with exactly `https://gist.githubusercontent.com/` (ASCII, no
    spaces/control characters, no fragment); any other value is refused **before** a request;
  - redirects: at most **3** hops, each only to `https://gist.githubusercontent.com/`, GET/HEAD only; a 4th hop,
    another scheme or host, or a `Location` with control characters is refused;
  - the body of a `3xx` is never read (closed unread); a `3xx` that is not followed (including `300`/`304`/`305`)
    counts as a refused redirect;
  - a followed hop carries no `Authorization`, `Cookie` or `Proxy-Authorization`;
  - a refused `raw_url` or redirect skips that file only (*Read and merge → Refused raw transport*).
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
- `machine.name`: v1.1 writers publish a sanitized machine tag `[a-z0-9-]{1,16}` (no personal names);
  readers truncate to 16.

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
- Auth maintenance and sync scheduling are independent of **Advanced** and the Claude/Codex
  **Auto** limits schedule. macOS calls sync at startup, every 10 minutes and about **7 seconds**
  after wake. Advanced still controls local log scanning; an available cached local snapshot
  may be synced while that scan is disabled. Linux's tray schedules sync independently of
  Advanced and still services auth when the local index is stale (without pushing stale data).
- Each cycle obtains usable access from the credential owner before gist requests. A short
  issuance is renewed automatically when due, including after sleep/restart; the client does
  not have to run during sleep. Temporary dependency failures retain durable credentials and
  set finite retry/backoff (normally 60/300/600 seconds, with bounded jitter and issuer delay).
  The 10-minute cycle bounds the next normal attempt under healthy dependencies; rate-limit
  instructions may extend that pause. macOS gist transport status `0` or `5xx` also schedules
  one retry after 60 seconds; this retry does not recursively schedule another retry.
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
  `machine-<id>.json`. Each id contributes at most once. v1.1 readers also apply the string rule of
  *Read rules → Validation (C7)* to the v1 envelope (`machine.*`, `tz`, keys of `days`).
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
- **Truncated-file failure.** A `raw_url` response other than `200` (e.g. `404`, `429`, `5xx`; `3xx` is
  covered below), a network failure, or a missing/empty body fails the whole cycle as in v1: keep the
  previous remote merge/cache and do not advance the last-success time (`syncLastOkAt` / `lastOkAt`).
  macOS also fails on invalid UTF-8, recording
  `Empty or unreadable GET raw_url response`. Linux decodes nonempty bytes with UTF-8 replacement:
  invalid bytes alone do not fail the cycle; the resulting text goes through normal JSON/file
  validation and may be skipped. Invalid JSON in an otherwise readable file is a file-level skip
  on both platforms. If a truncated file has no `raw_url`, macOS fails the cycle; Linux keeps the
  inline content if present, otherwise skips it. Raw `403`/`429` uses the backoff rules below;
  raw `401` is an unauthenticated read error and never starts the token-revocation checks.
  A write already completed earlier in the cycle keeps its push hash/upload time even if reading fails.
- **Refused raw transport (file-level).** A `raw_url` outside `https://gist.githubusercontent.com/` or a refused
  redirect (*Token boundary → raw rule*) skips only that file: the other files are merged, the remote cache is
  written and the last-success time advances, but the cycle still records a visible error (Linux: `res.ok = false`,
  `lastError`; no backoff) — RU «Файл синхронизации пропущен: недопустимый raw URL или редирект», EN «Sync file skipped: invalid raw URL or refused redirect». The error text never contains
  the URL: its path is secret. Same visibility as an oversized file (*Reader limits*).
- Show which machines are included and when each last reported (e.g. «2 компьютера · astra-desktop
  обновлён 10:15»).

## Errors

- A single `401` on a gist request is **not** proof of revocation (GitHub returns stray 401s).
  Use variant **a**: `401` on the gist → `GET https://api.github.com/user`; if that is also `401`,
  pause about **4 seconds**, then repeat `GET /user` with the **same captured token**. The pause
  stays inside the serialized cycle: macOS queue `q`, Linux `file_lock("sync")`.
  - Before final rejection, a refreshable issuance gets its automatic recovery opportunity.
    Only the confirmed triple-401 chain for the still-current captured credential disables
    that access. Persist the rejection before addressed cleanup; a late operation may not
    disable a newer generation or account. A single 401 never deletes credentials.
    A usable old access may continue while renewal requires explicit recovery.
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
- **Local cache write failure** (Linux behaviour; recommended for ports). If the merged remote cache
  (`sync-remote.json`) cannot be written (disk full, permissions, read-only FS), the cycle ends with an error
  (`res.ok = false`, `lastError`) and does **not** advance the last-success time; no exception escapes the cycle.
  The error text is fixed: no exception text, no strings from remote files. The next cycle retries.
- Storage reads/writes and network operations are bounded. Locked, unreachable, timeout and
  corrupt/unreadable state are distinct from a proven missing credential and server rejection.
  Retry retains the last durable issuance; Linux never falls through to a different backend
  after a selected Secret Service read timeout.
- **V2 credential owner (both platforms).** The secure record stores the whole access/refresh
  issuance. A nonsecret manifest selects immutable generations and records login epoch,
  active ref, transition, retry time and pending cleanup. Only the serialized owner refreshes;
  Linux CLI/GUI share the process lock. Persist intent before the refresh request and stage
  the returned candidate before identity validation/publication. Restart inspects the durable
  candidate in every transition phase before sending another refresh. Cancellation, sign-out
  or a new account prevents late publication into the newer epoch.
- **Identity revalidation.** A mismatched identity never publishes another account's
  credential or totals. Automatic revalidation of a saved candidate is allowed only after
  a new successful `/user` returns the known stable ID of the current epoch. Persistent
  mismatch remains blocked. A subsequent verified match is not an account change or a new
  OAuth grant; temporary mismatch does not mandate permanent quarantine until manual login.
- **Unknown issuer result.** A timeout may mean the one-use refresh was accepted. Consult the
  saved candidate first; an unknown outcome permits at most one further issuer recovery POST.
  A proven unsent attempt does not spend that budget. If the only replacement pair was lost
  and no recovery exists, report manual sign-in rather than claiming server revocation or
  endlessly reusing the old refresh. Terminal renewal failure preserves durable evidence;
  it does not itself assert complete credential deletion. External revocation, refresh expiry
  and local credential loss remain boundaries of automatic recovery.
- **Account-bound cache.** V2 remote totals are accepted only for the current epoch/account.
  On macOS, an old unbound remote cache is excluded after restart until the first verified
  sync; local usage is retained. A healthy legacy login does not need a new grant to do this.
- **Legacy Linux token generations (compatibility path).** A Secret Service item carries a `generation` attribute; sync state
  selects `tokenGeneration` plus `tokenBackend`. Reads use only the active pair and discard a
  result if the pair changed during the read.
  - Under the sync lock: persist a fresh reference in `tokenDeletePending` → store its secret →
    verify → publish the active pair → retire
    the previous `(generation, backend)` and pending references by addressed deletion. No sweep
    deletes items by common application/service attributes; unrelated generations are left alone.
  - Failed deletions and generations of failed/timed-out Secret Service writes are retained in
    `tokenDeletePending`, deduplicated and retried on the next publication or sign-out. The newly
    published pair is excluded; cancellation deletes its reference. Secret Service intent is registered
    before starting the timed worker, file intent before writing the staged file. If no Secret Service
    write was started (including `ss_write` returning `None`), its provisional reference is removed.
  - A late `CreateItem` after timeout attempts to delete its own generation on the same connection; timeout
    during verification also triggers worker cleanup. A late delete cannot address a newer generation.
  - File fallback uses a different fresh generation in a `0600` staged file (token on the first
    line, generation on the second). Verify the staged file, then replace the main token file
    only at publication; cancellation deletes the staged generation without replacing the active file.
  - Items/files without a generation and state without `tokenGeneration` are treated as `legacy`,
    preserving existing sign-ins. Only legacy state with an unknown backend may discover a legacy
    copy across backends; legacy searches filter out newer generations. An empty generation disables reads.
    Publication still retires `(legacy, None)` even without a login, for compatibility with the existing
    regression contract. For this unknown legacy backend, an absent Secret Service counts as successful
    SS cleanup; a temporarily unreachable or timed-out service is a failure. An explicitly recorded
    Secret Service reference is not cleared merely because the service is absent.
  - Sign-out invalidates the active pair before deleting it and all pending references. With cleanup
    complete, two consecutive sign-ins leave one stored copy; sign-out leaves no tracked application
    items or token files, including staged files. After addressed deletions, sign-out always unlinks
    `github-token`, `github-token.pending-*`, and write_atomic remnants `.github-token.*` (including
    staged-file temporaries), only in `CONFIG_DIR`, without recursion or following symlinks. Any unlink
    failure except an already missing name prevents success and retains a file cleanup reference for retry.
    Failed addressed deletions remain pending. Unknown Secret Service generations are not swept.
  - Unconfirmed writes have no separate age/attempt retention policy yet: a successful empty SS deletion
    can clear their pending reference. Late writes must finish their cleanup before the no-copies invariant
    holds; if the process dies and an empty deletion precedes the late `CreateItem`, that copy can escape
    subsequent cleanup. Pre-registration covers a late item already present at the next sign-out.
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
   `client_id`, `scope=gist offline_access` → `device_code`, `user_code`, `verification_uri`, `interval`, `expires_in`.
2. Show `user_code`, open `verification_uri` in the browser.
3. Poll `POST https://github.com/login/oauth/access_token` with `client_id`, `device_code`,
   `grant_type=urn:ietf:params:oauth:grant-type:device_code` every `interval` seconds:
   `authorization_pending` → keep polling; `slow_down` → interval += 5; `expired_token` /
   `access_denied` → stop and say so.
4. Save the full candidate issuance to the selected protected store before identity validation.
   Require `GET /user` to return `200` with valid identity before publishing the active login.
   Publish only a current, noncancelled epoch/attempt; the final check shares serialization
   with begin/cancel/logout. Late A cannot overwrite B; addressed cleanup remains pending
   if the store cannot prove deletion. Optional refresh and expiry are kept with access.
5. Sign-out is local-only: persist the disabled epoch/tombstone, then attempt addressed cleanup
   of access, refresh and known candidate/probe copies. The gist and other computers remain.
   An incomplete physical deletion is reported as cleanup pending; it is not called a complete
   deletion. If disabling state itself cannot be saved, report failure. Only explicit login
   starts a new session; queued refresh/login results cannot resurrect the signed-out epoch.
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

## Usage sync protocol v1.1 — account limits (additive)

**Why.** Only a machine signed in to an account can read its limits; v1.1 lets it publish them and attributes usage to accounts.

### Compatibility

- `schema` stays the integer `1`; the manifest is unchanged. Every v1.1 key is optional. Raising `schema` is
  forbidden: v1 readers (macOS ≤ 3.2.7, Linux ≤ 0.4.5) would drop the whole file and lose its usage.
- Linux `sync.merge()` (`linux/ccl/sync.py` 355–402) reads only `schema`, `machine.{id,name,os,app}`, `updated`, `tz`, `days`.
- macOS `GitHubSync.merge` (`Sources/LimitsMonitor.swift` 2740–2775) reads the same keys via `as?`; others are never looked up.
- The root `days` stays the whole machine's usage: per product it **equals** Σ `accounts[*].days` of that product +
  `unattributedDays[product]`, a projection for v1 readers. A v1.1 reader sums **either** that split **or** the root.
- Both ports test it: a v1.1 fixture through the **old** merge gives the same result as that fixture without v1.1 keys.

### File shape

```json
{ "schema": 1, "machine": {"id": "5f0c…", "name": "vps", "os": "Ubuntu 26.04", "app": "linux 0.5.0"},
  "updated": "2026-10-12T10:15:03Z", "tz": "Etc/UTC", "lastSeenAt": "2026-10-12T10:15:03Z",
  "days": { "claude": { "2026-10-12": { "claude-fable-5-1": {"input": 1200, "output": 3400, "cacheRead": 900000,
                                                            "cacheWrite5m": 0, "cacheWrite1h": 52000, "turns": 41} } },
            "codex":  { "2026-10-10": { "gpt-6-astra": {"input": 1, "output": 1, "cacheRead": 0,
                                                        "cacheWrite5m": 0, "cacheWrite1h": 0, "turns": 1} } } },
  "accounts": [
    { "product": "claude", "label": "3f9a0c71b2d4e5f6", "plan": "max", "tier": "default_claude_max_20x",
      "status": "ok", "asOf": "2026-10-12T10:15:02Z", "attemptAt": "2026-10-12T10:15:00Z", "attemptKind": "auto",
      "windows": { "session": {"pct": 42.5, "resetAt": "2026-10-12T13:00:00Z"},
                   "weekly":  {"pct": 61.0, "resetAt": "2026-10-15T07:00:00Z"} },
      "models": [ {"name": "Fable 5.1", "pct": 70.2, "resetAt": "2026-10-15T07:00:00Z"} ],
      "schedule": { "mode": "auto", "interval": 900, "nextAt": "2026-10-12T10:30:00Z", "backoff": false }, "retryUntil": null,
      "days": { "2026-10-12": { "claude-fable-5-1": {"input": 1200, "output": 3400, "cacheRead": 900000,
                                                     "cacheWrite5m": 0, "cacheWrite1h": 52000, "turns": 41} } } },
    { "product": "codex", "label": "a1b2c3d4e5f60718", "plan": "pro", "status": "expired", "expiredReason": "cli_refresh_pending",
      "asOf": "2026-10-12T06:40:11Z", "attemptAt": "2026-10-12T10:15:00Z", "attemptKind": "auto",
      "windows": { "session": {"pct": 12.0, "resetAt": "2026-10-12T11:40:00Z"} }, "resetCredits": 2,
      "schedule": { "mode": "auto", "interval": 3600, "nextAt": "2026-10-12T11:15:00Z", "backoff": true },
      "days": { "2026-10-10": { "gpt-6-astra": {"input": 1, "output": 1, "cacheRead": 0,
                                                "cacheWrite5m": 0, "cacheWrite1h": 0, "turns": 1} } } }
  ],
  "unattributedDays": {},
  "captions": { "3f9a0c71b2d4e5f6": { "text": "команда", "setAt": "2026-10-12T09:00:00Z" } } }
```

- `accounts[].days` has no product level (the record's `product` is it); `unattributedDays` has the full root `days`
  shape. Counters follow v1 (six integers, 0…10^15).
- **Day attribution.** The usage index stores `accountByDay[product][day]` = the local identity active when that day's
  lines were first indexed; it never changes later. Days with no known identity go to `unattributedDays`.

### Field rules

| Field | Type | Bounds | Required |
|---|---|---|---|
| `lastSeenAt` | time | heartbeat, see *Write rules* | v1.1 writers: yes |
| `accounts` | array of records | ≤ 8 records | no |
| `unattributedDays` | object, root `days` shape | v1 counters | no |
| `captions` | object `label → {text, setAt}` | ≤ 64 keys, key = 16 hex, `text` ≤ 32 chars | no (Should) |
| `product` | string | `claude` · `codex` | yes |
| `label` | string or `null` | 16 lowercase hex | yes (`null` allowed) |
| `labelReason` | string | `no_login` · `no_account_uuid` · `unreadable` · `no_gist` | when `label` is `null` |
| `status` | string | `ok` · `signed_out` · `expired` · `rate_limited` (writer holds its **own** `retryUntil` in the future, after 429 / Retry-After) · `error`; `stale` is reserved: v1.1 writers never set it, readers judge freshness from `asOf`/`schedule` (V4) | yes |
| `expiredReason` | string | `cli_refresh_pending` · `signin_required` | with `expired` |
| `plan`, `tier` | string | ≤ 64 chars | no |
| `asOf` | time | last **successful** API response; absent until this account's first success | no |
| `attemptAt` | time | last attempt; the only name (`lastAttemptAt` is not used) | no |
| `attemptKind` | string | `auto` · `activity` · `manual` · `initial` | with `attemptAt` |
| `windows.session`, `windows.weekly` | `{pct, resetAt}` | `pct` finite number 0…100, not boolean | no, each |
| `models` | array of `{name, pct, resetAt}` | ≤ 8; `name` ≤ 48 chars | no |
| `resetCredits` | integer | 0…1000 (Codex) | no |
| `schedule` | `{mode, interval, nextAt, backoff}` | `mode` `auto`·`fixed`; `interval` 900·1800·3600·14400 s; `backoff` boolean; `nextAt` = own last attempt + `interval` — the writer's cadence only, **never** its provider deadline (that goes only to `retryUntil`) | no |
| `retryUntil` | time or `null` | the provider's deadline (429 / Retry-After) | no |
| `days` (record) | day → model → counters | v1 counters | yes, may be `{}` |

Size: ≤ 4 KB of metadata per record (without `days`); file ≤ 8 MiB; above 1 MB the API truncates it → `raw_url` (v1).
No values are invented (no default zeros): without a login there is no reading, only a status. All times are ISO-8601
UTC; strings are shown only as plain text.

### Account label

- **Local identity** (never leaves the machine): Claude — `~/.claude.json` → `oauthAccount.accountUuid` (the parser
  extracts only this key; file limit 8 MB, excessive nesting rejected); Codex — `~/.codex/auth.json` → `tokens.account_id`
  (`id_token` is not read). Re-read on **every** pass. `organizationUuid` is **not** a fallback: it is shared by all
  members of an organization.
- **Label** = `hex(HMAC_SHA256(K, "ccl-account-v1|" + product + "|" + localId))[:16]`, `K = SHA256("ccl-label-key-v1|" + gist_id)`.
  `localId` is normalized (trimmed, lowercased) before HMAC so two machines give one label for one account.
  After normalization it must match `^[0-9a-z-]{8,64}$`; otherwise there is no label: `label: null`,
  `labelReason: no_account_uuid` (status `error`).
- The label is computed **only** when the block (or a log line) is built, under the gist id current at that moment. No
  local store keeps labels: the usage index, caches and publisher state are keyed by `localId`.
- No label → `label: null`, **no provider request**, no values: `no_login` (no login file/block) → `signed_out`;
  `unreadable`, `no_account_uuid`, `no_gist` (no gist id) → `error`. Token rotation without a new `localId` keeps the label.
- **Account change** = a new `localId`: new snapshots and usage go under the new label; earlier usage stays under the old
  one; the old account's cached values are not reused. If `localId` differs after the request, the result is discarded.
- **Known limitation.** `oauthAccount` is Claude Code's profile cache and may lag a newly signed-in account; the label
  stays the old one during the lag.
- **Gist switch** (convergence on the earliest gist, or the owner recreating it): every label changes at each machine's
  next build after its own discovery — up to 24 h apart, so duplicate cards may appear for ≤ 1 day. Reader settings
  keyed by label (hidden accounts, `captions`, menu account) fall back to defaults. Rare by design.

### Write rules

- A machine publishes only fresh API readings of **its own** accounts; other machines' records are never republished.
- **Three fingerprints** (`sync-state.json`), each decides independently; if none is due, no PATCH:
  1. `pushHash` = sha1(root `days`) — usage: on change and `now − pushedAt ≥ 570 s` (the v1 floor);
  2. `metaHash` = sha1(`accounts` without `days` + `captions`) — attempt, result, schedule, `retryUntil`, status, label,
     caption: on change, **no floor**;
  3. `heartbeatAt` — `lastSeenAt`: when `now − heartbeatAt ≥ 600 s` in automatic mode.
- Any PATCH writes the whole file (current `days`, `accounts`, `captions`, `lastSeenAt = updated = now`) and updates all
  three. `lastSeenAt` is part of the snapshot but of no fingerprint. A heartbeat moves only `lastSeenAt` and `updated`:
  never `asOf`, the attempt or the schedule; two non-due ticks within 600 s give 0 PATCH. `updated` moves on **every**
  PATCH, heartbeat included: v1 readers drop files by its 45-day age, so the heartbeat keeps the machine alive for them too.
- **Order on a polling tick** (publisher pass, Linux `file_lock("quota")` → `file_lock("sync")`, wait ≤ 60 s):
  1. one validating `GET /gists/{id}` (`public == false`), merge other files, coordination decision (*Read rules*);
  2. save the attempt locally first; if it can't be saved → no request;
  3. **PATCH №1** with the new `attemptAt`. Any failure (non-2xx, network, 404) → restore the previous attempt time,
     **no provider request** (skip `publish_failed`); the next tick retries. **Series limit:** the 1st and 2nd
     consecutive `publish_failed` ticks skip; the 3rd consecutive one polls on its own schedule without the
     announcement, as when the gist is unavailable (silent data loss ≤ 10 min; neighbours are not visible then —
     the same tolerance as «gist unavailable»);
  4. provider request;
  5. **PATCH №2** with the result (status, `asOf`, values, `retryUntil`, schedule).
  Both PATCHes reuse the one GET within **120 s**; PATCH 404 clears the gist id and hash as in v1; no discovery in between.
  If the GET fails, nothing is announced: the machine polls on its own schedule and publishes on the next good pass.
- **Budget:** a polling tick ≤ 1 GET + 2 PATCH; any other tick 1 GET + ≤ 1 PATCH. VPS with both products at 15 min:
  288 GET and ≤ 528 PATCH a day. Worst case for three machines ≈ 34 GET/h and ≈ 50 PATCH/h, i.e. 1.7 % of the core
  5000/h and 10 % of the 500/h content-creating limit. Reads still happen every cycle, as in v1.

### Read rules

- **Validation (C7).** Records are validated one by one; a broken `accounts` block never affects the file's `days`
  (v1 rules), and one bad record never stops the merge.
  - No `status`, `product` missing or not `claude`/`codex` → record dropped; unknown `status` → `error`; `label` not 16 hex → `null`.
  - `pct` not a finite number (string, boolean, NaN/Infinity) or outside 0…100 → that window dropped.
  - Unparsable time → that field dropped; a broken `asOf` leaves the record without a reading.
  - `models` > 8 → tail dropped. A string containing control/format characters or a lone surrogate (`Cc`/`Cf`/`Cs`,
    i.e. not encodable as UTF-8) is dropped **whole** (never cleaned); a string over its limit is dropped.
  - The same rule covers the v1 envelope: `machine.id` → file skipped; `machine.name/os/app` → field dropped
    (`os`/`app` over 64 are dropped, `machine.name` is checked, then truncated to 16); `tz` → dropped, also over 64;
    a product, day or model key of the root `days` → that entry skipped.
  - Duplicate `(product, label)` in one file → the record with the latest `asOf`. `captions`: the latest `setAt` wins.
  - `asOf` more than 5 min in the future → shown with age 0, no pace or forecast.
- **Reader limits (both ports)** act on the **file**, never on the cycle, so one hostile file can't stop sync (T1).
  Hitting any limit below still records a visible error («слишком большой ответ/файл синхронизации», Linux:
  `res.ok = false`, `lastError`; no backoff), while the other files are merged, the remote cache is written and the
  last-success time advances:
  - a `raw_url` body (or inline content) over 8 MiB: reading stops at cap + 1 byte and that file is skipped like
    invalid JSON in v1 (Linux `_raw`/`common.http` take a body cap);
  - more than 64 `machine-*.json` files: the first 64 by file name are taken, the rest ignored. This machine's own
    file occupies one of the 64 slots (it is selected first, then excluded from the merge);
  - more than 64 MiB in total (inline contents plus raw bodies, counted as wire bytes): each raw read gets the
    remaining budget as its cap, `min(8 MiB, 64 MiB − already read)`; a rejected body counts as cap + 1 bytes.
    Once the budget is spent no further files are read; files already read are merged;
  - `accounts`: only the first 64 raw array elements are examined; of them at most 8 valid records (after dedup) are kept.
  - **Refused-raw cache** (`sync-state.json` → `rejectedRaw`): a `raw_url` refused for its transport/redirect or for
    exceeding 8 MiB is stored as the first 16 hex chars of sha256(URL) → refusal time (epoch s). While the entry is
    present that file is skipped without a download (visible error as above). Entries live 24 h; at most 64 (the
    oldest is evicted). The URL itself is never stored. On disk, because each headless tick is a new process.
  - Known limitation (Linux; fix planned in A3): the gist `GET /gists/{id}` itself is capped at 16 MiB; a larger response fails the
    whole cycle, not one file.
- Grouping: one card per `(product, label)` across machines, own included; the latest successful `asOf` wins (a tie →
  local). The usage of a `null` label goes to «<Product> · account not specified». **Projection mismatch:** if a
  product's root `days` ≠ Σ its `accounts[*].days` + `unattributedDays[product]`, the whole root usage of that product
  goes to «account not specified» and that product's account `days` are **not** added — no double count.
- A source machine is offline when its `lastSeenAt` is older than 30 min. Files without `lastSeenAt` fall back to
  `updated`: they come from older writers without limit snapshots, so the offline card state does not apply to them.
  Links on remote cards are product constants, never taken from the file.
- **Trust in other machines' fields** — they may only **postpone** my polling, never make it more frequent than my Auto.
  Coordination runs only when my own schedule is due; it considers other machines' records for my `(product, label)`.
  Below, `now` is local time, `I` my interval, `I′` the other record's `schedule.interval` if it is one of 900 · 1800 ·
  3600 · 14400, otherwise 14400. All bounds are in seconds.
  - **Liveness** (the record takes part in coordination at all): its file's `lastSeenAt` is present, parsable and within
    `now − 1800 ≤ lastSeenAt ≤ now + 60` (`now + 60` itself is alive). Missing, broken, older or further in the future →
    **not alive**: it suppresses nothing, takes no part in the tie-break, and its `retryUntil` is not accepted (a
    previously accepted one still holds, see the chain below).
  - **Freshness** (an alive record is dropped **as a whole** if any holds; display rules above still apply):
    `asOf > now + 60`; `attemptAt > now + 60`; `asOf > attemptAt + 60`; `nextAt > now + I′ + 60`. A future `nextAt`
    within `I′ + 60` is normal. A single unparsable time is treated as absent, not as a reason to drop.
  - **Meaning of `nextAt`:** the writer's last attempt + its interval (*Field rules*). A writer never folds its own
    provider deadline into `nextAt`; that deadline travels only in `retryUntil`. (Folding it in would push `nextAt`
    past `now + I′ + 60` after a long Retry-After and make neighbours drop the very record that should stop them.)
  - Order of checks: `retry_after` > `remote_attempt` > `fresh_remote` > `tie_break` > poll.
  - `retry_after`: my own `retryUntil` (no cap) or an accepted foreign deadline (below) is in the future → skip.
  - `remote_attempt`: another machine's `attemptAt` younger than 900 + 60 s → skip (a failed attempt counts too).
  - `fresh_remote`: its `status = ok` and `asOf` younger than `I + 60` → skip.
  - **Foreign `retryUntil` chain.** Accepted only from fresh, alive records with `retryUntil > now`; the latest such
    deadline is taken; while it is in force it is not replaced, and at its expiry the next foreign deadline (if any)
    continues the chain. It is stored apart from my own deadline as `{until, firstSeenAt}` (Linux:
    `publisher-state.json` → `remote_retry`) and honoured until `min(until, firstSeenAt + 24 h)`. Repeats, heartbeats
    and restarts don't move `firstSeenAt`.
    - A newly accepted deadline **inherits** `firstSeenAt` (the same chain, one 24 h cap) only if the previous
      effective deadline `min(until, firstSeenAt + 24 h)` is still in force or expired ≤ 900 s ago, and I have not
      polled since (my last attempt < the previous `until`). Otherwise a **new chain** starts with `firstSeenAt = now`.
      So a neighbour republishing `retryUntil = now + 23 h` every tick cannot suppress me for more than 24 h, and a
      chain broken by > 900 s without deadlines cannot make a fresh 429 elsewhere trigger an immediate poll.
    - When the cap fires, the stored value becomes the **cap marker** `until = firstSeenAt + 24 h`, the event
      `remote_retry_capped` is logged and my own schedule resumes. The marker is kept even if the source disappears,
      so a heartbeat, a changed deadline or a restart cannot arm another 24 h in the same chain. It is cleared when my
      last attempt ≥ `firstSeenAt + 24 h`. The marker also counts as «the previous effective deadline»: if it expired
      > 900 s ago without my poll, the next foreign deadline starts a new chain.
    - Edge case: a normal deadline that ends exactly on the cap is treated as the marker — no `remote_retry_capped`,
      and I poll.
    - My own Retry-After has no cap. Invariant: ≥ 1 own request per 24 h.
  - **Tie-break** (`tie_break`): an alive, fresh record whose `nextAt` is within ±60 s of my due time
    (`last attempt + I`), whose source is alive within 15 min (`lastSeenAt ≥ now − 900`) and whose `machine.id`
    matches `^[A-Za-z0-9-]{1,64}$` and is lower than mine (plain string comparison) → I skip once per
    `(machineId, nextAt)` (Linux: `tie_wait`), then poll. With several candidates the lowest pair wins. A record whose
    `machine.id` fails the form never tie-breaks, but every other rule still applies to it; readers do **not** drop
    such files for coordination (a Mac id may be upper-case, fixtures may be shorter than 8 chars).
  - Manual refresh: only `retry_after` and `remote_attempt` apply (≥ 960 s after another machine's `attemptAt`, never
    before any `retryUntil`), plus my own ≥ 900 s floor.
- **Clocks.** Skew = GitHub's `Date` header − local time, sampled on every GitHub response (errors included) and kept
  in `sync-state.json` as `clockSkew` (seconds, signed) and `clockSkewAt` (local epoch of the sample). The 60 s margins
  assume |skew| ≤ 60 s; above that the machine logs `clock_skew`, shows it in status, and no coordination guarantee is
  claimed (no auto-correction; use NTP).

### Publisher journal (O1, Linux)

Private, headless event log `$XDG_STATE_HOME/claude-codex-limits/publisher.jsonl` (default `~/.local/state/…`;
directory 0700, file 0600, append-only, one JSON object per line with `ev` and `ts`). Values are enumerations,
16-hex labels, numbers or an exception **class name** — never identifiers, URLs, paths or error text. The allow-list
lives in `linux/ccl/common.py` (`O1_EVENTS`, `O1_SKIP_REASONS`, `_O1_ENUMS`); an unknown event or field raises.

| Event | Fields | When |
|---|---|---|
| `poll_attempt` | `product`, `kind` (`auto`·`manual`), `attemptAt` | provider request about to be made |
| `poll_result` | `product`, `httpStatus`, `result` (`ok`·`failed`) | provider answer accepted |
| `poll_skipped` | `product`, `reason` | product not polled on this tick; `reason` ∈ `not_due` · `fresh_remote` · `remote_attempt` · `tie_break` · `retry_after` · `no_github` · `no_login` · `no_label` · `state_unsaved` · `publish_failed` · `token_policy` · `busy` |
| `pass_skipped` | `reason` = `busy` | the whole pass skipped: the `quota` lock was not obtained within 30 s |
| `pass_failed` | `class` | unexpected exception ended the pass (class name only) |
| `publish` | `result` (`ok`·`failed`) | machine-file PATCH outcome |
| `accounts_days_dropped` | `reason` = `counter_overflow` | `accounts[].days` omitted from the file (overflow); root `days` still published |
| `token_refresh` | `product`, `credentialWrite` (1), `policy` (`guarded`) | token rotation written to the CLI credentials |
| `policy_forced_never` | `policy` = `never` | `guarded` overridden to `never` because the machine is a publisher (logged once per transition) |
| `policy_violation` | `product`, `policy` = `never` | a credential write was attempted under `never` and refused |
| `pending_rotation_lost` | `product` | a pending rotated token pair was not saved, or its rotation marker could not be removed |
| `remote_retry_capped` | `product` | a foreign `retryUntil` chain hit its 24 h cap |
| `label_changed` | `product` | the account label for a product changed |
| `identity_changed` | `product` | the CLI sign-in changed during a pass; the reserved attempt is not used for the new account |
| `clock_skew` | `seconds` (signed skew) | absolute skew (GitHub `Date` − local) > 60 s |

### Privacy

- Only the fields above go into the file. **Never**: tokens or their fingerprints, `id_token`/JWT (`eyJ…`), `scopes`,
  `refreshTokenExpiresAt`, `OPENAI_API_KEY`; email, names, `accountUuid`, `account_id`, `organizationUuid` or any UUID
  other than `machine.id`; prompts, paths, project names, full hostnames; error texts (only the enumerated status).
- `machine.name` is a sanitized tag (NFKD → ASCII, lowercase, `[a-z0-9-]`, ≤ 16; empty → `mac`/`linux`); the publisher
  sets it explicitly (`--name vps`). `tz` stays (v1).
- Writer, captions and `models[].name`: a string containing `@`, `/` or `\` is dropped **whole** before truncation
  (never cleaned). The check runs after NFKC, so fullwidth `＠`/`／`/`＼` are refused too. The published text drops
  `Cc`/`Cf` and is NFC-normalized.
- A scan test checks published files and publisher logs by values with an allow-list of keys and enum values (so
  `cli_refresh_pending` passes): email, `account_id`, `accountUuid`, `refresh`, `access_token`, `sk-`, `/home/`, `/Users/`.
- Old revisions keep v1 `machine.name` values; only recreating the gist removes them (all labels then change).

### Platform differences

- **Linux headless publisher** (VPS, P0): `ccl-sync push --auto` on a 5-min systemd timer, both products, the order
  above. `credential_write: never` by default: with an expired token it publishes `expired` + `cli_refresh_pending`
  and the last values, without refreshing. A tray on the same machine runs `delegated` (no polling, `allow_push=False`).
- **macOS** (P0): reader (one card per label, states from `lastSeenAt`/`retryUntil`/`asOf`) and publisher of its own
  Codex account; coordination via `syncNow(mode:completion:)`, `.writeOnly` PATCH against a gist validated by a GET
  ≤ 120 s ago; no completion within 60 s counts as a failed read. Cycles stay at 10 min plus a read before polling.
- **Second queue:** the Linux tray as a v1.1 reader (account cards) and as a publish-only tray; Linux `reader_card_state` logging.
