# GH-AUTH-STABLE: независимый QA готовых артефактов

2026-10-04. QA GPT-6.1 Sol/high, отдельный контекст. **PASS в назначенной области: синтетические пользовательские сценарии по фактическим журналам, визуальные fixtures и offline-упаковка.** Новых блокирующих QA-дефектов не обнаружено. Это заключение специалиста координатору; оно не заменяет live проверку и итоговую приёмку выпуска.

## Ревизия и область

PROJECT_ROOT: `/Users/arrivarus/Documents/VibeCoding2/2026_06_UsageLimits`.
Проверенный HEAD: `40cfdf58980acef0668bdb4915c6001322ba9e11`, ветка `codex/stable-github-auth`.
На старте и после визуальной/пакетной проверки tracked/untracked изменений не было. QA создал только этот отчёт и временные QA-артефакты в `/tmp/ccl-auth-final-qa/`; исходники, тесты, конфигурация и Git не изменялись. После записи отчёта final `git status --short` выявил также параллельные изменения шести чужих документов: `README.md`, `docs/project-guide.md`, `docs/release-notes-3.2.3.md`, `docs/release-notes-linux-0.4.3.md`, `docs/sync-protocol.md`, `linux/README.md`. QA их не менял и не проверял; координатор уведомлён, проверка этой области остановлена. Новый `docs/qa-github-auth-stability.md` — единственная запись QA в репозитории; проверяемый код прежний.

Входы: AGENTS.md проекта/HQ, codex-only.md, HQ/now.md, HEARTBEAT.md, decisions/log.md, .patches/INDEX.md, PRD/test-plan GH-AUTH-STABLE, UI test-plan, source fixtures и independent Code/Security reports. Исторические pending/FAIL в заголовках памяти сверены с финальными журналами, относящимися к этому HEAD. Предыдущий QA AUTH-1 использован лишь для классификации известного P3.

Фактическая ОС QA: macOS 26.6.2 (25G83), Darwin 25.6.0, arm64. Linux evidence: GitHub Actions run **37192768494**, Ubuntu **22.04.5 LTS**, Qt/PyQt5 offscreen. Checkout SHA прямо присутствует в CI log. Реальная Astra Linux/KDE/Fly и Linux-аппаратура не предоставлены. Это проект Claude Codex Limits, не AstraVoice; звук, hotkeys, вставка текста и QML не менялись и не проверялись как голосовые сценарии.

## Реально просмотренные изображения

Финальный macOS packaged selftest дал **182 уникальных PNG**: 42 GitHub auth + 88 AUTH-1 hints + 40 Auto UI + 12 subscriptions. Просмотрены все 182. Linux CI содержит **192 PNG**: 36 GitHub auth + 156 регрессионных; просмотрены все 192. Итого финальный визуальный осмотр — **374 изображения**, без учёта повторного первичного просмотра 42 macOS GitHub PNG до упаковки.

Изображения открывались через `view_image(detail=original)` в contact sheets: macOS retina bitmap720 приводился к реальному размеру панели360pt; Linux360px оставлен в исходном масштабе. Первичные storage-locked/cleanup-pending также открыты отдельными оригиналами. Имя каждого PNG, размер и SHA256 сохранены в `/tmp/ccl-auth-final-qa/image-inventory.json` и `bundled-image-inventory.json`.

Первичный macOS render не имел bundled icons. Координатор затем выполнил selftest из mounted DMG и ожидаемо перезаписал все 42 GitHub PNG (иконки/время). QA повторно создал `mac-final-00…06.png` и просмотрел все финальные 42, затем 140 regression PNG в `mac-regression-00…23.png`. Финальные SHA256 всех182 macOS и192 Linux изображений повторно сверены после просмотра: изменений нет. Первичные sheets не подменяют packaged evidence.

macOS originals: `/tmp/ccl-github-auth-{settings,main}-*.png`, `/tmp/ccl-auth-hints-*.png`, `/tmp/ccl-auto-ui-*.png`, `/tmp/ccl-subscriptions-*.png`. Linux originals: `/tmp/ccl-auth-final-ci-artifacts/linux-previews/`. Sheets: `/tmp/ccl-auth-final-qa/{mac-final,mac-regression,linux-github,linux-regression}-*.png`.

| Сценарий | macOS RU/EN | Ubuntu RU/EN | Наблюдение/граница |
|---|---|---|---|
| Healthy и legacy healthy | PASS, Settings+Simple/Advanced | PASS ready; legacy в lifecycle | Здоровый статус без ложной ошибки/повторного входа; fixture account, не реальные данные. |
| Renewing | PASS | Восстановление в typed temporary fixtures + lifecycle | Автоматическое продление объяснено; macOS account сохранён, login отсутствует. |
| Storage locked/unreachable, offline | PASS locked | PASS locked/unreachable/network | В Settings причина и sign-out; нет ложного revoked или login при temporary. |
| Identity pending | PASS | PASS | Сохранённый вход/автоматический retry, без требования нового device flow. |
| Cleanup pending после local logout | PASS | Cleanup lifecycle по CI | macOS прямо сообщает локальное отключение/незавершённую очистку. Явный Sign in допустим после logout; исход ещё не назван завершённой очисткой. |
| Terminal missing/lost result/invalid refresh | PASS lost-result fixture | PASS все три Settings/main | Одно явное login действие; missing local key не объявляется server revoke. |
| History collapsed, Advanced | PASS | Warning hit bounds по CI | macOS auth warning видим при свёрнутой истории. Simple macOS auth warning отсутствует по существующей структуре; Settings доступен. Linux новые main fixtures имеют раскрытую историю. |
| Login/sign-out bounds и маршрут в Settings | PASS визуально + assertions | PASS визуально + click fake slot assertions | Кнопки/нижние controls не перекрыты. QA не выполнял real mouse/device/browser действия. |
| Смена account A→B, failed first read | Assertions PASS | Actual apply_days/pipeline assertions PASS | Чужой remote cache исключён тестами; screenshot fixture с реальными A/B данными не создавался. |
| Claude read error/logout/expired рядом со stale Codex | PASS* все88 PNG | PASS* regression PNG | Codex stale не получает ложную login команду; команды Claude относятся к Claude. |
| Auto, single/both/none subscriptions, paused | PASS 52 PNG | PASS regression | Auto и фиксированная частота различимы, controls в пределах панели, без новых overlap. |

* Унаследованная косметическая P3 остаётся: длинная подпись readError выходит за узкую Simple-карточку при двух продуктах. Воспроизведение: synthetic Claude read error → Simple → both subscriptions; открыть `/tmp/ccl-auth-hints-claude-read-error-ru-advanced-false-both-true.png` либо Linux `auth-claude-readError-ru-False-True.png`. Текст Keychain/file-access шире левой карточки. Дефект уже описан в `docs/qa-auth-hints.md` и оставлен координатором в backlog; новый GH-AUTH-STABLE его не вводит.

Длинные новые notices в однострочном main warning и macOS lastError сокращаются многоточием. Примеры: RU storage-locked, RU terminal; prefix причины видим, кнопки целиком читаются. Linux Settings переносит полный текст, macOS Settings terminal имеет явную кнопку «Войти заново», locked сохраняет только «Выйти». Это ограничение полного чтения длинных пояснений, не подтверждение нового блокера или потери auth. Снимки не доказывают работу настоящего хранилища.

## Проверенные журналы и пользовательский lifecycle

QA **не перезапускал** auth/sync/subscriptions/unittest suite. Запуски сделал координатор после отдельного isolation review; ниже — результаты, независимо прочитанные QA. Совпадение test body с заявленными сценариями проверено чтением `Sources/GitHubAuthSelfTests.swift`, `linux/tests/test_auth_lifecycle.py`, `test_auth_integration.py`, `test_github_auth_ui.py`. PASS строка не используется как доказательство live issuer/backend.

| Сценарий PRD | Фактическое доказательство на frozen source | Результат |
|---|---|---|
| A1 30/180 simulated days | Swift и Linux core: 4320/25920 ticks 600 s, 4321/25921 authorized gist reads, 91/551 одноразовых renewal; один initial login. Linux actual pipeline: ежедневный durable restart,30/180 refresh, ≥31/181 protected reads,0 new device flow. | PASS assertions в успешных suite; годы/месяцы не ожидались реально. |
| A2 legacy без refresh/expiry | Swift181 protected reads за180 simulated дней,0 refresh/0 forced login/0 migration. Linux actual pipeline30/180 дней без нового grant/authV2 migration. | PASS synthetic. |
| A3 sleep2/6 недель | Fake clock jump, no sleep activity, один renewal при wake; Linux scheduled GUI actual callback с Advanced off/stale index/limits disabled получает authorized marker и0PATCH. | PASS synthetic; настоящий sleep не выполнялся. |
| A4–A5 сеть/storage | Offline/timeouts/429/5xx/backoff, delayed/locked/unavailable storage и следующая попытка ≤600s при здоровых зависимостях. | PASS synthetic. |
| A6–A8 конкуренция/logout/crash | Linux process/signal/durable fixtures, Swift injected epoch/store/lock/checkpoints; pending candidates/late writers и local-only logout. | PASS fixtures; native DBus/Keychain daemon races не воспроизводились. |
| A9 lost rotation result | Durable candidate recovery, persisted unknown request budget, terminal lost-result UI с одним explicit login. | PASS fixtures; не обещает recovery после невозможной потери единственной новой пары. |
| A10 triple401/terminal | Legacy triple401 regressions и recovery до требования login; usable access после bad refresh проверен отдельно. | PASS fixtures. |
| A11 parser/transport/secrets | Полная пара/issuer TTL/malformed/redirect и exact endpoints/nonsecret manifest assertions. | PASS fixtures + прежнее independent Security static review; native ACL не проверен. |
| A12 RU/EN UI + regressions | 374 фактически просмотренных PNG + callback/hit-bound assertions. | PASS в bitmap scope, с ограничениями/P3 выше. |

Финальные журналы:

- `/tmp/ccl-auth-mac-final-auth.log`: `AUTH SELFTEST: 30862 checks, 0 failures (synthetic dependencies only)`.
- `/tmp/ccl-auth-mac-final-sync.log`: `OK regression cases: all passed`.
- `/tmp/ccl-auth-mac-final-subscriptions.log`: **1218 строк OK**,42 new GitHub PNG, итог subscriptions selftest passed.
- `/tmp/ccl-auth-linux-ci-final.log`: exact SHA 40cfdf…, `Ran 284 tests in 34.246s`, `OK`, **0 skip**; build `sh linux/packaging/build-deb.sh` создал0.4.3_all.deb. Из log отдельно проверены actual Qt callbacks, account-cache isolation, package/isolation тесты. [CI run](https://github.com/ArrivaRUS/claude-codex-limits/actions/runs/37192768494).
- Packaged binary: `/tmp/ccl-auth-bundled-auth.log` —30862/0; `/tmp/ccl-auth-bundled-sync.log` —all passed; `/tmp/ccl-auth-bundled-subscriptions-escalated.log` —1218 OK,182 PNG, итог passed. Exit0 всех трёх запусков — handoff координатора, QA лично запуск не выполнял.

Первый packaged subscriptions запуск в обычной sandbox среде завершился exit 134 и оставил `/tmp/ccl-auth-bundled-subscriptions.log` с88 OK без итогового PASS. Он не засчитан успешным. Координатор повторил тот же binary после разрешённого выхода из sandbox; успешный escalated log и финальные PNG проверены QA. Это не проверка штатного запуска приложения или native auth backend.

## Независимая offline-проверка пакетов

DMG: `dist/ClaudeCodexLimits-3.2.3.dmg`.
SHA256: `c8f796efaed0343c679d397370050ae6f5d808b5bbc3dd4c8e1eb3ca5452d4d4`.
QA использовал read-only mount координатора `/tmp/ccl-auth-release-dmg-mount/Claude Codex Limits.app`; сам не монтировал/не отсоединял его.
Фактически выполнены QA: Python plist/hash/byte inspection; `codesign --verify --deep --strict --verbose=2` —exit 0, valid/designated requirement; `file Contents/MacOS/*` —arm64 Mach-O; `hdiutil verify dist/ClaudeCodexLimits-3.2.3.dmg` —exit 0, checksum VALID. Version/build 3.2.3; executable 0755; все14 packaged ресурсов побайтно совпадают с checkout, других ресурсов нет. Executable SHA256: `2b6728da03a284995b86ceec4dc5bd4822a04ee559a21dd6dc9f6fd8b7039ecd`. Notarization/Gatekeeper trust не заявляются по одному codesign verify.

DEB: `/tmp/ccl-auth-final-ci-artifacts/linux-deb/claude-codex-limits_0.4.3_all.deb`.
SHA256: `7d1edd28339a029f50ccb2975322293a63733a589e79679e2ceab811aeb14226`.
QA фактически выполнил Python in-memory parse ar и control/data tar.xz (без установки/распаковки системных путей/исполнения scripts): Debian 2.0, Version 0.4.3, Architecture all; Python≥3.7/PyQt5/dbus dependencies; root ownership; безопасные относительные пути, без symlinks/hardlinks. **38 data files**,33 побайтных checkout совпадения:16 Python modules,13 PNG/WAV,2entry scripts,icon,LICENSE. Пять generated файлов —2wrappers,desktop,user service/timer — отдельно сверены; timer 10 min, service `ccl-sync push --auto --quiet`. Wrappers/entry/postinst/prerm 0755; __pycache__ отсутствует. Postinst/prerm не запускались. Детальный SHA inventory — `/tmp/ccl-auth-final-qa/deb-inspection.json`; DMG inspection — `dmg-inspection.json`.

## Выполненные команды, изменения и непроверенное

QA реально выполнил: `pwd`, `git status --short`, `git rev-parse HEAD`, `git branch --show-current`; `cat`/`sed`/`rg` чтение инструкций, требований, памяти, source fixtures и журналов; `uname -a`, `sw_vers`; inline `python3` с Pillow для inventory/contact sheets и SHA/metadata/byte checks; `view_image` всех указанных финальных sheets; `codesign`, `file`, `hdiutil verify`. Все проверки/hash assertions/package comparisons завершились exit 0. Исходная инвентаризация отсутствующих preview paths в неполном sandbox log дала0 PNG — затем использован успешный escalated log,182 PNG; нулевой результат не засчитан проверкой.

Запись разрешена только отчёту и `/tmp/ccl-auth-final-qa/`. QA не делал commit/push/merge/publication, install, обычный startup приложения, credential helper, Keychain/SecretService/DBus calls, auth/browser/network/gist requests, чтение пользовательских prefs/logs/credentials. Mount оставлен координатору.

Остаётся непроверенным: live Astra Linux/KDE/Fly; native Keychain ACL/helper и KWallet/SS late-write/NoReply; фактический issuer configuration, OAuth/device/browser flow реального аккаунта; sleep/offline/возврат сети на живой машине; установка/удаление/апгрейд DEB и timer при login; Gatekeeper/notarization; реальная загрузка/установка обновления; реальные мышь/DPI/font/accessibility/window-manager сценарии; полгода календарной работы. Аппаратные звук/hotkey/text-insertion сценарии в этой auth задаче не выполнялись. Эти ограничения не скрыты общим synthetic PASS.

Файловое состояние после визуальной/пакетной проверки изменилось созданием данного документа и шестью параллельными документационными изменениями, перечисленными выше. QA не распространяет заключение на обновлённые release/user docs. Git HEAD прежний; `git diff --name-only -- Sources linux/ccl linux/tests build.sh .github` пуст. Код и пакеты после финальных проверок не менялись. `git diff --check` завершился exit 0, но не заменяет смысловое ревью чужих документов. Первая inline Python-попытка уточнить состояние отчёта завершилась SyntaxError encoding и ничего не записала; исправление выполнено apply_patch только этого файла. Координатору передан exact SHA и ограничения для итогового решения.
