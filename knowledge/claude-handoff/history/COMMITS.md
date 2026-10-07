# История разработки Claude Codex Limits

История коммитов, достижимых из локального HEAD `998cf0efabac5bcf8693d9889a48ddc1979b024a`, на 5 октября 2026 года. Это сообщения коммитов из репозитория, а не восстановленная переписка Claude. Они объясняют ход разработки и содержат решения, которых может не быть в сводке. Записи о тестах и релизах относятся к времени коммита; заново не проверялись.

## 2026-09-30T15:24:42+03:00 998cf0efabac

Merge pull request #7 from ArrivaRUS/linux-poll-5min

linux 0.3.3 — интервал опроса 5 или 15 минут, без «1м» (#6)

## 2026-09-30T15:16:30+03:00 17b1b07e1886

linux 0.3.3 — refresh interval 5 or 15 minutes, no 1 minute (#6)

At one minute two machines on one account hit 429 from /api/oauth/usage for
hours. Choices are now 5м | 15м (panel.POLL_CHOICES); a saved 60 (or anything
else) is lifted to 5 minutes at start and written back; the default is 300.
The width probe starts from a saved 60 and fails unless model, settings and
timer all end up at 5 minutes.

Closes #6

## 2026-09-30T15:14:59+03:00 2d97ba17a4ff

README: DMG name 3.1.4

## 2026-09-30T15:14:18+03:00 8d8ad4cc4b89

v3.1.4 — five-minute polling floor; drop the 1-minute option

At one minute, two machines on one account made ~120 calls an hour to
/api/oauth/usage and Anthropic answered 429 for hours (2026-09-30), which the
Advanced card then showed as a sign-in problem. Interval choices are now
5m | 15m (POLL_CHOICES, POLL_MIN = 300); a stored 1-minute value is lifted to
5 on launch (storedPollInterval) and setInterval refuses anything lower.
READMEs updated. Linux counterpart: #6.

## 2026-09-30T14:43:10+03:00 c15db0e82621

HEARTBEAT: от Linux-стороны — выкладка Linux = релиз linux-v…, не merge; 0.3.2 на ThinkPad

Пакет .deb обновляется только из GitHub-релизов linux-v<версия>, из main — лишь
старая установка через install.sh. linux-v0.3.2 опубликован (не Latest), поставлен
на ThinkPad: 183 теста без пропусков, синк без перевхода, в KWallet одна запись.
Поправка в журнале решений, урок 009.

## 2026-09-30T14:29:07+03:00 9522798bad29

HEARTBEAT: релиз v3.1.3 опубликован

## 2026-09-30T14:28:42+03:00 6df548153393

release: make-dmg 3.1.3

## 2026-09-30T14:25:57+03:00 33a6e1258795

HEARTBEAT: финальные ревью чистые, выкладка; тикеты после релиза

## 2026-09-30T14:12:37+03:00 dbb53b32ea5a

decisions: «да» на push/merge заранее при чистых финальных ревью (человек)

## 2026-09-30T14:10:12+03:00 c3385a33aa42

patches: 007 тихий отзыв синка на 401, 008 окна гонки по одному; дополнение 006

## 2026-09-30T14:09:49+03:00 b5881cc65937

sync: Ctrl+C во время записи токена откладывается до конца критической секции

_sigint_deferred() в store/publish/delete_ref/delete; второй рубеж — ветка таймаута
_timed внутри try. 20 новых тестов, 183 OK на Python 3.9 и 3.14.
developer-codex, GPT-6 Astra @high.

## 2026-09-30T13:57:08+03:00 591fc0625d5b

decisions: Ctrl+C при записи токена — лечить корень (человек)

## 2026-09-30T13:14:29+03:00 fa2cac595882

sync: F-1 — старт потока _timed под перехватом прерывания; F-2 — retire удаляет временники write_atomic своего поколения

Тесты глубокого JSON устойчивы к версии Python. 163 OK на 3.9 и 3.14.
developer-codex, GPT-6 Astra @high.

## 2026-09-30T13:07:44+03:00 bdb875216070

decisions: F-1 и F-2 чиним до релиза (человек)

## 2026-09-30T13:06:48+03:00 2dd5cd12f938

HEARTBEAT: T3 — стоп на решение по F-1; убран префикс id гиста

## 2026-09-30T12:58:33+03:00 0a0c6165fb1d

HEARTBEAT: ревью правки 4 — можно к релизу

## 2026-09-30T12:47:32+03:00 e15944cee96a

HEARTBEAT: дельта-ИБ цикла 3, правка 4

## 2026-09-30T12:47:32+03:00 5c2e7d1b35e7

sync: правка 4 — учёт копий токена переживает смерть процесса, выход чистит все файлы токена, нет SS ≠ SS не отвечает, Мак: «Выйти» после неудачной отмены

L-1 pending до записи, L-2 безусловная чистка файлов токена, L-3 BaseException в _timed,
Мак M-1/M-2, docs. L-4 (неподтверждённые SS-записи) — остаточное окно, тикет после релиза.
Linux 159 OK, macOS селфтест 225 OK. developer-codex, GPT-6 Astra @high.

## 2026-09-30T12:27:40+03:00 b63cbcf8a99d

decisions: сверхлимитная правка двух находок — исправить сейчас (человек)

## 2026-09-30T12:23:28+03:00 57ffde1dc720

tests: покрытие цикла 3 — Linux 148 тестов, macOS селфтест 179 OK

2 expectedFailure (находки): ложное «Выход не завершён» без Secret Service;
Ctrl+C во время зависшей записи в KWallet оставляет неотслеживаемую копию.

## 2026-09-30T12:12:58+03:00 ee6474fbc6cd

sync: цикл 3 — одна копия токена на Linux, выход из трея в фоне, отмена входа, одно правило «стоит», подсказка у «Выйти»

18 пунктов по код-ревью и ИБ-ревью цикла 2 (+ Sol, Astra). developer-codex, GPT-6 Astra @high.
Селфтест macOS 167 OK, Linux 127 тестов OK.

## 2026-09-30T11:36:22+03:00 2f56047bc26d

HEARTBEAT: тесты, ИБ цикл 2, состав цикла 3

## 2026-09-30T11:30:44+03:00 4101dc9f9287

tests: регресс-тесты синка — Linux 52 новых теста, macOS селфтест M1–M10

Сценарии 401/вариант «а», поколения хранилища и зомби-операции, вход/выход,
allow-list и редиректы, raw_url, мерж чужих файлов, secret-гист, строка «стоит»,
отсутствие утечки токена, изоляция от реальных файлов (урок 006).
1 expectedFailure: Linux merge принимает "schema": true.

## 2026-09-30T11:23:15+03:00 fc964f991304

HEARTBEAT: код-ревью цикл 2 — нужен цикл 3 (N1–N4)

## 2026-09-30T11:14:08+03:00 f9b68100fb5d

decisions: отзыв токена на GitHub при выходе — нет (человек)

## 2026-09-30T11:14:07+03:00 aea881d47f6e

sync: правки по ревью — вариант «а», поколения хранилища Linux, allow-list хостов, валидация чужих файлов, secret-гист, синк после сна

macOS 3.1.3 / Linux 0.3.2: находки код-ревью, ИБ-ревью (обе платформы),
Codex-прохода Sol и второго мнения Astra. Сделано developer-codex (GPT-6 Astra @high).

## 2026-09-30T09:34:09+03:00 20a6d6ca0340

HEARTBEAT: второе мнение Astra; решение об объёме правок

## 2026-09-30T09:20:14+03:00 b4edf342c35e

HEARTBEAT: итоги ИБ-ревью Linux

## 2026-09-30T09:18:59+03:00 23228183f051

HEARTBEAT: итоги Codex-прохода Sol

## 2026-09-30T09:15:29+03:00 60a41c751106

HEARTBEAT: итоги код-ревью Linux 3ca05f2

## 2026-09-30T09:10:51+03:00 5806d50d473a

HEARTBEAT: лимит Codex снят, догоняем Codex-проход и мнение Astra

## 2026-09-30T09:09:09+03:00 f488be663f44

решение: политика отзыва входа — вариант «а» (повторная проверка /user перед отзывом)

## 2026-09-30T09:07:54+03:00 9bb38b0f99c9

HEARTBEAT: итог ИБ-ревью macOS (0 blocker/major, minor 1–5, решение человека по minor 2)

## 2026-09-30T09:06:09+03:00 b0406f2791ca

HEARTBEAT: итог код-ревью macOS (M1 ложная тревога после сна + minor)

## 2026-09-30T09:05:52+03:00 a0bc1e4f0548

HEARTBEAT: статус фикса синка перед компактификацией

## 2026-09-30T09:05:12+03:00 3ca05f2d9078

linux 0.3.2: 401 подтверждается через GET /user, отзыв снимает только новый вход, статус синка в ccl-sync status и в GUI, таймауты хранилища секретов

## 2026-09-30T08:58:16+03:00 73ef1a3fbded

macOS 3.1.3: синк не выключается молча после разового 401 (проверка GET /user, удаление только того же токена), гист читается каждый цикл, статус синка и предупреждение на экране, таймаут на security, подменяемый транспорт; протокол обновлён

## 2026-09-29T19:25:48+03:00 d566b5683ebe

память проекта: HEARTBEAT и журнал решений; инцидент синхронизации 29.09

## 2026-09-28T10:28:48+03:00 b14633932814

Merge pull request #5 from ArrivaRUS/linux-about-card

linux 0.3.1 — «О приложении» как на Mac

## 2026-09-28T10:25:16+03:00 973b251389aa

linux 0.3.1 — About row as on the Mac

The About card was a text line, a stack of buttons, the repository URL spelled out and the data
path. Now it is one row like the Mac's drawAbout: ⓘ Version x.y.z on the left, pill buttons on
the right (Check for updates · What's new + Download/Update), "Checking…"/"Downloading…" in
their place while busy, and a status line under the card (orange when an update is waiting).
The GitHub link stays in the Advanced view, as on the Mac.

Pills are sized from their text with the font the stylesheet gives them; the layout probe now
also fails when a pill clips its text.

## 2026-09-28T08:54:03+03:00 5d0aad7cb611

Merge pull request #4 from ArrivaRUS/astra-linux-settings-fit

linux 0.3.0 — пакет .deb, раздел Linux в README, настройки не уезжают под полосу прокрутки

## 2026-09-28T08:48:18+03:00 241973588889

linux 0.3.0 — .deb package; README: Linux section

- linux/packaging/build-deb.sh builds claude-codex-limits_<ver>_all.deb with dpkg-deb only:
  /usr/share/claude-codex-limits, /usr/bin wrappers, menu entry + icon, systemd user timer
  enabled globally; Depends python3-pyqt5, python3-dbus; xz for Astra 1.7's dpkg.
- linux/packaging/release.sh publishes it as release linux-v<ver> with --latest=false, so the
  Mac updater and get.sh keep reading the DMG release from releases/latest.
- Installed from the package: updates come from linux-v releases — the new .deb goes to
  Downloads and is opened in the system package installer; the tray restarts itself once the
  files on disk carry a new version. First launch turns autostart on (TryExec entry).
- ccl-sync push --auto exits at once for users who never signed in (the timer runs for all).
- README.md / README.ru.md: Linux install section instead of "in progress".
- Tests: package contents/modes/run, release pick, .deb download check, timer for non-users,
  settings layout with the package update button.

## 2026-09-28T08:35:46+03:00 40fd69bd0562

уроки 005–006: Linux-настройки под полосой прокрутки; тест, задевший настоящий keyring

## 2026-09-28T08:35:05+03:00 b4f81dfa0fcd

linux 0.2.1 — settings no longer run under the scroll bar

QCheckBox never wraps its caption, so the long notification toggle added in 0.2.0 made the
settings page wider than the popup; with no horizontal scrolling the right edge of every row
ended up under the vertical scroll bar (worst in Breeze, the KDE/Fly style). Toggles are now
a checkbox + wrapping caption, and a regression test builds the page offscreen for Fusion and
Breeze × ru/en × signed in/out and fails if anything is wider than the viewport.

## 2026-09-28T08:11:40+03:00 630f81f5432a

v3.1.2 — re-discover the earliest sync gist; show that the sign-in code was copied

Closes #3. The protocol's "earliest created_at wins" was applied only on the
first discovery, so two machines that each created a gist would never see
each other. GitHubSync.syncBody now re-runs findGist right after creating a
gist and once a day (syncDiscoveredAt), switching to the earliest one and
forgetting the push hash so this machine's file is written there. logout()
and a revoked sign-in clear syncDiscoveredAt. Schema stays 1.

The sign-in's Copy button reads «Скопировано» in teal for a moment after
Copy or Open (both put the code on the clipboard); width doesn't change.

## 2026-09-28T07:32:05+03:00 18056e0eb311

Merge pull request #2 from ArrivaRUS/astra-linux

Linux-порт для Astra Linux: ccl-sync + синхронизация через gist + значок в трее

## 2026-09-27T22:04:50+03:00 6b2c2fcd327d

linux 0.2.0 — desktop notifications and self-update from main

- A limit reaching 100% or a window resetting now also raises a desktop notification
  (Settings → Notifications & sounds; on by default). Alarm detection is a pure, tested
  function (port of checkAlarms).
- `ccl-sync update [--check]` and the tray (orange dot on the gear, Settings → Update,
  tray menu) install the newest Linux version from `main`: only linux/ + Resources/ are taken
  from the tarball (no links, no path escapes), its install.sh runs with the same autostart /
  timer choices, the tray restarts itself. A git checkout is left to `git pull`.
- The tray menu is built once, and the Codex icon gets its own menu — no more DBusMenu
  "No id for action" noise; install.sh no longer aborts if the timer can't be enabled.

## 2026-09-27T20:26:52+03:00 098dc04bc140

linux: review fixes — never lose a rotated token pair, no stale state overwrites, gist convergence

- Claude/Codex refresh: re-read with retries, fall back to the pre-refresh copy, keep an
  unwritten pair in memory and retry the write every poll (the server already rotated it).
- Store: read-modify-write of changed keys only, under a cross-process flock; login/logout
  run under the sync lock; a 401 deletes the stored token only if it is still the one refused.
- A keyring that is unreachable (cron without a session bus) is reported, not taken for a
  sign-out; cron line gets the bus address; the tray hands it to systemd --user if missing.
- Gist: re-discover after a create and daily, so two machines converge on the earliest gist.
- A failed raw_url download keeps the last merge instead of dropping that machine.
- Backoff honours Retry-After first, x-ratelimit-reset only when the budget is spent.
- machine-id: created once with O_EXCL-style link, never regenerated on a read error.
- Forced pushes (sign-in, rename) are queued instead of dropped while the timer is busy.

## 2026-09-27T20:14:15+03:00 fb3706f2eb83

linux: tell a locked keyring from a sign-out; thread-safe settings store; don't push a stale index while the timer scans; fit the Claude CLI help page

## 2026-09-27T20:12:43+03:00 a527b30f56d1

linux: lighter Codex fetch (live first, 1 MB rollout tail), safer refresh-error parse, limits tests

## 2026-09-27T20:09:10+03:00 477f746dcdee

linux: Astra Linux port — ccl-sync (usage index + gist sync) and the tray app

Stage 1 (linux/TASK.md): `ccl-sync login|logout|status|push|dump` — incremental index of
Claude Code (incl. subagents, per-day message-id dedupe) and Codex (token_count) logs, GitHub
Device Flow, Secret Service or 0600-file token, one secret gist, machine-<id>.json exactly per
docs/sync-protocol.md v1. systemd --user timer (cron fallback) every 10 minutes.

Stages 2–3: PyQt5 tray icon with the chosen percentages, and the panel ported from drawPanel /
drawAdvanced — rings, pace per window, 7-day bars by model, 35-day calendar, money — with usage
merged from every machine in the gist. Claude token refresh writes back atomically and never
overwrites a pair the CLI rotated itself.

Standard library + OS-repo PyQt5 only; everything under $HOME, no sudo.

## 2026-09-27T18:16:49+03:00 e014a184097e

v3.1.1 — bring the author · GitHub credit line back to the Advanced view

The Advanced layout dropped the credit line from the Simple view, and with
it the only link to the repository. It's back under the footer (divider +
the same line), and advancedHeight() grows by ADV_CREDIT_H.

## 2026-09-27T11:10:26+03:00 c2055540f1bb

v3.1 — combine usage from several computers through a GitHub gist; sounds get their own screen

Sync (docs/sync-protocol.md): GitHub Device Flow with scope `gist`, token in
the Keychain via `security -i` on stdin; one secret gist found by its
`ccl-sync.json` manifest; each machine writes a whole snapshot of daily
per-model token totals to `machine-<id>.json` only when it changed, reads
the others, and the history draws from local + remote (`mergedUsageIndex`).
Pure merge covered by `--sync-selftest`. 401 → "sign-in revoked" state.
Settings block «Другие компьютеры · через GitHub» (Advanced only); the
history header shows «· N ПК».

Settings no longer outgrow the screen: the three sound cards moved to their
own screen behind a «Звуки ›» row with a summary.

Fixes: preview hooks restore the user's defaults instead of wiping them;
no re-entrant lock in GitHubSync.setUI (froze the app after sign-in).

## 2026-09-27T09:35:55+03:00 4b25e25793fb

docs: sync protocol — GitHub OAuth App Client ID

## 2026-09-27T09:35:29+03:00 222f512bb23d

v3.0.1 — forecast tail takes the bar's own colour

The Advanced view drew the forecast tail in the window's base colour while
the fill follows the usage ramp, so a 70% weekly bar was amber with a purple
tail. The tail now uses the fill colour at 0.30 alpha, and the header legend
swatch is neutral grey.

## 2026-09-27T09:33:39+03:00 1adb3e6a0a81

docs: usage sync protocol v1 + Astra Linux port task

docs/sync-protocol.md is the contract between the macOS app and the coming
Linux port: one secret gist, one whole-snapshot file per machine with daily
per-model token aggregates, GitHub Device Flow with scope `gist`, merge by
plain sum excluding the reader's own machine.

linux/TASK.md is the brief for a Claude Code session on Astra Linux SE:
stage 1 collector + sync CLI, stage 2 tray with limits, stage 3 Advanced
parity; Python 3 + PyQt5 from the OS repo, no pip, respect ЗПС/МКЦ, write
refreshed Claude tokens back atomically, work in branch astra-linux.

## 2026-09-24T11:36:43+03:00 efb6d8046b9e

v3.0 — Advanced view: pace per window, bars by model, calendar, money

A second panel layout (Settings → Panel view → Advanced). Every limit window
gets a pace line — linear-plan position, ±points, average rate and a plain
verdict («Хватит до сброса (прогноз 53%)» / «Кончится в 09:37, за 2 ч 13 мин
до сброса»). Claude rows: session → per-model week → all-models week; Codex
shows a session row only if the backend reports one (the 5-hour window is gone).

History card (collapsible, per product): 7 days as bars stacked by model in $
at API prices, a 35-day calendar heatmap, and money — $/day on the subscription
vs what the same tokens would cost via API, with the ratio.

Data layer: UsageLogs indexes the CLIs' own transcripts incrementally with
memmem (Claude ~/.claude/projects incl. subagents/agent-*.jsonl with per-day
message-id dedupe; Codex ~/.codex/sessions rollouts, input minus cached);
UsageHistory samples utilisation to ~/.claude-limits-monitor/history.jsonl;
MODEL_PRICES table; subscription price from the plan (Claude rateLimitTier,
Codex plan_type) with overrides in Settings. Percentages and pace are
account-wide; bars/calendar/money cover this Mac only.

CLI hooks: --advanced-dump, --advanced-preview <dir>; --screenshots renders
docs/advanced(-en).png from demo data. READMEs: feature bullet, How-it-works
paragraph, screenshot.

## 2026-09-24T07:25:10+03:00 f52ac2e93620

v2.9.2 — resize the open panel when refreshed data changes its height

The panel was sized once, in show(), for the data present at click time —
and opening it triggers a refresh. When that refresh added or dropped the
per-model row (cards ±15pt) update() only redrew, so the taller content ran
past the window's bottom edge and the footer line got clipped. update() now
compares the needed height with the frame and calls resizeToContent().

## 2026-09-05T11:34:17+03:00 512c9d4f3441

память: .patches/INDEX.md — индекс уроков (правило Юрки 2026-09-02, HANDOFF §5)

## 2026-08-16T20:18:32+03:00 76cb00a12352

v2.9.1 — say "sign-in expired" instead of silently serving yesterday's numbers

When both tokens of the saved CLI login expired, .expired was only set for an
EMPTY access token — an expired-but-present one slipped through, so the card
just greyed out with stale data and the app kept polling the API with a dead
token every 5 minutes until it earned a 429.

- treat a token expiring within two minutes as spent; if the refresh token is
  also gone, surface .expired with a "sign-in expired" error
- remember (by FNV-1a fingerprint, never the token itself) a refresh token the
  server refused with invalid_grant and stop calling the API entirely until the
  keychain holds a different one — a fresh `/login` re-arms the check on its own
- map usage HTTP 401 to .expired too
- the "How to fix?" walkthrough now adapts: an expired login gets `claude` →
  `/login` and an explanation of why the desktop-app session doesn't help,
  instead of the first-install curl/PATH steps

## 2026-07-26T23:22:07+03:00 b567d87f92aa

v2.9 — you pick which limits the menu bar shows, and in which order

The tray fits two numbers per product and they were hardcoded to session/weekly,
which is often not the limit you're about to hit: a per-model weekly can be at
100% while the overall week is half free.

- Settings → «В строке меню»: one segmented group per side of the slash, so the
  control reads like its own result («Fable / нед» → "100/86%").
- The stored order IS the left-to-right order; picking what's already on the
  other side swaps the two instead of showing it twice. The right side can be
  cleared to «—» for a single number.
- A product carrying none of the picked metrics (Codex has no per-model limit)
  falls back to what it does have rather than rendering a bare icon.
- The per-model number keeps its own ramp in the tray too, darkened for light
  menu bars where the bright teal would be unreadable.
- Settings section offsets now derive from shared constants instead of the
  hardcoded tops that would have drifted the moment a row was inserted.

## 2026-07-26T22:43:52+03:00 3c45979b890a

v2.8.2 — give the per-model limit its own colour ramp

The scoped limit shared the amber/red severity ramp with the weekly
one, so a card could show a red 100% pill beside a red weekly ring with
nothing to tell them apart — "is Fable spent, or is the week?".

scopedColor() replaces metricColor() for this metric: teal below 50%,
coral to 80%, magenta above. Still legibly an alarm, but distinct from
the weekly's amber and red at every level, so the ambiguity is gone in
the mid range too, not just at the top. Applies to both the pill and
the row dot, which are drawn from the same value.

## 2026-07-26T22:33:06+03:00 b4a95ae8d865

v2.8.1 — fix the footer divider striking through the credit line

The divider and credit text were positioned at hardcoded offsets from
the top of the panel (256 / 265), tuned when the panel was always 286pt
tall. v2.8 made the cards grow by a row for a per-model limit, which
pushed the interval row down into those fixed coordinates — so the
hairline crossed the pills and struck through the credit text.

Both are now derived from footTop, keeping their spacing from the
interval row at any card height. The values are unchanged for the
original 286pt layout, so nothing moves when no per-model limit exists.

## 2026-07-26T22:19:27+03:00 72b9c4c72701

v2.8 — surface per-model weekly limits (Fable) + chime on any limit

Anthropic's usage endpoint grew a structured `limits[]` array carrying
something the flat fields cannot express: per-model weekly allowances
(kind "weekly_scoped", named by scope.model.display_name). It is the
limit you actually hit first — Fable can sit at 100% while the overall
weekly is at 84% — and the old per-model fields (seven_day_opus etc.)
now return null, so this array is the only source for it.

The Claude card gains a percentage pill in the ring's lower opening
(text-only so it clears the arc, tinted so a red 100% doesn't read as a
second bare red number) plus a named row with its reset time, in a
third identity colour. Cards and panel grow by that row only when such
a limit exists and the card is live — logged-out and stale layouts are
unaffected. `limits[]` also backfills session/weekly should the flat
fields go the way of the per-model ones.

Reached-alerts now cover the scoped limit (keyed per model), the
settings caption says "when ANY limit is reached", and its rollover
chimes like any weekly window. A nil reading no longer clears the
persisted reached flag, which would have re-announced an already-hit
limit after a failed fetch.

## 2026-07-19T21:14:04+03:00 3bc8e05a73ce

v2.7.2 — don't grey the card over a single failed poll

The v2.5 staleness treatment fired on ANY fetch error, so one throttled
request (429) greyed the Claude card even though the cached reading was
a minute old — "as of 21:08" next to "updated 21:09" looked absurd.

isStale() now judges by the AGE of the last good read: an error only
greys the card once the snapshot is 15+ minutes old (a real failure
streak), while a reset moment in the past stays conclusive on its own
(with a 2-min rollover-jitter buffer) and an error-free read over an
hour old still counts as stale. Verified with a 10-scenario table test
covering the false positive and every real-stale case.

## 2026-07-19T15:52:33+03:00 e1cd7856a13a

gitignore: *.local.md — локальный тайм-леджер Юрки не для публичного репо

## 2026-07-19T15:43:45+03:00 6407b05780cd

v2.7.1 — tray digits follow the menu bar's real appearance, not the system theme

## 2026-07-19T15:29:42+03:00 20156b2b4452

v2.7 — guided Claude Code login walkthrough + weekly % in the menu bar

## 2026-07-19T14:41:51+03:00 10f213624ee8

v2.6 — fix silent exit on fresh Macs + one-command installer

## 2026-07-17T13:00:06+03:00 1d6b590215bf

v2.5 — never pass off a stale snapshot as live Claude data

When Claude Code's Keychain credentials expire and the token refresh
fails, the app used to keep showing the last good reading — including a
5-hour reset time that had already passed — with no sign it was frozen.
A user reasonably read that past time as a bug.

Now a card is stale on any of: an auth/fetch error, a reset moment
already in the past (impossible for a live rolling window), or no
successful read in over an hour. A stale card greys its ring + numbers
and swaps the reset lines for "as of <last read> · re-open <product> to
refresh"; the menu-bar strip fades the stale product too. It recovers
on its own the next time the credential is refreshed. Codex unaffected
(separate token).

## 2026-07-12T22:56:55+03:00 19be4f71a472

v2.4.2 — move the Codex resets badge under the weekly %

Relocate the ⟳N banked-resets pill from the card header to just below the
weekly percentage, centered in the ring's lower opening. Regenerated docs
screenshots + bumped the image cache-buster (?v=242).

## 2026-07-12T22:36:33+03:00 14d202f74d9e

v2.4.1 — align the Codex resets badge with the card title

Nudge the ⟳N reset-credits pill down ~3.5px so it's vertically centered on
the "Codex" title. Regenerated docs screenshots + bumped the README image
cache-buster (?v=241) so GitHub shows the new panel with the badge.

## 2026-07-12T22:28:44+03:00 5cb2c714514e

v2.4 — show Codex banked rate-limit resets

Codex's "reset banking" lets you save rate-limit resets; the live usage
response exposes the count in `rate_limit_reset_credits.available_count`.
Read it into LimitData.resetCredits (cached too) and show it as a small
orange ⟳N pill in the Codex card header when you have ≥1 banked reset.

## 2026-07-12T22:13:41+03:00 8c15468de195

v2.3.4 — map Codex windows by duration, not slot

Codex sometimes returns only one usage window, and the window it puts in
"primary" isn't always the 5-hour one — with little recent activity it
returns just the 7-day (weekly) window as primary, with secondary null. We
mapped primary→Session, secondary→Week by position, so the weekly value
landed under "Session" and "Week" showed "—".

Now each window is classified by its own duration (limit_window_seconds /
window_minutes): ~5h → Session, ~7d → Week — regardless of slot or how many
windows the backend sent. Falls back to the positional guess if a window
has no duration field. Applies to both the live endpoint and the local
rollout fallback.

## 2026-07-01T16:10:18+03:00 8a0dfa56a46f

docs: cache-bust README screenshots (?v=233)

The screenshots in docs/ are already current (thin toggles, v2.3.3), but
GitHub proxies and caches README images, so the old ones can linger. Append
a version query to every image src to force a fresh fetch.

## 2026-07-01T15:06:06+03:00 08ebd9342af7

v2.3.3 — thinner toggle switches

Slimmer toggles to match the compact settings: height 20 → 16, and the
knob now nearly fills the track (2px inset instead of 3) so it reads as a
thin pill rather than a chunky one. Regenerated docs screenshots.

## 2026-07-01T14:46:40+03:00 6ac894285dec

v2.3.2 — more compact Settings

Tighter Settings layout so it isn't stretched down the whole screen:
- Row height 44 → 36 (general + reset-toggle rows), sound rows 33 → 29.
- Smaller toggle switches (38×22 → 34×20) — less visually heavy.
- settingsTotalHeight recomputed to match exactly (also fixes a small prior
  drift). Overall panel ~74pt shorter.

Regenerated docs screenshots (RU/EN).

## 2026-07-01T14:17:00+03:00 d0f95331a1f0

v2.3.1 — reopen the popover on the main screen, not where you left off

When the popover is dismissed (clicking away / losing focus / tapping the
tray icon), reset it back to the main screen. Previously the mode was only
reset in show(); doing it in hide() covers every dismissal path, so after
leaving it on Settings (or What's new) the next open always starts on the
main screen. Also resets the What's-new scroll position.

## 2026-06-30T23:18:45+03:00 13aca15ae94b

v2.3 — compact language switch + launch-at-login toggle

Settings now opens with a "General" card:
- Language: a compact EN | RU segmented control on the right of the row
  (replaces the full-width two-button control).
- Launch at login: a toggle, surfacing the existing LaunchAgent option that
  was previously only in the right-click menu.

Regenerated docs screenshots (RU/EN) to show the new Settings.

## 2026-06-28T10:35:20+03:00 9e153d924a4a

docs: refresh README + regenerate screenshots (RU/EN, v2.2.2)

- Regenerate all docs/ screenshots from the live draw code, now showing the
  current UI: language selector + version 2.2.2 in Settings, the colour
  gauges, and a new "What's new" screen shot.
- Bilingual screenshots: README.md (English) uses the English-UI shots
  (*-en.png); README.ru.md (Russian) uses the Russian-UI shots.
- Add a permanent `--screenshots` hook that regenerates docs/ for both
  languages (run the built binary from the repo root).
- Refresh the Settings caption (language · sounds · updates) and add the
  "What's new" screenshot + caption to both READMEs.

## 2026-06-28T10:24:51+03:00 c41bcd24fe97

v2.2.2 — fix: status message didn't follow the language switch

The "you're on the latest version" / "couldn't check" / "download failed"
line at the bottom of Settings was stored as a pre-translated string at the
moment of the check, so switching the language afterwards left it in the old
language. Now the about line stores a kind (AboutMsg enum) and is localized
at draw time, so it follows the language toggle like everything else. Same
for the What's-new empty-state message.

## 2026-06-28T10:05:11+03:00 6416571e9fc2

v2.2.1 — fix: "limit reached" sound swallowed by restart

The limit-reached alert was gated on the in-memory `soundBaseline`, which
resets every launch. On the first reading after launch the code recorded
rch_* = reached WITHOUT playing the sound, then returned — so a limit that
was already at 100% when the app (re)started got marked "reached" silently
and never alerted again until it reset and re-crossed while running.

Fix: the reached alert is driven purely by PERSISTED state (rch_*), so it
no longer depends on soundBaseline and fires once per crossing — including
on the first reading after launch (limit hit while the app was closed).
Threshold relaxed to >= 99.5 to match the rounded "100%" shown. Reset
chimes keep the in-memory baseline (they need it for resets_at detection).

## 2026-06-28T09:57:27+03:00 40fb015ce339

v2.2 — interface language (RU / EN)

Adds a language selector in Settings (Русский | English, Russian by
default). Every UI label renders in the chosen language; reset dates use
the matching locale. Release notes are localized too: a release body may
carry both languages between <!--RU--> / <!--EN--> markers and the app
shows the section for the current language (falls back to the whole body
if unmarked).

- tr(ru:en:) / appLang() localization helpers; "lang" in UserDefaults.
- Localized: panel, settings, what's-new, status messages, context menu,
  sound names, fmtReset locale.
- localizedBody() parser; notes render in the selected language live.

## 2026-06-28T09:35:39+03:00 ac1a8b7653ac

v2.1 — "What's new" release-notes screen

Next to "Скачать" there's now a "Что нового" button. It opens a dedicated
screen listing the release notes for EVERY version newer than the running
one (so a user who skipped several versions sees the whole accumulated
changelog), and lets them jump straight to the latest from there.

- releaseNotesSince() pulls /releases and keeps entries newer than current.
- New PanelMode .whatsnew with a scrollable CoreText viewport (scroll wheel
  + thumb), light markdown tidy, and a phase-aware action footer
  (Обновить до X → progress → Установить и перезапустить).
- About card shows "Что нового" + "Скачать" side by side when an update is up.

## 2026-06-28T09:19:01+03:00 788cfd89e92c

v2.0 — fully automatic update checking

Background update checks (on launch + every 6h). When a newer release is
found, a dot badges the menu-bar icon and the ⚙ gear. The About card in
Settings drives a two-step flow: "Скачать" → live progress bar →
"Установить и перезапустить" (download via URLSessionDownloadTask with
progress, then the detached swap-and-relaunch helper).

- New: UpdatePhase (idle/downloading/ready) on AboutState; UpdateDownloader
  (progress callbacks); AppDelegate.startUpdateChecks/autoCheck/startDownload/
  installAndRelaunch; tray + gear "update available" badges.
- Replaces the old one-shot performUpdate + manual-only check.
- Still no Sparkle, no notarization: the app downloads the dmg itself, so it
  isn't quarantined and Gatekeeper stays silent.

## 2026-06-24T19:55:34+03:00 9c540241af1a

v1.9 — reset chime fires only on a real window rollover

Harden reset-sound detection so it can only fire at the actual moment a
limit window rolls over, never while usage sits at a constant level
(including 0% while idle). A reset now requires all of:
  • resets_at jumped forward (a new window boundary appeared),
  • usage was non-zero in the window that's ending (oldUsed > 0),
  • usage did not climb (it drops to ~0 at a real reset).
This also rules out a false chime if a window's reset time ever crept
forward instead of jumping. Stores last usage per window (use_* keys).

## 2026-06-23T17:44:40+03:00 f11e1d628383

docs: add social-preview banner (1280×640) + README header

Rendered with CoreGraphics + CoreText (scripts/make-banner.swift), same
dependency-free path the app uses. Shown at the top of both READMEs and
intended for the GitHub repo Social Preview.

## 2026-06-20T19:18:07+03:00 74acb8072ee9

v1.8 — compact "About" card, no empty space

The about/version card now hugs its single row; the status line ("update
available" / "up to date" / error) appears below it only when present, and the
settings panel resizes to fit. Fixes the empty gap under the version.

## 2026-06-20T18:35:57+03:00 719290970f3b

v1.7 — built-in update check & one-click self-update

Settings screen gains an "О приложении" section showing the version and a
"Проверить обновление" button. It queries the GitHub releases API; if a newer
version exists it shows "Обновить", which downloads the release .dmg and hands
off to a detached updater that swaps the app bundle and relaunches.

## 2026-06-18T14:17:48+03:00 d0d64c324d0d

v1.6 — settings screen + sound alerts

In-app settings screen (gear) in the app's own design language, replacing the
native menu. Optional sounds: per-event cheerful chime on a 5h/weekly reset
(separate sound for each), and a sad shutdown-style tone when any limit is
reached. 7 cheerful + 3 sad sounds, with in-app preview.

## 2026-06-15T17:17:51+03:00 a67f866ebf06

v1.5 — Codex always live (timer + launch + open)

Live Codex usage now refreshes on every tick (launch, the 1/5/15-min timer, and
popover open) — not just on open — so the tray stays in sync with the Codex web
page continuously, like Claude. Falls back to local logs if a call fails.

## 2026-06-15T17:12:23+03:00 a634688874e1

v1.4 — live Codex usage from the ChatGPT backend

Codex limits were read only from local session logs, which go stale when you use
Codex on the web (windows reset → wrong numbers). Now, on panel open / manual
refresh, the app fetches live usage from the same backend the Codex CLI uses
(GET /backend-api/wham/usage), authenticated with ~/.codex/auth.json and
auto-refreshing the token via OpenAI's token endpoint when expired. Background
ticks stay local. Matches the Codex web page.

## 2026-06-15T11:06:33+03:00 8c7716c28d1f

v1.3 — brighter tray separators

The "/" and "%" in the menu-bar readout are now ~95% white (matching the
numbers) instead of 50% — easier to read. Bump version to 1.3.

## 2026-06-14T22:58:15+03:00 3212a55a27f0

v1.2 — release with the custom app icon

Bump version to 1.2 (app credit line, build/dmg scripts, docs).

## 2026-06-14T22:36:16+03:00 c1c30e8f2b61

Custom combined app icon + single-product layout polish

- Own app icon (dark tile, dual glowing gauges + center %) replacing the
  borrowed Claude glyph — used in the popover header, the .app bundle and .dmg.
- Single-product mode: tray row is larger (icon 19pt, medium-weight text);
  popover header always shows the app's own icon.
- Remove the temporary single-product test stub; both products show again.
- Refresh docs screenshots.

## 2026-06-14T20:46:19+03:00 40e013af49ae

v1.1 — force refresh on open, GitHub credit link, single-product layout

- Opening the popover now triggers an immediate refresh.
- Credit line gains a clickable "GitHub" that opens the repo.
- If only Claude Code or only Codex is set up, the tray shows one row and the
  popover one card (dynamic header + present-only detection).
- Bump version to 1.1; docs (EN/RU) updated with the single-subscription view.

## 2026-06-14T20:33:47+03:00 2659f5176ae8

Claude Codex Limits 1.0 — macOS menu-bar monitor for Claude Code & Codex limits

Native NSStatusItem app: two-row tray readout (session/weekly %) with brand
icons, a custom System-Control-style popover with ring gauges, clickable cards,
interval picker, launch-at-login. Bilingual docs (EN/RU), build/install/dmg
scripts. No dependencies beyond the macOS Swift toolchain.

