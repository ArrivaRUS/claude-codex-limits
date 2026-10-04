# GH-AUTH-UI — регрессия состояния хранилища и GitHub-входа

2026-10-04. План до production-кода. База `297777d7b7386693fd8594a1b86532dab6b621c5`.
Источник: [github-auth-diagnosis.md](github-auth-diagnosis.md). Диагноз машины
пользователя остаётся неизвестным; матрица проверяет подтверждённые пути кода.
Все запуски ниже **запланированы, не выполнены**. Принят минимальный контракт
Architect из [github-auth-ui-fix.md](github-auth-ui-fix.md): Linux `_ss_read`
при `_ss=None` бросает существующий `_SecretServiceAbsent`; `_read` обрабатывает
его до общего Exception, явный SS возвращает `(None, 'unreachable')`, legacy
сохраняет прежний file-discovery. GUI/CLI используют существующий unreachable UI,
без дополнительного keyring/reachable query. Swift сохраняет enum/phase и меняет
общий revoked-copy на «Требуется вход в GitHub» / «GitHub sign-in required»;
причина доступна в `lastError`. Новые auth fields/enum не требуются.

## Контракт

- Linux: известный login, явный `tokenBackend=secret-service`, `_ss() is None`,
  без revoked/pending cleanup — недоступное хранилище. UI объясняет временный
  сбой и автоматическую повторную попытку; не предлагает новый GitHub-вход.
- Missing локальной записи, ошибки чтения, locked, timeout и подтверждённый
  отзыв — разные состояния. UI не делает вывода о серверном отзыве по missing
  Keychain. Действительно подтверждённые три 401 дают понятное предложение
  повторного входа. После восстановления сервиса возвращается обычный UI.
- Политика трёх 401, адресное удаление токена, local logout, generations,
  расписание/таймеры сохраняются. Refresh OAuth/миграция ключей вне задачи.
  Открытие страницы или draw не выдаёт device flow и не меняет storage.

## Независимая матрица ожиданий

Для каждого UI-сценария — RU/EN и Настройки + основной Advanced, история
collapsed/expanded. Simple сохраняет действующую видимость GH-блока; новый
баннер или действие туда не добавляется без отдельного продуктового требования.
Warning-проверки учитывают существующие first-attempt/stale gates: явное now,
известные last-success/error-at; отсутствие попытки не выдаётся за новый сбой.

| ID | Синтетическое состояние | Ожидание и побочные эффекты |
|---|---|---|
| L1 | login известен; backend SS; generation задан; revoked/pending отсутствуют; fake `_ss=None` | `_ss_read` поднимает `_SecretServiceAbsent`, `_read` возвращает `(None, 'unreachable')`. Settings использует существующее объяснение недоступности и автоповтора, кнопки нового входа нет. Main warning при действующих gates говорит о sync/storage, без «войдите заново». Ноль device-flow, HTTP, store/publish/delete; файл backend не читается как fallback явного SS. GUI не добавляет reachable/keyring query. |
| L2 | Тот же manifest; fake SS отвечает, get возвращает None, has_locked=False | Genuine missing отличается от unavailable: возможное предложение локального повторного входа по принятому контракту, без ложного утверждения server revoke. Rendering не обращается к device-flow и не меняет manifest/token. |
| L3 | Fake SS locked / `_timed` даёт Timeout / fake get даёт ошибку чтения | Locked предлагает разблокировать; timeout объясняет ожидание; read failure/unreachable объясняет доступ/ошибку чтения. Ни один из них не предлагает перевход или не называет токен серверно отозванным. Исходный login/generation/backend сохранён. Коды, которые production объединяет в unavailable, не объявлять отдельным новым core-state без решения Architect. |
| L4 | L1, затем тот же fake backend возвращает synthetic token | При повторном построении Settings доступны прежний signed-in UI и разрешённые текущим контрактом controls; login/generation неизменны, login-кнопки нет. Представление актуально без перезапуска и без start_login. Warning не обязан исчезать, пока не прошёл успешный sync: проверять восстановленную модель с очищенной ошибкой отдельно, без реального цикла. |
| L5 | revoked=True; pending cleanup; login неизвестен; file backend; пустая generation/tombstone — отдельные fixtures | Приоритет прежних revoked/pending/signed-out веток сохраняется. Pending не маскируется недоступностью и не выдаёт новый вход. File backend не требует SS; tombstone не разрешает legacy discovery. Legacy без SS с fake-файлом/без него проверяется отдельно в L6. Проверять защитные guards и число read/reachable-вызовов; не запускать настоящую очистку. |
| L6 | Legacy generation, backend None; fake `_ss=None`; synthetic fallback file present/absent | `_SecretServiceAbsent` не ломает прежний discovery: synthetic file читается ровно по legacy пути; present даёт token/file, absent — genuine missing. То же при existing SS без записи. У explicit SS такого fallback нет. File-get разрешён только как контролируемый fake, никаких реальных файлов токена/миграции/записи/удаления. |
| M1 | Swift известный login; fake Keychain `.missing`; syncRevoked=False | Prepare/startup и синтетический background read сохраняют прежний phase `.revoked`, но Settings/main показывают нейтральное «Требуется вход в GitHub» / «GitHub sign-in required». `lastError` объясняет отсутствие локального ключа. UI не утверждает серверный отзыв; persisted syncRevoked flag не выставляется, writes/deletes/HTTP=0. |
| M2 | Swift `.timedOut` / `.failure(code)`; известный login | Прежняя временная ошибка/деталь чтения, отсутствие ложного server revoke и device flow; token/login/generation/revoked-поля defaults не изменены. Запись диагностических error/backoff в отдельный selftest defaults допустима по действующему core-контракту; это не запись token storage. Проверять UI counters и существующий backoff-контракт, не ждать реальный таймаут. |
| M3 | M1/M2 → `.token(synthetic)`; прежний login | Fake startup/state refresh возвращает нормальное представление; нет повторного входа и storage writes/deletes. Snapshot предыдущего ошибочного текста не остаётся в заново построенных controls. |
| C1 | Подтверждённый revoked после gist401 + user401 + user401 | Main/Settings используют тот же нейтральный required-copy; `lastError` ясно сообщает реальный server revoke, controls предлагают новый вход. Exact delete/captured-token/generation поведение совпадает с существующими regressions; новый UI не запускает вход сам. |
| C2 | 401 + user200 либо последняя проверка non-401 | Предыдущие token-retention tests остаются зелёными, UI не становится revoked. Новые тесты не дублируют весь транспортный набор: использовать существующие fixtures как регрессионный гейт. |

Основные L1/L2 fixtures должны различаться только доступностью fake SS; это
доказывает исходную ошибку `_ss=None`, а не лишь реакцию UI на готовую метку.
В RU/EN проверять утверждение причины и доступные controls, а не только наличие
слова «GitHub». Геометрия: wrap/clipping, отсутствие overlap и все hit bounds;
bitmap оценит независимый QA. Сохранённые значения сравниваются **после draw**.

## Швы и будущая область записи Tester

Сейчас запись разрешена только этому документу. После production freeze и
передачи области координатором предлагаются:

1. Новый `linux/tests/test_github_auth_ui.py`: `_isolate` первым импортом,
   `common.Store`/sync-state/manifest — временные fixtures только в `/tmp`.
   Core `_read` с synchronous fake `_timed` и fake `_ss`, `get`, `has_locked`;
   file backend только fake из L6, все остальные file-обращения и записи/delete —
   запрещающие моки/счётчики. Проверить прямой `_ss_read`/`_SecretServiceAbsent`
   и `_read` explicit versus legacy, чтобы тест проходил через исправляемую ветку.
   Для UI использовать реальный `SettingsPage` со synthetic app/window и
   заглушенными slots, затем читать QLabel/QPushButton и строить offscreen image.
   Основная панель — `panel.Model`, `Canvas.text/text_c` с сохранением original
   Attr/list через `Canvas._runs`, actual draw и возврат hits. Без настоящего
   `TrayApp`, refresh callback или timers. Main state публикацию, если нужно,
   проверять на fake receiver отдельно от live runtime.
2. Только `--sync-selftest`-блок `Sources/LimitsMonitor.swift`: существующие
   `SelfTestHTTP`, `ScriptedSyncKeychain`/`SelfTestKeychainStore`, отдельные
   selftest defaults, temporary remotePath, фиксированное now. Prepare/read
   assertions используют инъецированный keychain; constructor явно передаёт
   fake transport/keychain/defaults/machineId. M1/M2 counters: reads разрешены
   только fake, HTTP/write/delete/device-flow=0; synthetic store неизменен.
   C1/C2 опираются на существующий scripted transport с нулевой recheck delay.
3. Только `--subscriptions-selftest`-блок того же Swift файла: RU/EN bitmaps
   `drawSettings`, `drawAdvanced` и соответствующие hits; `SYNC_PREVIEW`
   вместо обращения к `GitHubSync.shared`. `appLang()` в `--sync-selftest`
   принудительно ru, поэтому EN actual draw нельзя засчитать в этой ветке.
   Volatile `NSArgumentDomain`, temporary usage fixture, synthetic LimitData.
   Shared copy helper assertions + actual PNG + Reviewer wiring допустимы;
   production observer не требуется. Новые callbacks/AppDelegate не создавать.

4. Возможная минимальная коррекция существующего vault-test по отдельной передаче
   конкретного файла координатором: если он прямо закрепляет private
   `_ss_read(None SS) == (None, False)`, заменить устаревшее ожидание на новый
   private `_SecretServiceAbsent` и обязательную public `vault.read()` проверку
   `(None, 'unreachable')` для explicit SS. Legacy public fallback остаётся
   прежним. Readonly поиск на базе не нашёл прямого `_ss_read` assertion;
   это резерв области, а не утверждение об уже найденном сломанном тесте.

Существующие vault tests сейчас не менять. При необходимости изменения других
probes/fixtures сначала сообщить координатору и получить назначение файла.
Никаких production-правок Tester, новых auth fields или UI observers.

## Изоляция до исполнения — уроки 006/011

`_isolate` ставит XDG до импорта `ccl`, перенаправляет CLI/manifest-пути и режет
HTTP. В каждом новом тесте дополнительно запрещать или считать `sync.transport`,
`common.http`, `sync.sync_cycle`, device-flow/login helpers, `vault.store`,
`vault.publish`, `vault.delete`/`delete_ref`, real `_ss`, `_file_get`, оба limits
fetch, usage.refresh/scan; callbacks Settings — fake slots. При тесте fake SS
единственная разрешённая `_ss` — инъецированная заглушка до чтения UI.
Если существующий render/read вызывает check/reachable, mock ставится **до**
него; новый GUI-query контрактом запрещён и счётчик остаётся нулём.
XDG не защищает Secret Service. Backend manifest read также mock или
временный Store: не читать настоящие sync/token/login files.

Все файловые fixtures/PNG/бинарь — `/tmp`. Ни real credentials/logs, DBus/keyring,
`/usr/bin/security`, ни gist/API. Никаких настоящих device codes/auth headers
в результатах. Swift preview defaults сохраняются/restored только volatile;
UI fixtures восстанавливают прежний `prefs`/selection/SYNC_PREVIEW, чтобы не
ломать старые финальные assertions. Без refresh и not-due предположений.
Только специально инъецированный синхронный core read/state path; обычный
AppDelegate и unsafe preview запрещены. Изоляция ревьюируется до запуска.

## Проверки после freeze

Команды — рекомендации, сейчас не выполнены. Сперва статический scope/hash
контроль и независимый review изоляции; потом целевой запуск. Swift блоки
запускает координатор на согласованном временном бинаре после review.

```sh
QT_QPA_PLATFORM=offscreen CCL_PREVIEW_DIR=/tmp/ccl-gh-auth-ui python3 -m unittest discover -s linux/tests -p 'test_github_auth_ui.py' -v
QT_QPA_PLATFORM=offscreen python3 -m unittest discover -s linux/tests -p 'test_sync_warning.py' -v
QT_QPA_PLATFORM=offscreen python3 -m unittest discover -s linux/tests -p 'test_sync_revoke.py' -v
```

Полная suite один раз на финальном диффе в Ubuntu CI: обязательны 0 skip;
локальные PyQt skips честно отмечать как непроверенный UI. Запуск по решению root;
сейчас её не перезапускать. PyQt5/WindowServer недоступен → честное «не выполнено»
для соответствующего draw, GUI skip не становится PASS. Минимальное fail-before
доказательство L1: старый strict fake путь приводит к login control; новый — к
unavailable с нулевыми mutation/device-flow counters. M1: старая fake missing
модель показывала утверждение server revoke; внутренний phase сохраняется.
Если fail-before запуска недоступен, явно
разделить статическое подтверждение дефекта и выполненный after-run.

Отчёт: commit + frozen hashes и незакоммиченный diff; фактические run/skip/checks,
exit codes, картинки и zero-mutation counters. QA/Reviewer отдельно проверяют
тексты и wiring обоих UI. Уже выполненные релизные suite из предыдущей задачи
не доказывают этот инкремент; реальный wallet/GitHub пользователя не проверяется.
