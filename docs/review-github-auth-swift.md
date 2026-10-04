# GH-AUTH-STABLE: независимое Swift review

## C3: фактический auth RUN и новый finding

Root после отдельного isolation PASS выполнил frozen `--auth-selftest`:
**30767 checks, 0 failures**, exit0, `/tmp/ccl-auth-final-swift.log`.
SHA core `b1683f6bd0b6fbaf7872b0313d8ac2c2947cb64017bb27021a70de536a970675`,
main `32b41704d0677c825adfe2f6ed12dfd73d9d1c1dad2a34ec7b2853fc6ea38984`,
tests `1e330e18eff3b5d057a79408a3e3e378ba218237a0995b0d7c84727eb459a88e`.
Это не acceptance: свежий CodeReviewer нашёл P1 staged candidate, чей access
истёк до успешного `/user`, навсегда остаётся pending без использования refresh.
Нужна автоматическая recovery действующего staged refresh с теми же fences.
Security P2 initial probe settlement описан в security-github-auth.md.
Обычный `--sync-selftest` не запускать: читает реальные usage logs; старые
preview также запрещены. Остальные preview/selftest ждут отдельной изоляции.

2026-10-04. CodeReviewer GPT-6 Astra/high, контекст отдельный от автора.
База `eef4b77` + frozen source: core `dbc48af5c289cf53fccad7b4c893926744ce0c1703ecf06682a29a5545cef64d`,
main `d947ced0157d3f41876421143ef38639a66004a2790221ff0b70283c094d4805`,
build `db635a40f9bd933f8fe37c064e66cf6375927be8660595c2c2ca16a2c37cf9fd`.
Reviewer проверял только чтением, hashes совпали в начале и конце.

## Цикл 1 — НЕ PASS

| ID | Приоритет / исходная строка | Требуемое исправление |
|---|---|---|
| S1 | P1 core502/main1808 | Logout Bool лишь tombstone, UI скрывает незавершённое удаление. Различать disabled/deleted, pending snapshot и cleanup retry. |
| S2 | P1 main1684/core384 | Failed/expired device flow оставляет prepared login без candidate, maintenance показывает false on/login_pending без кнопки входа. Адресный abort no-issuance, отдельно pending validation после выдачи. |
| S3 | P1 core220/258 | Late writer userID=nil перезаписывает identity metadata после publish; restart теряет account fence. Settlement перед publish либо immutable authoritative identity вне late payload. |
| S4 | P2 core209/416 | Uncertain/missing refs не завершают cleanup, healthy path не вызывает GC. Trusted settlement и bounded maintenance GC. |
| S5 | P2 main1462 | Legacy syncRevoked превращается в temporary/on без recovery login. Сохранить terminal action. |
| S6 | P2 core189 | 600+jitter при cadence600 пропускает ближайший tick и откладывает до1200. Общий ordinary backoff максимум600. |
| S7 | P2 core437 | Первый bad_refresh_token пропускает fallback на usable access, блокирует рабочий sync. Одинаковая policy первого и повторных вызовов. |

DeveloperComplex исправляет цикл 1; независимая повторная проверка обязательна.

## Узкая изоляция и фактический первый запуск

Reviewer дал PASS только `/tmp` copied build + `--auth-selftest`, frozen selftests
`032bf940b8c7ef8ed5b751e158941324462e86e5f076b7f79f5e4a4532d2f174`.
Memory injected deps, ранний exit до startup/AppDelegate/production factories.
Это не production acceptance, full suite или проверка живого UI.
Root скопировал exact frozen sources в `/tmp/ccl-gh-auth-c1.rKYs3l`, compiled
swiftc -O (exit0, inherited verdict warning), затем запустил только approved arg.
Результат: 30657 checks / 1 failure, exit1: `bad refresh keeps usable access`.
Проверка независимо воспроизвела S7; успешный полный PASS не заявляется.
Реальные credentials/keychain/API/defaults/logs не использованы.
