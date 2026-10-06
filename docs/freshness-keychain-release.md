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

## Доказательства приёмки

Итоговый production source: `bd16d9c8e3296cd752784e61d9d456071c7bd2a6`.
CodeReviewer и SecurityAnalyst приняли исправленный диф; два P2 закрыты.
Linux CI: 306 tests PASS, 0 skips. Native QA: 1401 checks PASS, 214 PNG;
проверены критические RU/EN состояния, темп и восстановление входа.
Пакетный QA выявил неверный минимальный target macOS26: `build.sh` исправлен
на явный target13; новый DMG прошёл integrity/codesign/readonly проверку и packaged selftest1401/0,214PNG.

Точные хеши, прогоны и границы проверки — в
[итоговом отчёте](freshness-keychain-verification.md).
[План FRESH-4H](freshness-4h-plan.md), [ранний review-status](freshness-4h-review-status.md)
и [план KEYCHAIN-RETRY](keychain-retry-plan.md) сохраняют историю требований.

Реальные credentials/API, нативные Keychain ACL и живая ALSE в тестах не использовались.
Публикация DMG/DEB и установка пока не подтверждены. Linux release должен сохранять
`--latest=false`; Latest остаётся macOS.
