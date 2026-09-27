# Usage sync protocol (v1)

How copies of Claude Codex Limits on different computers share **local usage** through one
private GitHub gist. This file is the contract: the macOS app (`Sources/LimitsMonitor.swift`)
and the Linux port (`linux/`) both implement exactly this. Change it only by bumping `schema`
and updating both sides.

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
- Request headers: `Authorization: Bearer <token>`, `Accept: application/vnd.github+json`,
  `X-GitHub-Api-Version: 2022-11-28`, `User-Agent: ClaudeCodexLimits`.
- **Discovery.** `GET /gists?per_page=100` (follow `Link: rel="next"`). A sync gist is one that
  contains the file `ccl-sync.json`. If several exist, use the one with the earliest `created_at`.
  If none exists, create it: `POST /gists` with `"public": false`, description
  `Claude Codex Limits — usage sync (do not edit)`, files `ccl-sync.json` and this machine's file.
  Cache the gist id locally; if it later returns 404, rediscover.
- **Manifest** `ccl-sync.json`: `{"schema": 1, "created": "<ISO-8601 UTC>", "about": "https://github.com/ArrivaRUS/claude-codex-limits/blob/main/docs/sync-protocol.md"}`.

## One file per machine

- Name: `machine-<id>.json`, where `<id>` is a random lowercase UUID v4 generated once per machine
  and kept outside the app bundle so a reinstall keeps it
  (macOS: `~/.claude-limits-monitor/machine-id`; Linux: `~/.config/claude-codex-limits/machine-id`).
- A machine writes **only its own file**, and always the **whole snapshot** (idempotent — never a
  delta), so a lost or repeated write can't double‑count.

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

## Write

- At most once every **10 minutes**, and only when the serialized snapshot changed (compare a
  hash). `PATCH /gists/{id}` with `{"files": {"machine-<id>.json": {"content": "<json>"}}}`.

## Read and merge

- `GET /gists/{id}`; for a file with `"truncated": true`, fetch its `raw_url`.
- Take every `machine-*.json` **except this machine's own id** (own data always comes from the local
  index, never from the gist). Skip files with a different `schema`, unparsable JSON, or `updated`
  older than 45 days.
- Merge = plain sum per product → day → model. Machines' transcripts are disjoint, so the sum is
  the account total for what ran in the CLIs.
- Show which machines are included and when each last reported (e.g. «2 компьютера · astra-desktop
  обновлён 10:15»).

## Errors

- `401` → the token was revoked: show «Войдите в GitHub заново», stop syncing until re‑login.
- `403`/`429` with rate‑limit headers → back off until `x-ratelimit-reset`.
- Network failure → keep the last merged result, retry next cycle. Sync must never block or break
  the limits display.

## Device Flow, step by step

1. `POST https://github.com/login/device/code` (`Accept: application/json`) with
   `client_id`, `scope=gist` → `device_code`, `user_code`, `verification_uri`, `interval`, `expires_in`.
2. Show `user_code`, open `verification_uri` in the browser.
3. Poll `POST https://github.com/login/oauth/access_token` with `client_id`, `device_code`,
   `grant_type=urn:ietf:params:oauth:grant-type:device_code` every `interval` seconds:
   `authorization_pending` → keep polling; `slow_down` → interval += 5; `expired_token` /
   `access_denied` → stop and say so.
4. `GET /user` → show `login` («GitHub: ArrivaRUS»).
5. Sign‑out deletes the local token (the gist stays).

## Client ID

One GitHub OAuth App («Claude Codex Limits», Device Flow enabled) serves every port. Its Client ID
is public and goes into the code as `GITHUB_CLIENT_ID`; there is no client secret.

**Client ID: `TBD`** — to be filled in once the OAuth App is registered.
