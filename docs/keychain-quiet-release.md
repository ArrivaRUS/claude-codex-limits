# macOS 3.2.5 — KEYCHAIN-QUIET

2026-10-07. Production66587e9 принят независимыми CodeReviewer/SecurityAnalyst.
Пакетная приёмка и состояние выпуска — в [verification](keychain-quiet-verification.md).
Linux остаётся0.4.4.

## RU — заметки к выпуску

Версия 3.2.5 меняет фоновый доступ GitHub к Связке ключей: по контракту
запуск, пробуждение, продление входа и очистка старых записей должны проходить
без системных окон разрешения. Если доступа нет, данные входа сохраняются,
синхронизация и очистка ждут восстановления доступа.

Если на Mac с версией 3.2.5 синхронизации нужно разрешение, откройте
Настройки → Синхронизация через GitHub → **«Повторить доступ к Связке ключей»**.
Попытка ограничена по времени и может открыть системное окно. Разрешайте доступ
только узнаваемому приложению к указанной записи GitHub. После отмены или отказа
новый запрос требует нового нажатия. Новый вход выполняйте только по подсказке
приложения; он также не разрешает интерактивные фоновые повторы.

Сохранённой записи может понадобиться ручное разрешение: меняется помощник,
который обращается к ней. **«Разрешать всегда»** относится к конкретной записи
и приложению, а не всему сервису. Не разрешайте доступ всем приложениям и
не сохраняйте токен в обычный текстовый файл. Прежняя пауза **600 секунд** лишь
откладывала повтор; ожидание или перезапуск не разблокировали Связку ключей.
По контракту новые повторы по расписанию должны оставаться без окон.

Точная причина повторных окон на машине пользователя не установлена.
Изменение не добавляет нотаризацию и не меняет Gatekeeper. Отсутствующая
диагностика темпа Codex остаётся отдельным долгом; её исправление не заявлено.
Linux остаётся на 0.4.4.

## EN — release notes

Version 3.2.5 changes background GitHub Keychain access. Its contract
requires launch, wake, sign-in renewal and old-item cleanup to run without
system permission windows. If storage is unavailable, saved sign-in data is
kept while sync and cleanup wait for access.

If sync needs permission on a Mac running 3.2.5, open Settings →
GitHub sync → **Retry Keychain access**. The attempt has a time limit and may
open a system window. Allow access only for an app and GitHub item you recognize.
After cancel or deny, another request needs another click. Sign in again only
when the app asks; that action also cannot authorize interactive background retries.

An existing item may need manual permission because the helper accessing it
changes. **Always Allow** applies to the particular item and requesting app,
not the entire service. Do not grant access to all applications or save the
token in a plain-text file. The old **600-second** pause only delayed retries;
waiting or restarting did not unlock Keychain. The contract requires subsequent
scheduled retries to remain quiet.

The exact cause of repeated prompts on the user's machine is unknown.
This change does not notarize the app or change Gatekeeper. The missing Codex
pace diagnostic remains a separate issue; no fix is claimed. Linux stays at 0.4.4.

## Sources and verification limits / источники и ограничения

- [Contract](keychain-no-background-prompts.md): all background GitHub operations
  must be quiet; explicit recovery/login has bounded permission; unavailable
  storage preserves credentials/epoch and pending cleanup. It also records the
  unknown live cause and the possible permission need when helper identity changes.
- [Independent test plan](test-plan-keychain-quiet.md): Q1–Q10 are planned checks; completed subsets are listed in
  [verification](keychain-quiet-verification.md). Fake tests cannot establish native no-UI behavior or
  the user's actual ACL. Native isolated validation needs a separate assignment.
- [GitHubAuth.swift](../Sources/GitHubAuth.swift): helper quiet/interactive policy,
  manual permit scoped to an operation, retry gate and explicit retry entry point.
- [LimitsMonitor.swift](../Sources/LimitsMonitor.swift): native helper interaction
  policy, bounded subprocess adapter and RU/EN retry labels. Final source66587e9 passed independent Code/Security review.
- [Historical 3.2.4/0.4.4 evidence](freshness-keychain-verification.md): the older
  cooldown did not establish whether a native prompt occurred. Those results
  do not validate 3.2.5.

Only document content is checked in this TechWriter task. No build, app, CLI,
API, Keychain, real credentials or user-log inspection is performed. Runtime
behavior, denial/cancellation, time limits, native no-UI, packaged validation,
notarization/Gatekeeper status and installation are not verified here.
Before publication, the coordinator must reconcile these drafts with the frozen
source and independent evidence. Until then, release/installed/tests PASS claims
for 3.2.5 remain absent.
