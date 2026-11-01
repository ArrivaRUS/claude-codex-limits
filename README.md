# Claude Codex Limits

**English** · [Русский](README.ru.md)

<p align="center">
  <img src="docs/banner.png?v=314" alt="Claude Codex Limits — macOS menu bar usage limits" width="820">
</p>

A tiny macOS menu-bar app that shows how much of your **Claude Code** and **Codex**
usage limits you have left — at a glance, right in the top tray.

Each row shows `session% / weekly%` by default (the rolling 5‑hour window and the 7‑day
window), with the product's icon to its left — and you decide which two numbers those are.
Click the tray icon for a detailed popover.

<p align="center">
  <img src="docs/menubar-dark.png?v=314" width="180" alt="Menu bar (dark)">
  &nbsp;&nbsp;
  <img src="docs/panel-en.png?v=314" width="320" alt="Popover">
</p>

## Limits from other computers

**New in [macOS 3.4.0](https://github.com/ArrivaRUS/claude-codex-limits/releases/tag/v3.4.0) and [Linux 0.5.0](https://github.com/ArrivaRUS/claude-codex-limits/releases/tag/linux-v0.5.0).**

Only a machine where the Claude Code or Codex CLI is signed in can read that account's limits. If your agents work on a VPS or another laptop, the Mac used to show only its own subscriptions. Now every machine signed in to the same GitHub account publishes the limits and usage of its own accounts to your secret gist. The Mac shows **limits and spending from all machines in one window**, including a subscription that is not signed in on the Mac at all.

### Turn it on

1. **On the Mac.** Open Settings → **Other computers · via GitHub** (in both Simple and Advanced view), click **Sign in with GitHub** and enter the code at github.com/login/device. The first machine creates a secret gist; every machine signed in to the same GitHub account uses the same gist.
   Under **Poll on this computer**, keep on only the products whose CLI is signed in on this Mac. When a product is off, this Mac does not read its sign-in or logs and does not request its limits; accounts from other computers stay visible. Example: with no Claude subscription on the Mac, turn Claude off — the Claude card from the VPS still appears.
2. **On each Linux server or laptop that should publish (the publisher).** Sign in to the Claude Code and/or Codex CLI there, then install from a checkout of the release and sign in to the same GitHub account:
   ```sh
   git clone --branch linux-v0.5.0 https://github.com/ArrivaRUS/claude-codex-limits.git
   cd claude-codex-limits
   sh linux/install.sh --publisher --no-tray --name vps
   ccl-sync login --no-browser
   ccl-sync status
   ```
   - `--name` is the short machine tag shown on the Mac: lowercase ASCII letters, digits and hyphens, 1–16 characters, no leading or trailing hyphen (e.g. `vps`, `alse`).
   - `--no-tray` is for a server without a desktop. `ccl-sync login --no-browser` prints a code; open github.com/login/device on any device.
   - A publisher keeps its GitHub token **only in a file with permissions `0600`** under `~/.config/claude-codex-limits/`, not in a desktop keyring. `ccl-sync login` prints where.
   - The installer refuses while this user's tray app is running: a tray and a publisher on one machine would poll twice. Do not start the tray on that machine afterwards.
   - A systemd user timer checks every 5 minutes. Actual requests to Anthropic/OpenAI follow Auto (15 minutes up to 4 hours) or a fixed interval, plus coordination with other machines. Nothing is polled before the GitHub sign-in.
   - **Tokens are read-only.** The publisher never refreshes OAuth tokens or rewrites the CLI credential files. When a CLI sign-in expires, it publishes that the machine is waiting for the CLI to renew it, together with the last values and their original time.

   Commands, modes and rollback: [Linux publisher guide](linux/README.md#режим-издателя-сервер-без-трея) (in Russian).

Machines on older versions (macOS ≤ 3.2.7, Linux ≤ 0.4.5) keep syncing usage with newer ones; they publish no limits and show no account cards. The Linux tray app 0.5.0 also shows no cards from other machines; it shows account captions in `ccl-sync status` and its tooltip.

### What you see on the Mac

**One account on several machines means one card**, for example `Codex · macbook, vps`; different accounts get separate cards. Values come from the most recent successful reading on any machine; equal reading times favour this Mac. A failed local poll does not hide a newer successful reading from another machine. An older local failure with a known attempt time no later than that success also stops showing a warning and Retry; a newer failure or one with an unknown time keeps them.

In Simple view, machine names sit below the title, with a freshness dot for each source. Advanced shows the dots beside the machine names after the plan badge. Both views keep source times in the header tooltip and accessibility labels; there is no separate source/time line. Each dot uses **that machine's own reading time**:

- **Green:** no older than its polling interval plus 15 minutes, including the boundary.
- **Amber:** beyond that allowance, but no older than 24 hours.
- **Red:** older than 24 hours.
- **Grey:** no reading yet.

The interval is this Mac's current fixed/Auto interval or the other machine's published schedule; if unavailable, it is 4 hours. Hover over the header for each source's time and freshness in words. An amber `macbook` beside a green `vps` is normal: while another machine polls the same account freshly, coordination can postpone this Mac's own poll. The card still uses the freshest successful values.

Separately from the dots, a card says when its source machine has not reported for more than 30 minutes, when that machine needs its CLI sign-in renewed (the advice is about that machine, not this Mac), when the provider asked to wait, or when this Mac's own GitHub sync is stalled. The last values stay visible with their age.

- **Refresh now** on a card whose account is not signed in on this Mac only re-reads GitHub (30-second guard); the Mac never asks Anthropic or OpenAI about such an account.
- **Coordination.** When one Codex account is signed in on the Mac and on a server, a machine skips its own request while another machine has just polled that account, so the account is not polled twice within 15 minutes. A provider's Retry-After is honoured by every machine of that account (a deadline received from another machine for at most 24 hours).
- **Menu bar.** It shows the account signed in on this Mac, otherwise the first account of that product. With two or more accounts of a product, pick one in Settings → **In the menu bar**.
- **Accounts.** Settings → **Accounts** lists every account; you can hide a card on this Mac or edit its label with the pencil. The editor starts with the current label selected. Labels allow up to **32 Unicode scalars**, without `@`, `/` or `\` (including their fullwidth forms); line breaks and control characters are removed. Enter saves, Esc cancels; an empty label or **Reset** restores the default. Labels sync between machines, with the latest edit winning.
- **Auto.** Fresh successful readings of the same account from another machine can restore the 15-minute interval when comparable usage grows by at least 1 percentage point per 15 minutes. This does not bypass coordination or a server retry deadline.

### History & money (Advanced)

<p align="center"><img src="docs/advanced-en.png?v=340" width="320" alt="Advanced view with cards from two machines and History & money by subscription"></p>
<p align="center"><sub>Advanced: the Claude card comes from <code>vps</code>, the Codex card from <code>macbook</code> and <code>vps</code>; History & money has one tab and one row per subscription. Preview on test data.</sub></p>

**One subscription per product.** History & money has one tab and one table row for each subscription — Claude and/or Codex. Usage from all machines is added into that subscription as one sum, with no per-machine split. The name is your label, otherwise `<Product> <plan>`, such as `Claude Max` or `Codex Pro`.

The subscription price is the one you set in Settings; otherwise it follows the published plan (for example, Claude Max 20x — $200 a month). A price the app can only guess is marked `≈` and has a pencil that opens Settings. Without a set price and without plan information there is no subscription price or value ratio. Usage from older machines without account information is included in the same product total.

### What goes to the gist — and what never does

- **Usage:** daily token totals per product, day and model for the last 45 days, as before.
- **Limits from publishers (Mac: its Codex account; Linux publisher: Claude and Codex):** an account label derived with HMAC from the account ID and the gist, plan, limit percentages and reset times, per-model weekly limits, Codex reset credits, the times of the last successful reading and of the last attempt, a status from a fixed list, the polling schedule, a provider retry deadline and a heartbeat.
- **Your account labels** (captions), and machine metadata: a random machine ID, the short tag, OS and app version, time zone.
- **Never:** prompts, tokens or their fingerprints, e-mail, names, raw account or organization IDs, file paths, project names, full hostnames, error texts.

A secret gist is unlisted, not encrypted: anyone with its URL can read it. Never share the gist URL: it is a read access key. `ccl-sync status` hides it by default; only `ccl-sync status --show-gist` prints the full URL. Old gist revisions may retain earlier machine names. Field-level contract: [sync protocol v1.1](docs/sync-protocol.md#usage-sync-protocol-v11--account-limits-additive).

Programs running as your user can read the GitHub token; it grants access to all your gists.

### Turn it off and delete the data

- **Mac:** Settings → **Other computers · via GitHub** → **Sign out**. The Mac stops reading and publishing; cards of accounts not signed in on this Mac disappear. Sign-out affects this Mac only; the gist and other machines stay.
- **Pause a Linux publisher:** `ccl-sync publisher --disable` stops limit polling (usage sync continues). To stop everything, run `systemctl --user disable --now ccl-sync.timer`, then `systemctl --user stop ccl-sync.service`.
- **Remove a Linux publisher:** stop the timer and service as above, then `sh linux/uninstall.sh` (keeps settings and state) or `sh linux/uninstall.sh --purge` (also signs this machine out of GitHub and deletes its settings, state and publisher journal).
- **Delete data in GitHub:** uninstalling leaves the machine's file `machine-<id>.json` in the gist. Delete it in the gist on github.com after that machine has stopped; a running machine writes it again. To remove everything, including revision history, sign out on every machine first, then delete the gist: a machine that is still signed in creates a new gist at its next sync.
- **Revoke the app's GitHub access:** github.com/settings/applications. Signing out does not revoke it.

## Release history — Linux 0.4.5: compact refresh

**Published:** [Linux 0.4.5](https://github.com/ArrivaRUS/claude-codex-limits/releases/tag/linux-v0.4.5), source `19440ee112f164b411bf4715d6fa65077a272c48`. CI, independent reviews and package QA passed; see the [verification report](docs/linux-compact-refresh-verification.md). macOS 3.2.7 was Latest at the time. Release sections below retain their historical behavior.

With the required CLI signed in and the desired subscriptions enabled in Settings, open Simple or Advanced view. Use the small refresh icon beside Settings in the existing header; read compact request status and data time inside each provider card, with details in its tooltip.
Choose **15 min / 30 min / 1 h / 4 h** for fixed polling, or **A** for Auto. Auto highlights A and the actual intervals of enabled providers together: different intervals highlight both segments; disabled providers do not contribute. With both subscriptions off, no interval is highlighted; A can remain selected if Auto is saved. There is no separate frequency label or **Pace from snapshot at…** annotation; forecasts and relevant access/data warnings remain.

Manual refresh bypasses the local Auto/fixed schedule and error backoff while keeping the selected mode. Each provider has a 30-second guard and at most one request in flight; results appear independently, and a failed provider can be retried on its own. Actual server Retry-After deadlines still apply. An unchanged live response counts as success; fallback retains the old reading time. Sign-in problems show guidance for the affected CLI without automatic login or permission prompts; macOS Keychain permits are not part of the Linux flow.
Use the DEB from **linux-v0.4.5**, published without Latest. [RU/EN release notes and installation steps](docs/linux-compact-refresh-release.md).

## Release history — macOS 3.2.7: compact refresh

[Download macOS 3.2.7](https://github.com/ArrivaRUS/claude-codex-limits/releases/tag/v3.2.7).
Click the refresh icon beside Settings (tooltip: **Refresh now**); status and actions fit inside each card, with times shown without seconds in its tooltip.
On macOS 3.2.7, choose a fixed interval of **15 min / 30 min / 1 h / 4 h**; Linux 0.4.4 keeps its three choices, without fixed 4 h.
In Auto, **A** and the actual interval segments are highlighted together; different Claude/Codex intervals highlight both segments, with the service mapping in the tooltip.
There is no separate frequency label to the right of A. The **Pace from snapshot at…** line is removed; forecasts still use the reading time.
Manual refresh, the 30-second guard and server retry deadlines keep their 3.2.6 behavior. [Release notes](docs/compact-refresh-release.md).

## Release history — macOS 3.2.6: manual refresh

[Download macOS 3.2.6](https://github.com/ArrivaRUS/claude-codex-limits/releases/tag/v3.2.6).
Released 2026-10-07. Linux remains at 0.4.4.

With at least one subscription enabled in Settings and that CLI signed in, open
the panel and click **Refresh now** in its header, in Simple or Advanced view.
It requests fresh limits for each enabled service without waiting for the Auto
or fixed interval, including after a local network-error pause. Your chosen
polling mode stays selected. Opening the panel in Auto still follows the schedule.

- Each service shows **Refreshing…**, then its own result. One service can finish
  while the other is still waiting. A successful reply with unchanged percentages
  is still a successful refresh.
- Check **Data** for the reading time and **Next automatic attempt** for the
  schedule. A failed attempt keeps the previous figures and their original time;
  it does not make an old reading fresh. An unknown time is shown as `—`.
- If only one service fails, use **Retry** beside that service after the displayed
  wait. Repeated clicks do not start a second request already in progress. The
  **30-second local guard**, counted from the start of an attempt, is separate
  from Auto and is not a server limit.
- **Service allows retry in…** means the service supplied a retry deadline
  (`Retry-After`). Manual refresh must respect it; the automatic attempt becomes
  eligible at that deadline. No server deadline is invented when it is unknown.
- Ordinary **Refresh now** and background attempts keep permission dialogs disabled.
  Only when reading the Claude entry requires permission does **Allow Keychain
  access** appear after the displayed wait. Click it for one read attempt limited
  to 15 seconds; a system dialog may appear for that separate action. **Cancel**
  ends the attempt; a new attempt needs a new explicit request. Read permission
  does not authorize saving renewed sign-in data or automatically change access permissions.
- For **Could not save renewed sign-in**, open **Restore access**, unlock
  Keychain, then click **Refresh now** to retry saving. Read permission does not mean
  saving succeeded. A read or save failure alone does not require signing in again.
  If saving still fails, a new `claude login` is an optional recovery step.
  For an actual sign-in problem, follow the affected CLI's instructions:
  `claude login` for Claude or `codex login` for Codex, then return and refresh.

These quota controls are separate from **Retry Keychain access** in GitHub sync
settings. See [RU/EN notes](docs/manual-refresh-release.md).

## Release history — macOS 3.2.5: quiet GitHub Keychain access

Background GitHub Keychain access runs with system permission dialogs disabled,
including after launch, wake and credential cleanup. If permission is
needed, sync waits and keeps the saved sign-in. Linux stays at 0.4.4.

On a Mac running 3.2.5, open Settings → GitHub sync and choose
**Retry Keychain access** if storage needs permission. The attempt has a time
limit; a system window may appear for that action. Allow access only if you
recognize the app and the requested GitHub item. Cancel or deny ends that attempt;
a new interactive attempt needs another click. Sign in again only when the app
asks for a new login.

An existing credential may need manual permission because the helper accessing
it changes. **Always Allow** applies to the particular item and requesting app,
not every item in the service. Do not grant access to all applications or export
the token to a plain-text file. The exact cause of the user's repeated live
prompts is still unknown. The old **600-second** pause only delayed retries;
waiting or restarting did not unlock Keychain. Scheduled retries keep system dialogs disabled.

This change does not notarize the app or change Gatekeeper. The missing Codex
pace diagnostic remains a separate issue; 3.2.5 does not claim to fix it.
See [RU/EN release notes and verification limits](docs/keychain-quiet-release.md).

## Features

Refresh and interval instructions cover macOS 3.4.0 and **Linux 0.5.0**.

- **Two products, one glance** — Claude Code (orange) stacked over Codex, `session / weekly` percentages.
- **Live data** — both read usage from the same backends their CLIs use. When a fresh reading is unavailable, the card marks retained data as stale.
- **Honest about stale data** — an old reading or a network error does not prove that sign-in expired. A timestamped reading remains valid by age through 4 hours inclusive; a failed fetch alone does not invalidate it. Pace uses the reading time and checks each window separately. Expired readings keep cached percentages and suggest refreshing data. If no reading time is available, the card says “No fresh data · pace paused”. Claude sign-in instructions appear only for Claude when its sign-in state is logged out or expired; a stale Codex card does not show `claude login`.
- **Per‑model weekly limits** — a model with its own 7‑day allowance (e.g. Fable) gets its own percentage pill and a row with its reset time. This is usually the limit you actually run into first: it can sit at 100% while your overall weekly still has room. The model is named by the backend, so new ones appear on their own.
- **Advanced view** — a second panel layout for people who want to *manage* their limits, not just glance at them. Every window gets a pace line: where a linear plan says you should be by now, how many points you're ahead of it, your average burn rate, and a plain verdict — “Lasts until reset (forecast 53%)” or “Runs out at 09:37, 2 h 13 min before reset”. Below: 7 days of consumption as bars stacked by model, a 35‑day calendar heatmap, and money — what a day costs you out of the subscription versus what the same tokens would cost at API prices. Separately for Claude Code and Codex. Settings → *Panel view*.
- **Several computers, one window** — sign in with GitHub in Settings and every computer running the app adds its local usage to one secret gist; each copy shows the combined bars, calendar and money per subscription. Usage is shared as daily token totals per model — no prompts, paths or project names. Since macOS 3.4.0 / Linux 0.5.0, machines also share [limits from other computers](#limits-from-other-computers). There is a Linux port for Astra Linux — see [Linux](#linux-astra-linux) ([protocol](docs/sync-protocol.md)).
- **You choose what the menu bar shows** — pick which number sits on each side of the slash (5‑hour, weekly, or the per‑model limit) and in which order, or clear the right‑hand one for a single figure. Settings → *In the menu bar*. The strip updates the moment you tap.
- **Codex reset credits** — if you've banked rate‑limit resets, a small ⟳ badge on the Codex card shows how many you have.
- **Color warnings** — numbers and gauges turn amber at ≥50% and red at ≥80% of a limit.
- **Detailed popover** — click the tray icon for ring gauges, exact percentages, and reset times.
- **Click a card** to open the relevant limits page in your browser.
- **Choose what this Mac polls.** Settings → **Poll on this computer** offers independent Claude Code and Codex switches in both panel views. A product that is off is not polled and its sign-in and logs are not read on this Mac; its usage from this Mac is excluded from new sync uploads. Accounts of that product from other computers stay visible. Existing local history is kept; re-enabling catches up from the logs. The choice is saved per computer.
- **One or both** — if only Claude Code or only Codex is set up, the tray and popover collapse to a single row / single card.
- **Refresh now** — the small icon beside Settings requests fresh limits without waiting for the local schedule or error backoff. Each provider has a 30-second guard and one request at a time; server Retry-After still applies. Status and data time fit inside each card. With GitHub sync on, accounts not signed in on this Mac are refreshed by re-reading GitHub, and the Mac's own Codex account follows the 15-minute floor described in [How Auto polling works](#how-auto-polling-works).
- **Refresh interval** — choose **15 minutes / 30 minutes / 1 hour / 4 hours**. The default is 30 minutes; saved supported choices are preserved, and old 1/5-minute settings migrate to 30 minutes.
- **Adaptive polling (A)** — active usage returns polling to 15 minutes; quiet readings extend it to 30 minutes, 1 hour, then 4 hours, independently per provider. Auto highlights A and the actual intervals of enabled providers; different intervals highlight both segments. Tooltips map intervals to providers; there is no separate frequency label. With both subscriptions off, no interval is highlighted; A may remain selected. Auto is off by default.
- **Sound alerts (optional)** — a cheerful chime when a 5h or weekly limit *resets*, and a sad shutdown‑style tone when **any** limit is *reached*, per‑model ones included; choose a sound per event in the in‑app settings (⚙).
- **Automatic updates** — checks for new releases in the background (on launch + every 6 h); when one appears, a dot badges the tray icon and the ⚙ gear. In Settings, **What's new** shows the accumulated release notes for every version you skipped, and **Download** → live progress bar → **Install & Relaunch** takes you straight to the latest. No Sparkle, no notarization required.
- **Bilingual (RU / EN)** — switch the whole interface between Russian and English in Settings; release notes load in the chosen language too. Russian by default.
- **Light & dark** menu bar, retina‑crisp.
- **Launch at login** — a toggle right in Settings; no Dock icon, no dependencies beyond what macOS already ships.

<p align="center">
  <img src="docs/menubar-single.png?v=314" width="140" alt="Single product (menu bar)">
  &nbsp;&nbsp;
  <img src="docs/panel-single-en.png?v=314" width="300" alt="Single product (popover)">
</p>
<p align="center"><sub>With only one subscription set up, the tray and popover collapse to a single row / card.</sub></p>

<p align="center"><img src="docs/settings-en.png?v=314" width="250" alt="Settings screen"></p>
<p align="center"><sub>Settings (⚙): interface language · panel view · launch at login · which two numbers the menu bar shows · subscriptions and GitHub sync (Advanced) · sounds on their own screen · built‑in updates.</sub></p>

<p align="center"><img src="docs/whatsnew-en.png?v=314" width="320" alt="What's new screen"></p>
<p align="center"><sub>“What’s new”: release notes for every version you skipped, then update straight from there.</sub></p>

## How it works

**Claude Code** (subscription limits). The app reads your existing Claude Code OAuth
credentials from the macOS Keychain (`Claude Code-credentials`) and calls Anthropic's
usage endpoint `GET /api/oauth/usage`. **This does not consume any of your quota** — it
only reads `five_hour.utilization` (session) and `seven_day.utilization` (weekly), plus the
structured `limits[]` array for per‑model weekly allowances (`kind: "weekly_scoped"`, named
by `scope.model.display_name`). The older per‑model fields (`seven_day_opus` and friends)
now come back `null`, so `limits[]` is the only source for those.

**Codex** (OpenAI). The app fetches **live** usage from the same backend the Codex CLI
uses — `GET /backend-api/wham/usage` — when a refresh is admitted by the
polling rules (see Auto and manual refresh above), authenticated with your local `~/.codex/auth.json` token. `primary_window` = 5‑hour, `secondary_window`
= 7‑day. If a live call fails it falls back to the most recent local session log
(`~/.codex/sessions/**/rollout-*.jsonl`).

**CLI sign-ins are read-only.** Since macOS 3.4.0 the app only reads the Claude Code and Codex
credentials: it does not refresh their tokens or write them back. When an access token has
expired, the card says the CLI needs to renew its sign-in and keeps the last values with their
time; the next CLI use renews it. On Linux the tray behaves the same by default.

**Advanced view.** The pace math needs only the current reading and the window's reset time.
The bars, calendar and money come from the CLIs' own local transcripts — `~/.claude/projects/*/*.jsonl`
and `~/.codex/sessions/**/rollout-*.jsonl` — which record every turn's token counts and model. So the
percentages and the pace are account‑wide (whatever machine you used), while the bars, calendar and money
cover what ran on this Mac — plus every other computer signed in to the same GitHub, if you turn on sync. With sync, a card can also show the limits of an account signed in only on another computer; its pace is calculated from that machine's reading time. The app indexes the transcripts incrementally (only bytes appended since the last pass) and prices tokens with a built‑in
per‑model table of public API rates; unknown models are left unpriced rather than guessed. The
subscription price is inferred from your plan where possible (Claude's rate‑limit tier) and is editable
in Settings — Codex plan names don't map to public prices, so that one is marked as an estimate until
you set it. The app also keeps its own utilization samples (35 days, in `~/.claude-limits-monitor/`)
so that pace can later use your recent rate, not just the window average.

Authenticated usage requests go to Anthropic and OpenAI as you. If you enable GitHub sync,
daily usage aggregates and account limit snapshots also go to your secret gist ([what exactly](#what-goes-to-the-gist--and-what-never-does)). No telemetry. Runtime cache and a Keychain backup live
under `~/.claude-limits-monitor/`.

## GitHub sign-in and recovery

macOS 3.2.3 / Linux 0.4.3 are published; code, packages and independent QA
have passed, and public downloads match the verified packages (see [macOS notes](docs/release-notes-3.2.3.md)
and [Linux notes](docs/release-notes-linux-0.4.3.md)). A healthy existing GitHub
sign-in keeps working without signing in again. A new explicit login requests
`gist offline_access` and saves refresh credentials and lifetimes if GitHub supplies
them. Short access credentials are renewed automatically, including after sleep
or restart. GitHub maintenance has its own schedule, independent of Advanced view
and Auto polling of Claude/Codex limits.

Temporary network or keyring failures retain the last safely saved sign-in and
retry with backoff. Check Settings → GitHub sync for the latest error. On the
macOS 3.2.5, use **Retry Keychain access** when permission is needed;
background retries cannot request it. Restore the connection for network errors.
External revocation, an expired refresh credential, a missing local key or a lost replacement pair may require
one explicit sign-in. A timeout alone is not proof that GitHub revoked access.
Sign-out affects this computer only; if credential deletion is still pending,
the app says so. On Mac, old remote totals without a verified account binding wait
for the first verified sync after restart; local history is retained.

Synthetic lifecycle checks do not establish six months of real-world operation
or live Astra Linux verification. See the [sync contract](docs/sync-protocol.md).

## Install

### 1. One‑line install (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/ArrivaRUS/claude-codex-limits/main/get.sh | bash
```

Downloads the latest release and installs it straight into **Applications** with **no
Gatekeeper prompts** — an app fetched with `curl` isn't quarantined, so macOS doesn't
flag it as “damaged” or “unidentified developer”. Launch‑at‑login stays **off** until
you turn it on in Settings.

### 2. From the .dmg

1. Download `ClaudeCodexLimits-3.4.0.dmg` from the [macOS 3.4.0 release](../../releases/tag/v3.4.0).
2. Open it and drag **Claude Codex Limits** into **Applications**.
3. Launch it. The build isn't notarized, so on **macOS Sequoia / Tahoe** the first
   launch is blocked. Do this once:
   - In the block dialog click **Cancel** (⚠️ **not** “Move to Trash”).
   - Open **System Settings → Privacy & Security**, scroll to the bottom, click
     **Open Anyway**, and confirm.
   - **If no “Open Anyway” button appears**, clear the quarantine flag in Terminal,
     then open the app normally:
     ```bash
     xattr -dr com.apple.quarantine "/Applications/Claude Codex Limits.app"
     ```
4. The icon appears at the top‑right of your menu bar.

### 3. From source

```bash
git clone https://github.com/ArrivaRUS/claude-codex-limits.git
cd claude-codex-limits
CCL_REQUIRE_STABLE_SIGNING=1 bash build.sh
```

Requirements: macOS 13+, the Xcode command‑line tools (`swiftc`). No packages to install.

Build in your own Terminal. Quit the previous app
before installing `dist/Claude Codex Limits.app` into Applications. The strict command
requires stable signing; if that fails, it stops without replacing the existing app
in `dist/` with an ad-hoc build.

The build creates a local **`.signing/`** directory with a long-lived signing key,
certificate and separate signing keychain. **Keep it between builds:** the same
certificate and bundle ID preserve the app's identity for Keychain permissions.
Deleting it creates a new identity on the next build and requires granting access
again. The first stable build may still need **Always Allow** for old entries.
Keep its secrets out of commits and shared artifacts. Details: [build guide](docs/project-guide.md#сборка-публикация-и-откат).

### Linux (Astra Linux)

Linux **0.5.0** is the current Linux release. Earlier versions were tested on Astra Linux SE 1.8 (KDE / Fly). The port gives a tray icon with the same
percentages, the popover with the simple and Advanced views, and usage sync with the Mac through
the same gist.

1. Download `claude-codex-limits_0.5.0_all.deb` from [Linux 0.5.0](https://github.com/ArrivaRUS/claude-codex-limits/releases/tag/linux-v0.5.0). Linux releases are not marked Latest; Latest is macOS 3.4.0.
2. Double-click it and press Install, or install it from a terminal:
   ```bash
   sudo apt install ./claude-codex-limits_0.5.0_all.deb
   ```
   apt pulls the dependencies (`python3-pyqt5`, `python3-dbus`) from the OS repository.
3. Start **Claude Codex Limits** from the application menu. From then on it starts at login.

Without admin rights, install into your home folder instead: `git clone`, then `sh linux/install.sh`.
A server that should publish its limits is set up from a checkout, not from the .deb — see [Turn it on](#turn-it-on).
Details: [linux/README.md](linux/README.md) (in Russian).

## Usage

For macOS 3.4.0 and **Linux 0.5.0**. Enable the required subscriptions in Settings and sign in through the corresponding CLI.

- **Left‑click** the tray icon → open/close the popover.
- **Click a card** → open that product's limits page in the browser.
- **Refresh now** → click the small icon beside Settings. Manual refresh bypasses the local schedule/error backoff, preserves the selected mode and respects each provider's 30-second guard, active request and server Retry-After. On Linux, opening the panel alone does not request fresh limits.
- **Read each card's result** → providers finish independently. Unchanged live values count as success; fallback retains the old data time. Use **Retry** on the failed card once its wait ends; its tooltip separates data time from the next automatic attempt.
- **Restore access on Linux** → follow the affected card's instructions: start `claude` and run `/login`, or run `codex login`. For file read/save errors, check that the CLI runs as your user, its credential file is accessible and disk space is available. Login and permissions are not requested automatically.
- **Interval buttons** → **15 min / 30 min / 1 h / 4 h** selects fixed polling; **A** selects Auto. Auto highlights A and enabled providers' actual intervals together; different intervals highlight both, and both subscriptions off means no highlighted interval. No separate frequency or snapshot-pace annotation; forecasts remain.
- **Power button** (bottom‑right) → quit.
- **Right‑click** the tray icon → fallback menu (Refresh / Launch at login / Quit).

### How Auto polling works

Activity means an increase of at least 1 percentage point per 15 minutes in any comparable limit, measured over the time between readings. The first response establishes a baseline; limit window resets are not consumption. Local token logs are checked every 2 minutes without an API request: three distinct events with positive token usage in the past 15 minutes also restore 15-minute polling.

Opening the panel in Auto keeps its schedule. Errors and cached responses extend automatic polling's pause; local activity cannot shorten error backoff. **Refresh now** bypasses that local pause, subject to the provider's 30-second guard, active request and actual server retry deadline in the published versions described here. Without GitHub sync, activity exclusively on another computer is detected at the next API poll, which can take up to 4 hours during a quiet period. With [limits from other computers](#limits-from-other-computers), the Mac also uses fresh readings of the same account from other machines to accelerate Auto. Refresh now for the Mac's own Codex account asks OpenAI at most once per 15 minutes for that account across machines (16 minutes after another machine's attempt) and otherwise only re-reads GitHub. History sync keeps its own schedule.

## Build a release

```bash
./scripts/make-dmg.sh     # → dist/ClaudeCodexLimits-3.4.0.dmg
```

## Project layout

```
Sources/LimitsMonitor.swift   the app (Foundation + AppKit + CoreText)
Sources/RemoteLimits*.swift   limits from other computers: gist v1.1 reader/publisher, cards
Sources/GitHubAuth.swift      GitHub sign-in and credential lifecycle
Resources/*.png               brand icons
linux/                        Linux port: tray app and ccl-sync (incl. publisher)
build.sh                      build the .app into dist/
install.sh                    build + install + launch-at-login
scripts/make-dmg.sh           package a .dmg
docs/                         screenshots, sync protocol, design and release notes
```

## Privacy & security

The app only ever reads **your own** local credentials and logs, and only talks to
Anthropic's and OpenAI's APIs authenticated as you (the same endpoints their own CLIs use),
plus GitHub when you enable sync, as [described above](#limits-from-other-computers).
Credentials authenticate their intended API requests and stay out of usage aggregates and logs.
The Swift sources are readable in `Sources/`.
Use at your own discretion.

## License

[MIT](LICENSE) © 2026 Alex Kovalev
