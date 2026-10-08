# MANUAL-REFRESH — приёмка macOS3.2.6

Статус: завершено, v3.2.6 опубликована и установлена. Базаd607ff9fb8820164d9cdf9e880f859ed89547da6. Пользователь согласовал реализацию2026-10-07. Следующие поля заполняются только фактическими доказательствами.

## Проверки последней сборки

- Frozen3: main `6bfdb2b5aa0eb5c567f353f79452587d183dd3595c93839d4e0a32c17bd8a42e`; pure `b118084f80c26a4c86fe24417b3c5dd229ff14f686906b974feeea8af717e41b`.
- Developer: arm64/macOS13 compilation PASS. CodeReviewer и SecurityAnalyst: production delta и изоляция exact `--subscriptions-selftest` PASS; блокирующих замечаний нет.
- Независимые pure-проверки: 78 сценариев / 1089 assertions / 0 failures, exit 0. Артефакты `/private/tmp/ccl-manual-refresh-independent-run.5qrJeA`; точные входы ниже.
- Exact packaged `--subscriptions-selftest`: exit 0, **3091 OK / 0 FAIL**. Лог `/private/tmp/ccl-qa-snapshot3-0jhsa3qm/subscriptions-selftest.log`. QA просмотрела 36/36 новых PNG без геометрических замечаний.
- DMG SHA256 `b8ff16fc6fd9cdbc0387e732e7e2127f25200c4c1a566c339157beb64b6cc257`; executable `323615237fd990802bc3d1dde257d4d6b60242d3b000cb2394d457192cac3ff9`.
- Публикация и установка завершены; доказательства ниже.

## Ограничения

Никаких настоящих credentials, Keychain, пользовательских журналов или live API в тестах. Нельзя выдавать компиляцию и bitmap за интерактивный native lifecycle или проверку ACL. Подпись остаётся ad-hoc; нотаризация не входит в эту задачу. Новый ручной refresh не изменяет GitHub sync auth journal и его quiet-политику.

## Источник Retry-After

[RFC9110,10.2.3](https://www.rfc-editor.org/rfc/rfc9110.html#name-retry-after): срок задаётся HTTP-date либо неотрицательным целым числом секунд. Поддержка старых форматов HTTP-date описана в5.6.7. Проверки используют синтетические строки; пользовательские ответы API не читались.

## Frozen1 — изменения до приёмки

CodeReviewer и SecurityAnalyst приняли изоляцию exact app с единственным --subscriptions-selftest (synthetic tmp/assets/PNG разрешены, настоящие credentials/API/logs/Keychain недостижимы). Это не разрешение для новых helper режимов или обычного app startup в тестах.

Кандидат1 не принят: P1 recovery новойClaudehelperidentity отсутствовал (CLIlogin не гарантирует разрешение приложению); P2 выбор fallback терял снимок с показаниями/nil asOf; P2 старый геометрический oracle не учитывал38px новой шапки. Developer исправляет эти пути и добавляет новые UI-состояния. Старый DMG49dd0450 не выпускать. Новые source/fixtures требуют дельта-ревью изоляции и производственного поведения.

## Frozen2 — повторная приёмка

Snapshot:/private/tmp/ccl-manual-review2-_jfdd7ja. Main20c2d53e91b7b9e299f1e78c660efe848a9b122fdcd1fc837aaec7c2742b0527; pure0cb916e6c9f161ba010f34a9dee31acf96c91538427884a2f049db922e87706d. Developer compile arm64/macos13 PASS. Последняя дельта main относительно промежуточного666aaabf — использование systemUptime для permit. Есть36новых synthetic UI-фикстур; их runtime ещё не выполнен. P1/P2 исправления переданы на повторное Code/Security ревью.

Независимый новый pure-прогон:65scenarios/875assertions/0fail, harness5af1e7bd789382cc27bdd01bf90d00e89b0e09bbae11c81e6022737654e3ae83, runnere8ca809ed76ea03731b51fe93f06e2548c1a82f5fce3b5b434515c979f903c9d. Артефакты:/private/tmp/ccl-manual-refresh-independent-run.eIeFDq. Проверены P2actualselector и P1pureadmission/policy/cancel/expiry; realRPC и UIwiring не выдаются за проверенные этими тестами.

Ранняя QA старого snapshot1:expectedFAIL после810OK,106PNG;12свежихPNG просмотрены, дополнительных clipping/overlapне найдено. Отчёт:/private/tmp/ccl-qa-early-7wwr4nml/REPORT.md. Эти результаты не принимают snapshot2.

## Frozen3

Snapshot:/private/tmp/ccl-manual-review3-yjtg_b29. Main6bfdb2b5aa0eb5c567f353f79452587d183dd3595c93839d4e0a32c17bd8a42e; pureb118084f80c26a4c86fe24417b3c5dd229ff14f686906b974feeea8af717e41b. Новый pending-recovery читает текущую запись перед quiet update, различает semantic OAuth identity и изменения metadata; сведения других CLI-сервисов сохраняются. Независимый pure batch78scenarios/1089assertions/0fail, harness8aea790e19f539c07cccf2faa6526dbf1fedbfaaf22a040f0f03361bb4566350; runner6e5c67f6cf8a7054cc0f280f227bfa1c529b2c090511de4ec0a1e01f0b3d5e0d. Артефакты:/private/tmp/ccl-manual-refresh-independent-run.5qrJeA. Nativefetch отсутствиеповторногоOAuth проверяется отдельно статически, не заявляется пофейкам.

QA frozen2: DMG2dbbe150,17/17files,codesignPASS; exactselftestFAIL после124OK наcombined data/preferences assertion первойновойUIfixture.0/36новыхPNG. Отчёт:/private/tmp/ccl-qa-second-vs87jflj/REPORT.md. Frozen3разделяетassertions и предварительноинициализируетAppKit; rootcauseпроверяетDebugger. Пакет2непринимаетсяквыпуску.

CodeReviewer и SecurityAnalyst приняли frozen3 production delta и isolation exact `--subscriptions-selftest`. Прежний pending P2 закрыт; новых блокирующих замечаний не найдено. QA проверяет пакет SHA256 `b8ff16fc6fd9cdbc0387e732e7e2127f25200c4c1a566c339157beb64b6cc257`, binary `323615237fd990802bc3d1dde257d4d6b60242d3b000cb2394d457192cac3ff9`. Native compare/update не является атомарным CAS относительно внешнего CLI.

Предкоммитный HQ `secrets-check.sh` нашёл один ложноположительный результат: `Sources/LimitsMonitor.swift:535`, `codexAccessToken()`. Это вызов функции, не литерал или значение секрета. Других совпадений нет; лог сохранён локально, реальных секретов в проверяемой строке нет. Правила сканера не изменялись.

## Final acceptance (2026-10-07)

Production commit d50584b: CodeReviewer + SecurityAnalyst PASS. Pure 78 scenarios / 1089 assertions / 0 failures. Exact packaged selftest exit 0, 3091 OK / 0 FAIL; 250 PNG generated, all 36 new manual-refresh PNG visually reviewed. CRC and strict codesign PASS, 17/17 package files identical, arm64/macOS13. QA report: `/private/tmp/ccl-qa-snapshot3-0jhsa3qm/REPORT.md`.

P3: EN Advanced writeUnavailable badge says read failed, while detailed saving failure is correct. Native scrolling/focus and actual permission dialogs were not tested. Previous combined assertion cause is not established; all separate data/preferences keys/values assertions pass in the accepted revision. Publication and installation are next.

## Публикация и установка

2026-10-07: v3.2.6 на source d50584bcf5c7b7b63eb6df2ef50539b11fd0f045, Latest. Публичный DMG скачан с GitHub Releases и SHA256 совпал с b8ff16fc6fd9cdbc0387e732e7e2127f25200c4c1a566c339157beb64b6cc257. Linux0.4.4 не изменялся.

Установлено /Applications/Claude Codex Limits.app: версия3.2.6, strict codesign PASS, binary SHA323615237fd990802bc3d1dde257d4d6b60242d3b000cb2394d457192cac3ff9, PID96073 работает. Это обычный запуск после установки по разрешению пользователя, не liveAPI/Keychain тест. Backup3.2.5: /private/tmp/ccl-install-backup-nv_4dd_q/Claude Codex Limits.app. Receipts: /private/tmp/ccl-install-3.2.6-receipt.json, /private/tmp/ccl-installed-3.2.6-verified.json.
