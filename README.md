# Claude Codex Limits

**English** · [Русский](README.ru.md)

<p align="center">
  <img src="docs/banner.png?v=311" alt="Claude Codex Limits — macOS menu bar usage limits" width="820">
</p>

A tiny macOS menu-bar app that shows how much of your **Claude Code** and **Codex**
usage limits you have left — at a glance, right in the top tray.

Each row shows `session% / weekly%` by default (the rolling 5‑hour window and the 7‑day
window), with the product's icon to its left — and you decide which two numbers those are.
Click the tray icon for a detailed popover.

<p align="center">
  <img src="docs/menubar-dark.png?v=311" width="180" alt="Menu bar (dark)">
  &nbsp;&nbsp;
  <img src="docs/panel-en.png?v=311" width="320" alt="Popover">
</p>

## Features

- **Two products, one glance** — Claude Code (orange) stacked over Codex, `session / weekly` percentages.
- **Live data** — both are pulled from the same backends their CLIs use, so Codex matches its web page (not a stale local cache).
- **Honest when a login lapses** — if Claude Code's saved credentials expire for good, the card says so (“Sign-in expired · How to fix?”) and tapping it walks you through `claude` → `/login`; meanwhile the app stops hammering the API with a token it already knows is dead. One fresh sign-in and it heals on its own.
- **Per‑model weekly limits** — a model with its own 7‑day allowance (e.g. Fable) gets its own percentage pill and a row with its reset time. This is usually the limit you actually run into first: it can sit at 100% while your overall weekly still has room. The model is named by the backend, so new ones appear on their own.
- **Advanced view** — a second panel layout for people who want to *manage* their limits, not just glance at them. Every window gets a pace line: where a linear plan says you should be by now, how many points you're ahead of it, your average burn rate, and a plain verdict — “Lasts until reset (forecast 53%)” or “Runs out at 09:37, 2 h 13 min before reset”. Below: 7 days of consumption as bars stacked by model, a 35‑day calendar heatmap, and money — what a day costs you out of the subscription versus what the same tokens would cost at API prices. Separately for Claude Code and Codex. Settings → *Panel view*.
- **Several computers, one account** — sign in with GitHub in Settings and every computer running the app adds its local usage to one secret gist; each copy shows the combined bars, calendar and money. Only daily token totals per model travel — no prompts, paths or project names. There is a Linux port for Astra Linux — see [Linux](#linux-astra-linux) ([protocol](docs/sync-protocol.md)).
- **You choose what the menu bar shows** — pick which number sits on each side of the slash (5‑hour, weekly, or the per‑model limit) and in which order, or clear the right‑hand one for a single figure. Settings → *In the menu bar*. The strip updates the moment you tap.
- **Codex reset credits** — if you've banked rate‑limit resets, a small ⟳ badge on the Codex card shows how many you have.
- **Color warnings** — numbers and gauges turn amber at ≥50% and red at ≥80% of a limit.
- **Detailed popover** — click the tray icon for ring gauges, exact percentages, and reset times.
- **Click a card** to open the relevant limits page in your browser.
- **One or both** — if only Claude Code or only Codex is set up, the tray and popover collapse to a single row / single card.
- **Opening the popover forces a fresh reading** right then.
- **Refresh interval** — 1 / 5 / 15 minutes, your choice.
- **Sound alerts (optional)** — a cheerful chime when a 5h or weekly limit *resets*, and a sad shutdown‑style tone when **any** limit is *reached*, per‑model ones included; choose a sound per event in the in‑app settings (⚙).
- **Automatic updates** — checks for new releases in the background (on launch + every 6 h); when one appears, a dot badges the tray icon and the ⚙ gear. In Settings, **What's new** shows the accumulated release notes for every version you skipped, and **Download** → live progress bar → **Install & Relaunch** takes you straight to the latest. No Sparkle, no notarization required.
- **Bilingual (RU / EN)** — switch the whole interface between Russian and English in Settings; release notes load in the chosen language too. Russian by default.
- **Light & dark** menu bar, retina‑crisp.
- **Launch at login** — a toggle right in Settings; no Dock icon, no dependencies beyond what macOS already ships.

<p align="center">
  <img src="docs/menubar-single.png?v=311" width="140" alt="Single product (menu bar)">
  &nbsp;&nbsp;
  <img src="docs/panel-single-en.png?v=311" width="300" alt="Single product (popover)">
</p>
<p align="center"><sub>With only one subscription set up, the tray and popover collapse to a single row / card.</sub></p>

<p align="center"><img src="docs/advanced-en.png?v=311" width="320" alt="Advanced view"></p>
<p align="center"><sub>Advanced view: a pace line and a plain verdict per window, 7 days stacked by model, a 35‑day calendar, and what a day costs on the subscription vs at API prices.</sub></p>

<p align="center"><img src="docs/settings-en.png?v=311" width="250" alt="Settings screen"></p>
<p align="center"><sub>Settings (⚙): interface language · panel view · launch at login · which two numbers the menu bar shows · subscriptions and GitHub sync (Advanced) · sounds on their own screen · built‑in updates.</sub></p>

<p align="center"><img src="docs/whatsnew-en.png?v=311" width="320" alt="What's new screen"></p>
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
uses — `GET /backend-api/wham/usage` — on every refresh (launch, the 1/5/15‑min timer,
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

Nothing is sent anywhere except the authenticated usage requests to Anthropic and OpenAI
(as you). No telemetry, no third‑party services. Runtime cache and a Keychain backup live
under `~/.claude-limits-monitor/`.

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

1. Download `ClaudeCodexLimits-3.1.1.dmg` from the [Releases](../../releases) page.
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

The Linux port is tested on Astra Linux SE 1.8 (KDE / Fly). It gives a tray icon with the same
percentages, the popover with the simple and Advanced views, and usage sync with the Mac through
the same gist.

1. Download `claude-codex-limits_0.3.0_all.deb` from the [Linux 0.3.0](../../releases/tag/linux-v0.3.0) release.
2. Double-click it and press Install, or install it from a terminal:
   ```bash
   sudo apt install ./claude-codex-limits_0.3.0_all.deb
   ```
   apt pulls the dependencies (`python3-pyqt5`, `python3-dbus`) from the OS repository.
3. Start **Claude Codex Limits** from the application menu. From then on it starts at login.

Without admin rights, install into your home folder instead: `git clone`, then `sh linux/install.sh`.
Details: [linux/README.md](linux/README.md) (in Russian).

## Usage

- **Left‑click** the tray icon → open/close the popover.
- **Click a card** → open that product's limits page in the browser.
- **Refresh button** (top‑right of the popover) → refresh now.
- **Interval pills** (bottom) → 1 / 5 / 15 minutes.
- **Power button** (bottom‑right) → quit.
- **Right‑click** the tray icon → fallback menu (Refresh / Launch at login / Quit).

## Build a release

```bash
./scripts/make-dmg.sh     # → dist/ClaudeCodexLimits-3.1.1.dmg
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
It never embeds or transmits secrets. The source is a single readable Swift file — read it.
Use at your own discretion.

## License

[MIT](LICENSE) © 2026 Alex Kovalev
