# macOS 3.2.4 / Linux 0.4.4 — release preparation

2026-10-05. **Черновик / draft. Не выпущено / not released.**
Рабочая копия документации: `/private/tmp/ccl-integration.yCDZba`.
Исходный PROJECT_ROOT: `/Users/arrivarus/Documents/VibeCoding2/2026_06_UsageLimits`.
Номера — целевые; этот документ не подтверждает версию сборки или публикацию.

## RU — текст для будущего выпуска

- Снимки не старше 4 часов, включая ровно 4 часа, остаются допустимыми по возрасту даже после сбоя запроса. Завершённые окна и подтверждённые проблемы входа проверяются отдельно.
- Темп и прогноз привязаны к времени снимка `asOf` и помечены как исторические. Ход часов без новых данных не изображает замедление расхода. Сессионное, недельное и модельное окна независимы; недельные данные работают без сессионных. Неизвестное время снимка не заменяется текущим.
- Auto планирует обновление по сроку, соблюдая ограничения частоты и backoff. При неудаче сохраняет снимок и сообщает о сбое и следующем повторе; расписание не гарантирует успешный запрос.
- На macOS общий gate GitHub V2 ограничивает фоновые обращения к Связке ключей после ошибки на 600 секунд по монотонным часам. Пропуск не продлевает срок; после срока допускается одна сериализованная попытка. Ручной «Повторить доступ к Связке ключей» не является новым входом и не отменяет сетевые/recovery-ограничения.
- Недоступность хранилища не означает отзыв входа и не удаляет действующие credentials. После выхода сохраняется tombstone, а недоступная физическая очистка/GC откладывается.
- Gate действует только в текущем процессе и сбрасывается при restart. Успешное Allow или другая запись с тем же именем не покрываются этой гарантией. ACL не меняются; причина первого prompt не установлена и его устранение не подтверждено. Последующие диалоги возможны. Keychain-изменения относятся к macOS; Linux получает FRESH-4H.

## EN — text for the upcoming release

- Readings up to 4 hours old, including exactly 4 hours, remain valid by age even after a failed fetch. Expired windows and confirmed sign-in problems are checked separately.
- Pace and forecasts use the snapshot timestamp `asOf` and are labelled historical. Clock movement without a new reading does not imply slower consumption. Session, weekly and model windows are independent; weekly-only readings work. Missing timestamps are not replaced with the current time.
- Auto schedules an update attempt at its deadline while respecting frequency limits and backoff. Failures retain the snapshot and display the failure and next retry; a scheduled attempt does not guarantee network success.
- On macOS, a shared GitHub V2 gate pauses background Keychain store attempts for 600 monotonic seconds after an access failure. Skipped calls do not extend the deadline; one serialized attempt is allowed after it. “Retry Keychain access” is an explicit retry, not a new login, and preserves network/recovery limits.
- Unavailable storage does not mean revoked sign-in and does not delete active credentials. Sign-out preserves a tombstone and defers unavailable physical cleanup/GC.
- The gate is process-local and resets on restart. Successful Allow or another item with the same name falls outside this guarantee. ACLs are unchanged; the first prompt's cause is unknown and its removal is unverified. Further prompts remain possible. Keychain changes are macOS-only; Linux receives FRESH-4H.

## Доказательства и незавершённые гейты

Последняя сводка передана координатором в поручении; команды этих проверок
технический писатель не запускал и итоговую ревизию Git не устанавливал.

| Область | Переданный результат | Ограничение |
| --- | --- | --- |
| FRESH-review | Принят; 49 Python / 105 Swift | Не доказывает итоговый combined source |
| Combined security | Первая проверка исходников пройдена | Два P2: developer fix pending; нужна проверка исправленного дифа |
| CI | 306 тестов, 5 failures: 2 Simple bug + 3 path | Повтор CI ожидается; не PASS |
| Native selftest | Passed | Не заменяет UI/пакетную проверку |
| Visual QA | Продолжается | Финального результата нет |

[План FRESH-4H](freshness-4h-plan.md), [ранний review-status](freshness-4h-review-status.md)
и [план KEYCHAIN-RETRY](keychain-retry-plan.md) сохраняют исходный контракт и историю.
Их ранние статусы не заменяют свежую сводку координатора и не обновлялись здесь.
Указанная там база `d65df2dda14e09312e87b4d61b00417acda5a00f` — историческая база,
не проверенная ревизия этой интеграционной копии.

Источники поведения, прочитанные статически в копии:

- [Swift limits/UI/scheduler](../Sources/LimitsMonitor.swift): `metricIsStale`, `snapshotWindowPace`, `pacedLimits`, `KeychainRetryDeadline`, ручной retry и сообщения UI.
- [Swift auth owner](../Sources/GitHubAuth.swift): `checkStoreAccess`, `storeFailed`, `withAuthLock`, `retryKeychainAccess`, `retire`, logout tombstone.
- [Linux limits](../linux/ccl/limits.py): `SNAPSHOT_MAX_AGE`, `metric_is_stale`, `snapshot_window_pace`, `with_poll_status`.
- [Linux scheduler](../linux/ccl/polling.py): `PollState.due`, `observe`, `next_delay`; [Linux UI](../linux/ccl/gui/panel.py): failed fetch/next retry notices.
- [Build](../build.sh), [DMG](../scripts/make-dmg.sh), [DEB](../linux/packaging/build-deb.sh), [Linux release](../linux/packaging/release.sh): команды и источники версии. Версии оставлены координатору.

## Перед выпуском — действия координатора, пока не выполнены здесь

1. Исправить два P2 и Simple/path failures, зафиксировать точный итоговый source/диф; получить независимые проверки исправленной ревизии, успешный повтор CI и завершённый visual QA. Не переносить PASS с прежнего дифа.
2. Согласовать целевые версии во всех источниках версии. Тексты выше публиковать только после проверки фактического поведения конечной сборки.
3. На macOS с Swift compiler и средствами подписи выполнить `bash build.sh`, затем `bash scripts/make-dmg.sh` (второй скрипт также вызывает build). Ожидаются подписанная `.app` и `dist/ClaudeCodexLimits-3.2.4.dmg`; strict codesign staged app проверяет DMG-скрипт. Сверить версию, SHA-256 и пакетный QA. Сборка сама по себе не доказывает живой Keychain сценарий.
4. С `dpkg-deb` выполнить `sh linux/packaging/build-deb.sh` либо использовать подтверждённый CI artifact той же принятой ревизии. Ожидается `dist/claude-codex-limits_0.4.4_all.deb`; сверить путь из вывода скрипта, версию, архитектуру и SHA-256. Это не живой ALSE smoke.
5. Координатор подтверждает release gates и разрешение на публикацию. Для Linux сохранить `--latest=false`; Latest остаётся macOS. Сверить опубликованные assets после выпуска. В этой задаче сборка, публикация, установка и обращения к реальным credentials/API не выполнялись.

README сохраняют исторические подробности выпущенных версий. Этот документ —
черновик текста и передачи доказательств, а не HEARTBEAT, решение или закрытие задачи.
