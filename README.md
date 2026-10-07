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

## macOS 3.2.5: quiet GitHub Keychain access

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

- **Two products, one glance** — Claude Code (orange) stacked over Codex, `session / weekly` percentages.
- **Live data** — both read usage from the same backends their CLIs use. When a fresh reading is unavailable, the card marks retained data as stale.
- **Honest about stale data** — an old reading or a network error does not prove that sign-in expired. A timestamped reading remains valid by age through 4 hours inclusive; a failed fetch alone does not invalidate it. Pace uses the reading time and checks each window separately. Expired readings keep cached percentages and suggest refreshing data. If no reading time is available, the card says “No fresh data · pace paused”. Claude sign-in instructions appear only for Claude when its sign-in state is logged out or expired; a stale Codex card does not show `claude login`.
- **Per‑model weekly limits** — a model with its own 7‑day allowance (e.g. Fable) gets its own percentage pill and a row with its reset time. This is usually the limit you actually run into first: it can sit at 100% while your overall weekly still has room. The model is named by the backend, so new ones appear on their own.
- **Advanced view** — a second panel layout for people who want to *manage* their limits, not just glance at them. Every window gets a pace line: where a linear plan says you should be by now, how many points you're ahead of it, your average burn rate, and a plain verdict — “Lasts until reset (forecast 53%)” or “Runs out at 09:37, 2 h 13 min before reset”. Below: 7 days of consumption as bars stacked by model, a 35‑day calendar heatmap, and money — what a day costs you out of the subscription versus what the same tokens would cost at API prices. Separately for Claude Code and Codex. Settings → *Panel view*.
- **Several computers, one account** — sign in with GitHub in Settings and every computer running the app adds its local usage to one secret gist; each copy shows the combined bars, calendar and money. Only daily token totals per model travel — no prompts, paths or project names. There is a Linux port for Astra Linux — see [Linux](#linux-astra-linux) ([protocol](docs/sync-protocol.md)).
- **You choose what the menu bar shows** — pick which number sits on each side of the slash (5‑hour, weekly, or the per‑model limit) and in which order, or clear the right‑hand one for a single figure. Settings → *In the menu bar*. The strip updates the moment you tap.
- **Codex reset credits** — if you've banked rate‑limit resets, a small ⟳ badge on the Codex card shows how many you have.
- **Color warnings** — numbers and gauges turn amber at ≥50% and red at ≥80% of a limit.
- **Detailed popover** — click the tray icon for ring gauges, exact percentages, and reset times.
- **Click a card** to open the relevant limits page in your browser.
- **Choose subscriptions.** Settings → “Collect and show” offers independent Claude Code and Codex switches in both panel views. Keep only Codex, or turn both off. Disabled products stop API polling and log indexing, disappear from the tray, panel and history, and are excluded from new sync uploads from this Mac. Existing local history is kept; re-enabling catches up from the logs. The choice is saved per computer.
- **One or both** — if only Claude Code or only Codex is set up, the tray and popover collapse to a single row / single card.
- **Opening the popover requests a fresh reading** with a fixed interval; Auto respects its schedule.
- **Refresh interval** — 15 minutes, 30 minutes, or 1 hour. The default is 30 minutes; saved 15-minute and 1-hour choices are preserved. Older 1/5-minute settings automatically switch to 30 minutes.
- **Adaptive polling (A)** — opt in with the button beside the fixed intervals. Active usage returns polling to 15 minutes; quiet readings gradually extend the pause to 30 minutes, 1 hour, then 4 hours. Claude Code and Codex have independent schedules, persisted across restarts. When Auto is on, the blue-to-violet A button shows the current interval beside it in both Simple and Advanced views. One enabled subscription or equal intervals shows one value; different intervals show each product, for example `Claude 15m · Codex 4h`. With both subscriptions off, the label reads `no subscriptions`. The last-update time is available in the A tooltip while Auto is on. Auto is off by default; the fixed default remains 30 minutes.
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

<p align="center"><img src="docs/advanced-en.png?v=314" width="320" alt="Advanced view"></p>
<p align="center"><sub>Advanced view: a pace line and a plain verdict per window, 7 days stacked by model, a 35‑day calendar, and what a day costs on the subscription vs at API prices.</sub></p>

<p align="center"><img src="docs/settings-en.png?v=314" width="250" alt="Settings screen"></p>
<p align="center"><sub>Settings (⚙): interface language · panel view · launch at login · which two numbers the menu bar shows · subscriptions and GitHub sync (Advanced) · sounds on their own screen · built‑in updates.</sub></p>

<p align="center"><img src="docs/whatsnew-en.png?v=314" width="320" alt="What's new screen"></p>
<p align="center"><sub>“What’s new”: release notes for every version you skipped, then update straight from there.</sub></p>

## How it works

**Claude Code** (subscription limits). The app reads your existing Claude Code OAuth
credentials from the macOS Keychain (`Claude Code-credentials`), refreshing the access
token the same way the Claude Code CLI does when it expires, and calls Anthropic's
usage endpoint `GET /api/oauth/usage`. **This does not consume any of your quota** — it
only reads `five_hour.utilization` (session) and `seven_day.utilization` (weekly), plus the
structured `limits[]` array for per‑model weekly allowances (`kind: "weekly_scoped"`, named
by `scope.model.display_name`). The older per‑model fields (`seven_day_opus` and friends)
now come back `null`, so `limits[]` is the only source for those.

**Codex** (OpenAI). The app fetches **live** usage from the same backend the Codex CLI
uses — `GET /backend-api/wham/usage` — on every refresh (launch, the 15/30/60‑min timer,
and popover open), authenticated with your local `~/.codex/auth.json` token (auto‑refreshed
via OpenAI's token endpoint when expired). `primary_window` = 5‑hour, `secondary_window`
= 7‑day. If a live call fails it falls back to the most recent local session log
(`~/.codex/sessions/**/rollout-*.jsonl`).

**Advanced view.** The pace math needs only the current reading and the window's reset time.
The bars, calendar and money come from the CLIs' own local transcripts — `~/.claude/projects/*/*.jsonl`
and `~/.codex/sessions/**/rollout-*.jsonl` — which record every turn's token counts and model. So the
percentages and the pace are account‑wide (whatever machine you used), while the bars, calendar and money
cover what ran on this Mac — plus every other computer signed in to the same GitHub, if you turn on sync. The app indexes the transcripts incrementally (only bytes appended since the last pass) and prices tokens with a built‑in
per‑model table of public API rates; unknown models are left unpriced rather than guessed. The
subscription price is inferred from your plan where possible (Claude's rate‑limit tier) and is editable
in Settings — Codex plan names don't map to public prices, so that one is marked as an estimate until
you set it. The app also keeps its own utilization samples (35 days, in `~/.claude-limits-monitor/`)
so that pace can later use your recent rate, not just the window average.

Authenticated usage requests go to Anthropic and OpenAI as you. If you enable GitHub sync,
daily usage aggregates also go to your secret gist. No telemetry. Runtime cache and a Keychain backup live
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

1. Download `ClaudeCodexLimits-3.2.2.dmg` from the [macOS 3.2.2 release](../../releases/tag/v3.2.2).
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
./install.sh        # builds, installs to /Applications, enables launch-at-login, starts it
```

Requirements: macOS 13+, the Xcode command‑line tools (`swiftc`). No packages to install.

### Linux (Astra Linux)

Earlier Linux versions were tested on Astra Linux SE 1.8 (KDE / Fly). The 0.4.2 UI change has not yet been tested on a live ALSE system; Linux CI uses Ubuntu 22.04. The port gives a tray icon with the same
percentages, the popover with the simple and Advanced views, and usage sync with the Mac through
the same gist.

1. Download `claude-codex-limits_0.4.2_all.deb` from the [Linux 0.4.2](../../releases/tag/linux-v0.4.2) release.
2. Double-click it and press Install, or install it from a terminal:
   ```bash
   sudo apt install ./claude-codex-limits_0.4.2_all.deb
   ```
   apt pulls the dependencies (`python3-pyqt5`, `python3-dbus`) from the OS repository.
3. Start **Claude Codex Limits** from the application menu. From then on it starts at login.

Without admin rights, install into your home folder instead: `git clone`, then `sh linux/install.sh`.
Details: [linux/README.md](linux/README.md) (in Russian).

## Usage

- **Left‑click** the tray icon → open/close the popover.
- **Click a card** → open that product's limits page in the browser.
- **Refresh button** (top‑right of the popover) → refresh now.
- **Interval buttons** (bottom) → 15 min / 30 min / 1 hour / **A** (Auto).
- **Power button** (bottom‑right) → quit.
- **Right‑click** the tray icon → fallback menu (Refresh / Launch at login / Quit).

### How Auto polling works

Activity means an increase of at least 1 percentage point per 15 minutes in any comparable limit, measured over the time between readings. The first response establishes a baseline; limit window resets are not consumption. Local token logs are checked every 2 minutes without an API request: three distinct events with positive token usage in the past 15 minutes also restore 15-minute polling.

In Auto, opening the panel keeps the schedule; manual refresh waits at least 15 minutes after the previous response. Errors and cached responses extend the pause, and local activity or manual refresh cannot shorten that error backoff. Activity exclusively on another computer is detected at the next API poll, which can take up to 4 hours during a quiet period. History sync keeps its own schedule.

## Build a release

```bash
./scripts/make-dmg.sh     # → dist/ClaudeCodexLimits-3.2.2.dmg
```

## Project layout

```
Sources/LimitsMonitor.swift   the whole app (Foundation + AppKit + CoreText)
Resources/*.png               brand icons
build.sh                      build the .app into dist/
install.sh                    build + install + launch-at-login
scripts/make-dmg.sh           package a .dmg
docs/                         screenshots
```

## Privacy & security

The app only ever reads **your own** local credentials and logs, and only talks to
Anthropic's and OpenAI's APIs authenticated as you (the same endpoints their own CLIs use).
Credentials authenticate their intended API requests and stay out of usage aggregates and logs.
The Swift sources are readable in `Sources/`.
Use at your own discretion.

## License

[MIT](LICENSE) © 2026 Alex Kovalev
