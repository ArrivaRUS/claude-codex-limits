# GH-AUTH-STABLE: независимая security-проверка

2026-10-04, SecurityAnalyst GPT-6 Astra/high, новый контекст. Первичное заключение
сделано без чтения нового CodeReviewer отчёта. Только чтение/specs/hashes,
без runtime, реальных credentials/store/logs/auth API, записи и Git-мутаций.

## Linux rev4 / Swift C3 — финальный проход НЕ PASS

Последующий Linux rev5b auth `48ee84cac854b7174eebd78446cb346199ffb2ff09f76801eb537838daef9d60`
с прежним vault96ae: Security delta PASS, pure grants_per_ensure=[1,1,1].
Swift C4 core `3f3457d7cf6e37c791a1b170dbc9b2de7a09c75e11a8d7902dfe22819595388f`
НЕ PASS: completeLogin cancellation callback теряется через candidate successor
renewCandidate→recover→validate(default true), durable publish после Cancel;
crash до наружной cleanup оставляет отменённую session. CodeReviewer независимо
подтвердил. Остальные permit/probe/cache delta механизмы статически приняты.
Автор исправляет callback по всей цепочке; native stores/runtime не проверены.

Последующий Linux rev5 delta на auth `086d4cec38185ffb76968871b91855269971e6263c48319e6667124b54cecc6c`
и vault `96ae997f72d384a10c51d2667930ad9f6da2ac864b174b7120584a7c822e0fcc`:
reservation no-writer P1 исправлен (pure in-memory restart → ready, grant=1).
Write-ahead/receipt/schema/candidate fences статически приняты. Новый P2:
успешный refresh + identity401 вызывает второй successor grant в том же ensure
(auth539→370→447); pure reproduction grants=2. Автор исправляет общий лимит
и terminal late-candidate ветку. Это НЕ PASS; Swift C4 ещё pending.

Новый SecurityAnalyst Astra/high независимо проверил base `eef4b77` и frozen
auth.py `299617e52621475369282f7ee92ee7b52fafa7290aed57b28d7ca2444cf42b23`,
vault.py `3efa99ed1ebec2a196a816df59a72525dd09f777b86b3d52d232c69e685797f2`,
Swift core `b1683f6bd0b6fbaf7872b0313d8ac2c2947cb64017bb27021a70de536a970675`
и main `32b41704d0677c825adfe2f6ed12dfd73d9d1c1dad2a34ec7b2853fc6ea38984`.
Прежние SEC-L1–3 и четыре Swift C2 находки статически исправлены, но найдены:

- P1 Linux auth449/vault620: intent помечает toRef uncertain до OAuth и запуска
  writer. Crash до создания lock/receipt оставляет вечный storage_write;
  missing lock не позволяет recovery/cleanup. Нужны раздельные durable states
  для no-RPC-yet и remote-unknown, включая reservation-before-lock окно.
  Pure in-memory reproduction на обоих backend: три restart, OAuth=0,
  recoveryAttempts=0, temporary/storage_write. Fake store маскировал missing lock.
- P2 Swift core415/477: initial probe timeout + readable payload позволяет OAuth
  до trusted settlement. Нужен gate и regression timeout/readable/unsettled.

Native helper статически ограничен fixed service/UUID/128 KiB, immutable
SecItemAdd/stdin, explicit trusted security ACL; новых leakage путей не найдено.
Live Keychain ACL/KWallet/ALSE не проверены. Финальный CodeReviewer дополнительно
проверяет candidate access expiry до identity; выпуск блокирован до исправлений.

## Linux rev3 — НЕ PASS

Frozen auth `ce91d8c57524e9435f48b94ba5155a64d714b612a4e5cd98850cf6bf6524b6c4`,
vault `e7df37a3163c285919aaddbeab608630591b6e6af790bc568388bd0b1831b4fb`,
sync `93dc04b62d26641657250301bfeaed9b97939a2cfd7caf1b9e94a07e2a780354`.
Полный набор шести source hashes совпал в начале и конце; база `eef4b77` + diff.

| ID | Приоритет / строка | Подтверждённый класс и направление |
|---|---|---|
| SEC-L1 | P1 sync110/172; auth488 | Process-local begin/is_current не защищает delayed device response от logout/newlogin другого процесса. Durable operation ID/revision ДО device flow, CAS receive/publish, invalidation при logout/supersession. |
| SEC-L2 | P1 vault596/708; auth243 | Free writer flock/PID death подтверждает локальное завершение, но не DBus CreateItem после NoReply/disconnect. Отдельная durable server uncertainty, trusted completion/barrier либо retained cleanupPending; не забывать ref при возможном daemon late write. |
| SEC-L3 | P1 common67; vault700/731 | SIGKILL между fsync и replace оставляет .GEN.random с полной парой; delete только GEN выдаёт готовую очистку. Адресный temp sweep после settlement с fsync, ref сохранять при ошибке. |

NoReply/daemon interleaving на живом KWallet/ALSE не воспроизводился. Основание
неправомерности settlement inference: [D-Bus PendingCall](https://dbus.freedesktop.org/doc/api/html/group__DBusPendingCall.html)
и [Secret Service API](https://specifications.freedesktop.org/secret-service/latest-single/):
прекращение локального ожидания не обещает rollback уже принятой операции.
A9 не разрешает объявлять завершённым logout при возможной поздней локальной копии.

Положительные статические наблюдения: отдельный V2 namespace, полная пара,
pinned backend, exact OAuth HTTPS/no redirects, API-only Bearer/raw без Bearer,
0600/0700, file+directory fsync, sync flock, persistent unknown budget,
local-only logout и durable legacy retirement. Путей секретов в manifest/gist/argv
или обычный status не найдено. Полную schema validation manifest считать принятой
нельзя: требуется проверить refs/counters/ranges. Это ограничение проверки.

Автор получил исправления; Linux code review PASS rev3 не заменяет этот НЕ PASS.
Swift C2 передан SecurityAnalyst отдельным поручением, его результат pending.
