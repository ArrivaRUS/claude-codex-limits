# GH-AUTH-STABILITY — независимая проверка полного lifecycle

2026-10-04. Tester GPT-6.1 Sol/high. База чтения
`297777d7b7386693fd8594a1b86532dab6b621c5`, до production.
Требования: [PRD A1–A12](prd-github-auth-stability.md).
Accepted [architecture-github-auth.md](architecture-github-auth.md) прочитан
после двух архитектур и challenge. Перед реализацией тестов сверить exact
phase/checkpoint/dependency API Developer. Этот план заменяет UI-only приёмку цели.
Ни один тест/команда ниже сейчас **не запускались**.

## Контракт и независимые доказательства

Проверяем secure CredentialV2 с полной парой, immutable generation/epoch,
атомарный nonsecret manifest: Linux `authV2` в `SYNC_STATE_PATH`, macOS
`dataDir/github-auth-state.json`. Намерение хранит `fromRef/toRef` до запроса;
`requestStarted` сохраняется до возможного расходования refresh. Recovery
проверяет `toRef`, даже когда готовый candidate ещё не отмечен фазой ready.
Сначала надёжно stage результата, потом user identity validation, commit,
retire прежнего ref. Backend закреплён; probe использует **другую** unique
generation. Refresh stage не использует abandoned-login cleanup/file fallback.

Устойчивость доказывается успешными защищёнными чтениями fake issuer/gist,
operation counters и durable состоянием после restart, а не одним UI/login
flag. Oracle отдельно хранит допустимые выдачи issuer и актуальный user/epoch;
не копирует production parser/formatter или вычисление transitions.

| Проверяемый инвариант | Наблюдаемое доказательство |
|---|---|
| Полная выдача, правильный владелец | Fake protected request принимает только текущий access своей пары/user; запрещено смешивание access/refresh разных generations/accounts. |
| Один расход refresh | Fake issuer инвалидирует прежнюю пару при принятии refresh; одновременные операции не расходуют один refresh повторно в здоровом сценарии. |
| Durable результат не потерян | Пересоздать coordinator/store wrapper из сохранённых fixtures: recovery выбирает сохранённый toRef и завершает validation/commit без повторного refresh. |
| Нет лишней авторизации | После initial explicit login счётчики device-flow/browser/confirmation остаются 0 в healthy/восстановимых случаях. |
| Поздний writer не победил | После logout/нового login старый epoch/ref не меняет active manifest и не удаляет новый ref; frozen state/ledger сверяется после callback. |
| Credentials локальны | Sentinel access/refresh отсутствуют в prefs, manifest, gist, логах, UI и argv; store содержит только разрешённые refs своей fixture. |

## Виртуальное время и здоровый pipeline — A1/A2/A3

Fake clock стартует с фиксированного epoch. Issuer настраивается с несколькими
TTL, включая типовой 8h и короткий TTL. Maintenance = 600 s, lead = 900 s с
ограничением принятой долей TTL; точную долю взять из published contract,
а expected due вычислить независимо по нему. После установления known gist
обычная healthy fixture вызывает фактический sync read на каждом tick.

- Горизонты 30 и 180 дней: 4 320 и 25 920 ticks после initial setup при 600 s.
  На каждом tick защищённый gist read действительно проходит с действующим
  access. У fake gist изменяется безопасный usage marker: проверяется его
  получение в модели/cache, чтобы пустой `ok` не заменил реальную авторизацию.
  Если протокол делает дополнительный `/user`/raw read, считать их отдельно.
- Количество renew определяется независимым расписанием issuer TTL/lead;
  в исходной healthy fixture каждый успешный renew ровно один раз stage,
  validate, commit, retire. Время и refs issuer не берутся из production state.
  Device-flow ровно один при explicit setup; после reset counters — 0 новых.
- Долгоживущий legacy access без refresh/expiry: те же горизонты через обычный
  старый sync pipeline; refresh=0, forced-login=0, working legacy ref не
  переписывается ради схемы. Новое приложение читает совместимое старое хранение.
- Sleep 2/6 недель: clock прыгает, maintenance во сне=0. После wake/restart
  доступный refresh восстанавливает защищённое чтение в ближайшую автоматическую
  попытку ≤10 минут. То же для long-lived, без фиктивного expiry. Заведомо
  истёкший refresh — отдельный terminal fixture, не healthy failure.
- Maintenance с Advanced on/off и выбором обеих/одной/без лимитных подписок:
  renewal продолжает независимый cadence. Fetch Claude/Codex запрещены моками;
  Фактический авторизованный sync также восстанавливается независимо от Advanced
  и свежести локального индекса; нельзя засчитать только продление метки login.
  Отдельно подтвердить scheduled/manual sync использует новую active выдачу.
  Clock rollback/forward не создаёт busy loop или стирание auth.

## Матрица parser, транспорта и policy

| ID / PRD | Fixture | Ожидание |
|---|---|---|
| P1 / A1,A2,A11 | Полный access+refresh+issuer lifetimes; legacy access-only | Полная новая пара пригодна для stage; lifetime поля метаданные. Long-lived не становится expired по выдуманному сроку. |
| P2 / A11 | Lifetime: missing/null/bool/NaN/infinity/negative/ноль/слишком большой; boundary допустимого диапазона | Недостоверный срок становится unknown по контракту, но **полная новая пара не уничтожается**. Нет NaN arithmetic/busy-loop. Не публиковать access одной generation с refresh другой. |
| P3 / A9,A11 | Partial response: отсутствует access/refresh, пустой credential, неправильный тип, malformed JSON/error body | Нет commit partial/mixed pair. Пригодные новые values сохраняются непубликуемым candidate по контракту, не дополняются старой парой и не уничтожаются из-за lifetime ошибки. Разделить старую ещё рабочую выдачу и уже расходованный issuer refresh; второй путь сохраняет неопределённость, не обещает рабочий старый token. |
| T1 / A4,A11 | OAuth refresh POST; fake 301/302/307/308, другое origin/path, HTTP downgrade, lookalike host | No redirects; только точный TLS origin/path. Refresh body не уходит на иной endpoint; Authorization и client_secret отсутствуют в OAuth POST. Предусмотреть spy самого HTTP-adapter redirect policy, не только already-filtered fake endpoint. |
| T2 / A4 | Заведомый pre-send network failure, timeout до отправки, 429/Retry-After, 5xx; потом успех | Credentials не уничтожены, bounded retries; обычный healthy recovery ≤10 min, issuer Retry-After исключение соблюдено. Реальный sleep не используется. |
| T3 / A1,A10 | Access401 при usable refresh | Recovery/renew до access-only triple401 destructive rule. Новый access идёт в actual protected read; истёкший старый access не выдаётся за окончательный отзыв. |
| T4 / A10 | Access-only: gist401/user401/user401; варианты user200/403/429/5xx | Существующая triple401/captured-token/deletion policy не меняется. Non-401 не подтверждает окончательную утрату. |
| T5 / A9,A10 | bad_refresh_token/terminal refresh error; late old-ref response; candidate может существовать | Перед terminal classification перечитать ref/epoch и проверить recovery/toRef. При доступном durable candidate не объявлять terminal и не удалять его. Только корректный bad_refresh_token текущей транзакции подтверждает непригодность refresh; usable access сохраняется и ещё выполняет protected read, UI сообщает невозможность продления. Явный вход нужен при отсутствии usable access/recovery. |
| T6 / A9 | Issuer consumed refresh, response lost; нет issuer grace | Persistent unknown-request budget переживает restart, не сбрасывается CLI/GUI сменой процесса. Нет endless reuse/device-flow; окончательная неопределённость честно объяснена. После одного explicit login новый healthy lifecycle проходит. |

## Durable этапы и fault checkpoints — A5/A8/A9

Сценарии запускаются для каждого поддерживаемого pinned backend с fake store.
Manifest читает только temporary root. Каждый checkpoint проверяется kill/restart
или контролируемым exception; не ограничиваться одним happy path.

| Точка сбоя | Ожидаемый результат после пересоздания зависимостей |
|---|---|
| До durable intent; после intent до requestStarted | Старая выдача не потеряна. Нет расхода issuer, незавершённый intent не требует login. |
| requestStarted сохранён, до transport call; неизвестно, был ли принят запрос | Recovery сначала проверяет toRef; ambiguous retry расходует **persisted** budget. Не сбрасывать budget при новом процессе/перезапуске. |
| Issuer request → parse → первый durable stage | Bounded SIGINT deferral охватывает request, parse и первую bounded stage-попытку, сохраняет полученную пару перед доставкой KI. Не охватывает бесконечные persistence retries. SIGKILL/hardware failure до durable stage остаётся честной A9-границей; невозможная гарантия не заявляется. |
| Stage завершён, ready-phase marker отсутствует/не записался | Recovery находит toRef по durable intent, даже без ready-phase, validation/commit продолжаются без нового issuer refresh. |
| User validation timeout/network/locked-storage после stage | Candidate остаётся recovery-eligible, не очищается как aborted explicit login. После устранения причины normal commit; protected read подтверждает нового пользователя. |
| User identity изменена: стабильный userID тот же, login переименован; отдельно другой userID | Rename login допустим при прежнем userID; candidate чужого userID не публикуется под старым user, расход не смешан. Quarantine/admin outcome по контракту, без самовольного device flow. |
| Перед atomic manifest commit / failure atomic replace / restart сразу после commit | Manifest целиком старый или новый, не hybrid. Сохранённый candidate не теряется; active ref после успешного commit указывает на полную проверенную пару. |
| После commit, перед retire старой generation; retire locked/timeout/failed | Новый active ref читается; retry cleanup адресный, никогда не удаляет active/newer user ref. Pending cleanup не мешает здоровой новой сессии. |
| Пробный write/read/delete по unique probe generation; failure probe | Probe не равен fromRef/toRef; не перезаписывает активные credentials и не расходует issuer refresh при недоступном pinned storage. Cleanup только probe, не candidate. |
| Stage write timeout; fake поздняя запись после возврата timeout | Нет abandoned-refresh deletion или file fallback; поздний toRef остаётся учтённым recovery intent и находится следующим процессом. Явная SS generation не переключается на file. |

Дополнительно injected manifest read error/truncated/corrupt state не превращается
в tombstone/непринятый logout. Согласованный recovery либо безопасная остановка;
не перезаписывать неизвестный manifest новым пустым состоянием. Сравнивать active
и candidate refs, token-пару, epoch/user и файлы **после** каждого перехода.
Atomic replace/fsync/checkpoint failure сохраняет Linux остальные поля общего
SYNC_STATE_PATH. V2 envelope не пишется в legacy raw-token namespace. Разрешённый
file backend имеет 0600; refresh pinned SS не создаёт file copy. Проверить payload
ASCII/base64url decode/readback и отсутствие credential values в manifest.

## Конкуренция, сигналы и административные действия — A6/A7/A8

- Два независимых процесса, общий только `/tmp` fake ledger/manifest/store и
  настоящий process-lock выбранного механизма. Синхронизировать barrier/Event,
  а не надеждой на миллисекундный sleep. Победитель A/B чередуется; в healthy
  race issuer refresh count=1, follower использует committed pair.
- Lock busy/timeout, смерть owner, отложенный writer: следующий owner проверяет
  intent/toRef/budget, не начинает blind повторный расход. Process test не
  заменять одним thread-lock unit test.
- Logout/новый explicit login/account switch в каждом существенном окне:
  до запроса, после requestStarted, после stage, после identity, после commit.
  Late response старого epoch не публикует новую active пару; адресная очистка
  не удаляет generation нового входа. Кнопки admin controls показывают состояние
  занятого/неопределённого renewal по контракту, не плодят параллельные grant.
- SIGINT single/double внутри bounded request→parse→durable-stage section:
  предыдущий signal handler восстанавливается; снаружи KI доставляется без
  бесконечной блокировки. SIGKILL до/после durable stage классифицируется честно.
- Две машины — разные local roots/выдачи; renew и local-only logout одной
  не отзывают другую. Credential values никогда не попадают в fake gist.
- TearDown отпускает все held workers, join/terminate bounded; orphan candidate
  не маскируется очисткой fixture до проверки durable evidence.

## Storage/UI/routing — A5/A7/A10/A12

Linux explicit SS `_ss=None` → typed unavailable; existing SS missing, locked,
timeout и generic read failure — отдельные fake ответы. Legacy discovery с
fake file present/absent остаётся совместимым; tombstone не разрешает discovery.
Недоступный SS не даёт нового device flow и не создаёт новый file fallback.
macOS missing Keychain не утверждает server revoke; generic network/read error
не сбрасывает usable auth. REST /user подтверждает identity **после stage**.
Типы readCredential ready/missing/locked/unreachable/timeout/corrupt/changed/
signedOut проверяются отдельно; readCredential не делает сеть. Missing признаётся
только после успешного обращения к доступному backend, не по исключению/timeout.
Compatibility marker credential-v2 защищает отдельный V2 namespace; изменение
legacy login/generation старым logout прекращает V2 session без resurrection.
Не обещать полноценный downgrade или совместную работу старого/нового binary.
Bearer только на разрешённом API origin; raw gist read без Authorization.

Routing matrix: GUI scheduled maintenance, wake/startup/restart, manual sync,
CLI login/status/logout/доступ к расходу, Advanced off и limits disabled.
Все защищённые запросы берут актуальную committed выдачу через auth owner;
CLI/GUI видят одинаковое durable состояние, не обходят refresh через старый
direct token-read. Existing access-only tests прогоняются через реальный старый
pipeline. Exact handler/callback wiring дополнительно проверяет Reviewer;
обычный AppDelegate или реальный refresh callback для теста не вызывается.

RU/EN actual Settings/main draw: healthy, renewing, unavailable/locked, candidate
pending, unresolved response, terminal bad-refresh/missing, local logout. Qt —
QLabel/QPushButton/Canvas actual text + hits; Swift — pure dependencies/shared
copy helpers + actual PNG + независимый Reviewer wiring, без observer production.
Renderer получает несекретный presentation snapshot; **никакого** DBus/HTTP или
повторного credential read в rendering, даже fake-успешного. Слоты controls fake.
Cache/durable state сравнивать после draw; no extra storage-write/login request.
Отметка времени только при известном timestamp. Никаких секретов в visible UI.

## Изоляция до запуска — обязательный review

1. Каждая Linux entry point/subprocess сначала `_isolate`, **до ccl**. Все new
   auth manifest/cache/root paths явно перенаправлены в `/tmp`; общий process
   fixture root передаётся как путь, credentials не передаются через argv/env.
2. Default запрещающие моки: real `vault._ss`, keychain read/write/delete,
   `common.http`, `sync.transport`, новый refresh HTTP/transport, limits fetch,
   usage scan/refresh, browser/device-flow. Разрешены только конкретные fake
   адаптеры каждого сценария; fallback real implementation запрещён.
3. Старого `_sync_env` недостаточно автоматически: до первого импорта/инициализации
   нового auth owner проверить его default transport/store/manifest/clock.
   Новые credential paths добавляются в fixture redirects; no real singleton.
   Дополнительный backend check ставится под mock **до** render/read.
4. Swift selftest стартует до обычного startup/AppDelegate, real data-dir mkdir,
   default auth-store/singletons. Fake clock/transport/secure store/manifest/lock
   передаются явно; UI через SYNC_PREVIEW и isolated volatile prefs. Explicit
   RU/EN, не force-RU appLang workaround и не unsafe preview. State/prefs после
   fixtures восстановлены. Новые no-due guards не считаются изоляцией.
5. Fake issuer принимает sentinel только на разрешённых endpoint; неожиданный
   вызов — FAIL. Counters/read ledger не выводят секреты. No real GitHub API,
   DBus/keyring, `/usr/bin/security`, credential files, пользовательские logs.
6. Проверки реальных файлов — максимум existence/mtime по старому isolation
   guard, не содержимое. Новый path guard проверяет расположение fake manifests.
   Если любой reachable runtime эффект не изолирован, запуск остановлен до fix.

## Будущая область записи и seams

Сейчас Tester пишет **только этот документ**. После code freeze и назначения
координатором предполагаются новые Linux файлы:

- `linux/tests/_auth_env.py`: injectable FakeClock/Issuer/secure store/manifest,
  counters, fault checkpoints и bounded subprocess bootstrap; import isolation.
- `linux/tests/test_auth_parsing.py`, `test_auth_lifecycle.py`,
  `test_auth_durability.py`, `test_auth_concurrency.py`,
  `test_github_auth_ui.py`: независимые contract/integration fixtures выше.
- Swift: тестовая ветка safe `--auth-selftest` либо назначенные существующие
  selftest-блоки; название/owner/входные deps определит accepted diff-plan.
  Если Developer выделит отдельный auth-core файл, Tester получает лишь отдельно
  назначенный тестовый файл/блок, не production store/parser/policy.
- Минимальные изменения existing vault/legacy tests только при выявленном новом
  контракте и назначении конкретного файла; старую regression не отключать.

Необходимые Developer seams: explicit clock, OAuth/protected transport с проверяемой
redirect policy, credential-store, atomic manifest, process-lock, checkpoint hook
или равноценный fake adapter. Checkpoints не наделяют production тестовым I/O;
Reviewer проверяет отсутствие unsafe default/auth constructor пути. Пока эти API
не опубликованы, конкретные новые source/test writer не назначены Tester.

## Запуски и гейты после production freeze

Сначала frozen hashes/source scope, compile/static inspection, независимый
isolation review. Лишь затем целевые тесты; команды ниже — будущие entry points,
файлы/arg ещё не существуют и не должны запускаться сейчас.

```sh
QT_QPA_PLATFORM=offscreen python3 -m unittest discover -s linux/tests -p 'test_auth_parsing.py' -v
QT_QPA_PLATFORM=offscreen python3 -m unittest discover -s linux/tests -p 'test_auth_lifecycle.py' -v
QT_QPA_PLATFORM=offscreen python3 -m unittest discover -s linux/tests -p 'test_auth_durability.py' -v
QT_QPA_PLATFORM=offscreen python3 -m unittest discover -s linux/tests -p 'test_auth_concurrency.py' -v
QT_QPA_PLATFORM=offscreen CCL_PREVIEW_DIR=/tmp/ccl-gh-auth-stability python3 -m unittest discover -s linux/tests -p 'test_github_auth_ui.py' -v
```

Swift: compile по принятому build/source-list, только temporary бинарь и module
cache. Root запускает подтверждённый safe selftest arg после review; полный
auth fixture и existing `--sync-selftest`/`--subscriptions-selftest` должны быть
совместимы и не менять persistent пользовательские defaults. Root один раз
запускает полный Linux suite на final revision в Ubuntu CI, **0 skip**; local
Qt SKIP и отсутствующий AppKit честно оставляют соответствующий draw непроверенным.
ALSE live/полгода real-world не заявляются пройденными по CI/симуляции.

Гейты: A1–A12 с actual authorized reads/counters, все checkpoint/routing случаи,
старые 401/SS/generations/local logout/isolation regressions; no sensitive data
в артефактах. Fail-before для игнорирования refresh и unavailable recovery —
через безопасную временную копию/fixture; mutation toRef recovery/request budget/
epoch fence должна ронять релевантную проверку, а не только parser assertion.
Никаких mutation production checkout или отключения настоящего flow без fake deps.

Отчёт: commit+diff/hash, точные команды/exit codes/run/skip, horizons/число protected
reads и renew, issuer расход/budget, candidate/epoch/durable ledger, PNG и safety
limitations. Счётчики и PASS не выдумывать до фактического запуска. Изоляция и
security-review относятся к exact freeze; код автора сам себя не принимает.
