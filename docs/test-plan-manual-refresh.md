# MANUAL-REFRESH — независимый тест-план

2026-10-07. Tester Sol/high. PROJECT_ROOT: `/private/tmp/ccl-manual-refresh.qMuRQa`.
Исходный HEAD: `189a60d19edfbd9fb2ace659d392ca9258ab541a`, база: `d607ff9`.
Контракт: [утверждённое предложение](manual-refresh-proposal.md); обязательная изоляция:
[006](../.patches/006-tests-touch-real-keyring.md), [011](../.patches/011-selftest-clock-can-escape-offline-fixture.md).
План составлен до чтения будущей реализации `Sources/QuotaRefresh.swift` и тестов автора.
Статус: независимая standalone фикстура написана после появления pure API;
координатор одобрил точные source/harness/runner fingerprints и команду.
2026-10-07 выполнено: **43 сценария / 454 assertions / 0 failures**, exit 0.
Этот результат относится только к pure source `76b66aa…` и прежнему harness.
Новый инкремент Code P2 и quiet recovery реализован в harness после передачи API.
После явного нового одобрения изоляции выполнено: **65 сценариев / 875 assertions /
0 failures**, exit 0, source `0cb916e6…` / harness `5af1e7bd…` / runner `e8ca809e…`.

## Pending credential whole-chain: 78 сценариев / 1089 assertions / 0 failures

По новому поручению координатора добавлен `pendingCredentialChecks` с реальным
`quotaReconcilePendingCredential`. Все Data — буквальные synthetic JSON в тесте;
PendingCredentialMemory записывает calls и моделирует только read/quiet store и
исполнение явного retirePending результата. Реальных credentials/helper/OAuth нет.

Контрактные последовательности:

- RAM pending после rotation, quiet write fails → следующее чтение требует permission:
  readInteractionRequired не маскируется writeUnavailable, pending сохраняется,
  write после read failure не происходит. Явный one-shot read находит новый CLI login:
  используется current, старый pending удаляется, stale candidate не записывается.
- Уже сохранённый candidate → retire без записи; повторное чтение не выполняет update.
  При неизменной старой паре следующий quiet retry сохраняет тот же RAM candidate.
- Missing, timeout, interaction-required, unavailable/cancelled, corrupt/signed-out JSON
  сохраняют pending без write; corrupt credential record возвращает invalidCredentials.
  Неизвестная refresh-only запись не считается доказанным usable новым login.
- Cancel до чтения → 0 read/0 write; cancel из read closure → 1 read/0 write,
  повторное cancelled действие не добавляет вызовов. Явное read permission не
  распространяется на последующий update: real pure helper policy вызывается с
  quiet update и recording closures, без настоящего RPC.
- Identity = access+refresh, а не JSON bytes. Порядок ключей/форматирование и
  посторонние MCP metadata при прежней паре не означают новый CLI login. Проверяются
  successful/failed quiet persistence, сохранение текущих metadata и CAS expected
  exact-current bytes. При write failure старые credentials не возвращаются как
  разрешение повторить OAuth; pending остаётся. Candidate pair с новой metadata
  считается уже сохранённой, без update. Изменение каждого компонента пары проверено
  отдельным входом distinct login.

Фикстуры считают read/update calls и порядок эффектов. Отсутствие OAuth callback в
pure API — статическое свойство seam, **не доказательство** no-OAuth-again в реальном
fetch. CAS/helper wiring, pipes/ACL и actual cancel/kill остаются review/QA границами.

Source во время подготовки изменён разработчиком: `8cb3beaa…` → `4b7f2046…`
(corrupt read classification) → `b118084f…` (semantic identity/rebase). Назначенные
harness/runner guards/README/этот план изменены после 65/875/0. HEAD по-прежнему
`189a60d19edfbd9fb2ace659d392ca9258ab541a`, дерево общее с незакоммиченными правками.
После повторной проверки изоляции точных входов новый batch скомпилирован и выполнен:
78 сценариев / 1089 assertions / 0 failures, exit 0. Артефакты:
`/private/tmp/ccl-manual-refresh-independent-run.5qrJeA`. Production и тесты автора тестировщик не менял.

## Новый инкремент: выбор fallback и явный recovery read permit

Координатор передал подтверждённый Code P2: integration вызывает `quotaFallback`
только при `previous.asOf > response.asOf`, подменяя nil на distantPast. При двух
nil даты равны, поэтому существующие проценты могут быть потеряны. Ранее выполненные
тесты вызывают reducer напрямую и не доказывают корректность условия его выбора.
Нужен настоящий pure selection seam, используемый обоими production путями
doRefresh/cache; тест не должен воспроизводить прежний date guard самостоятельно.

План независимых регрессий до чтения нового API:

| ID | Вход/действие | Контрактный oracle |
|---|---|---|
| M08S1 | previous содержит session/weekly, asOf=nil; failed response пустой, asOf=nil. | Сохранены известные проценты, asOf остаётся nil; актуальные error/auth/Retry-After относятся к новой попытке. Не создаётся свежий успех. Это основной подтверждённый P2. |
| M08S2 | Та же пара nil/nil, previous содержит только session=0, только weekly=0 либо только один ненулевой процент. | Ноль считается известным значением; частично заполненный снимок не теряется. Нет подстановки now/distantPast в отображаемый asOf. |
| M08S3 | И previous, и failed response не содержат ни значений, ни asOf. | Сохраняется отсутствие данных и актуальная ошибка; не выдумываются проценты или дата. |
| M08S4 | Ответ apiFresh=true, проценты прежние либо изменились; known/nil previous.asOf. | Принимается свежий ответ и его собственный asOf, без ошибочного отката на previous или синтетической даты. |
| M08S5 | Nonfresh снимки с actual readings: previous новее, response новее; только одна дата известна; обе даты nil. | Для двух populated снимков known timestamp предпочтительнее unknown; более новый known выигрывает. При обеих nil берётся candidate с его nil — хронология не выдумывается. Empty failed candidate сохраняет known prior независимо от дат. Поля и asOf переходят вместе, ошибки/серверный запрет новой попытки сохраняются. |
| M11Q1 | startup/timer/wake/обычный manual refresh; quiet credential read требует interaction. | В этих контекстах нет интерактивного read permit. Interaction-required отделён от missing/expired; виден явный следующий шаг восстановления. |
| M11Q2 | Отдельное явное действие Restore access для Claude после interaction-required. | Только разрешённый recovery read получает permit; обычный refresh от такого действия не приобретает автоматическое право на последующие системные запросы. |
| M11Q3 | Cancel/completion/смена запроса или выбора после явного recovery; затем фон/обычный refresh. | Нет утечки разрешения в другой запрос/контекст. Точные границы lifetime/consume проверяются после передачи контракта pure policy API. |
| M11Q4 | Реальный missing, auth-expired и временная quiet-read недоступность. | Причины и адресные recovery действия различимы; состояние данных/asOf само по себе не выдаёт auth evidence или permit. |

Предоставлены `quotaSelectSnapshot`, `QuotaKeychainReadPermit`,
`ClaudeQuotaHelperRequest.parse`, `quotaHelperInteraction` и feedback с
credentialIssue/permissionPending. Precedence уточнён координатором и отражён выше;
ожидание old для двух populated undated снимков исправлено до первого запуска.
Новые сценарии находятся в `selectionAndPermissionChecks` независимого harness:

- P2 вызывает именно selection seam для empty failure, а не только fallback reducer:
  нули/частичные session/weekly, scoped-only, credits zero × known/nil даты;
  fresh всегда выигрывает, отсутствие данных не создаёт значений/даты.
- Permit: одна admission, repeated admission без нового launch, cancel до/после
  admission и повторный cancel, фиксированная граница 15 секунд, nonfinite now,
  throwing launch потребляет permit и освобождает lock для последующего cancel.
- Helper parser: interactive update/write и malformed args отвергаются.
  Даже direct request в обход parser не разрешает interactive update с read permit.
- Helper policy: recording closures проверяют UI-off до любого synthetic RPC;
  failure при quiet configure и при interactive enable даёт ноль RPC. Обычные
  read/update никогда не включают UI. Интерактивное чтение — только соответствующий
  request после успешного UI-off/enable, backend status передаётся без подмены.
- RU/EN: readInteractionRequired → явный allowKeychain, pending permission → cancel,
  ordinary pending без permission action, writeUnavailable → restoreAccess,
  timeout/unavailable/cancelled не выдумывают разрешение или истёкший вход.

Closures только увеличивают счётчики/записывают массивы в памяти; launch/process
не вызываются. NSLock используется внутри настоящего pure permit; reentrant calls
под lock и потоки не создаются. Source/harness/runner SHA снова передаются
на isolation review до любого запуска. Native Keychain/helper/app не вызываются.
Даже PASS pure policy не доказывает UIoff перед RPC, process/pipes bounds,
отсутствие секретов в argv или actual permit wiring — это review/QA граница.

HEAD инкремента `189a60d19edfbd9fb2ace659d392ca9258ab541a`. После старого PASS source
изменён разработчиком: добавлены selection/permit/policy и credential feedback;
во время подготовки hash менялся с `8a80dc2f…` на `0cb916e6…` (permission feedback
учитывает local cooldown). Самостоятельно изменены только назначенные fixtures,
README/runner guards и этот план; production не редактировался. Новый pure runtime
после одобрения выполнен успешно; полные текущие hashes — в README фикстуры; старые доказательства ниже
сохраняют первоначальные fingerprints. Чужие незакоммиченные изменения сохранены.

Фактическая команда нового прогона: `sh fixtures/manual-refresh-independent/run.sh`
из PROJECT_ROOT. Copied inputs подтвердили SHA до компиляции; после исполнения
source/harness/runner и копии совпали с разрешёнными fingerprints. Всего 65 сценариев,
875 assertions, 0 failures; относительно прошлого прогона добавлены 22 сценария и
421 assertion. Артефакты: `/private/tmp/ccl-manual-refresh-independent-run.eIeFDq`;
binary SHA `e83c044159c809e1ced53c94d3daaa568586a5e3e5acbd38ea29ee06e7dd00c5`.
Toolchain снова вывел FSEvents/confstr cache warnings; compile/runtime exit 0.
После проверки изменены только README фикстур и этот тест-план для записи результата;
исполняемые входы и runner неизменны. App/native helper, credentials, API не вызывались.
Baseline FAIL и actual integration/native policy по-прежнему не проверены.

## Матрица контрактных проверок

Все даты синтетические и фиксированные; контроль времени осуществляется явным
аргументом или fake clock. Ни ожиданий реального времени, ни sleep. Сценарии
проверяются для Codex и Claude, одного/двух включённых сервисов, Auto и каждого
поддержанного фиксированного интервала, если контракт соответствующего API позволяет.

| ID | Сценарий | Наблюдаемый результат |
|---|---|---|
| M01 | Последняя попытка менее 900 с назад; короткая защита уже истекла. Автоматический запрос ещё не due, затем ручной. | Ручной запрос допускается ровно один раз. Выбранный режим/интервал не переключается; следующий автоматический тик не создаёт немедленный дубликат. |
| M02 | Последний ответ — локальная сетевая ошибка, следующая автоматическая попытка далеко в будущем. | После короткой защиты ручная попытка доступна. Локальная пауза не обозначается запретом сервера. |
| M03 | Ответ сервера содержит действительный Retry-After. Часы до срока, на точной границе и после. | До срока ни manual, ни auto не начинают запрос этого сервиса. На границе сервис доступен; причина и deadline серверные. Другой сервис независим. |
| M04 | Codex in-flight, Claude свободен; затем поменять роли. Также один сервис заблокирован сервером. | Свободный включённый сервис стартует. Busy/blocked сервис не получает второй запрос; общий флаг не блокирует оба. Выключенный сервис не запрашивается. |
| M05 | Оба запроса начались. Один завершается успешно, второй остаётся pending, затем ошибается. Проверить оба порядка. | Успешный результат и его asOf доступны сразу, второй остаётся pending. После частичной ошибки целевой retry запрашивает только проблемный сервис. |
| M06 | Двойной клик при одном now, клик во время in-flight, клик до/на/после границы короткой защиты. | Нет дубликатов. Причины pending/local cooldown различимы; точная граница доступности — 30 с, подтверждено координатором после раннего плана. |
| M07 | Успешный свежий ответ содержит те же проценты и reset, что старый снимок. | Успех/checkedAt фиксируется несмотря на равные значения. asOf соответствует действительно полученным данным; отсутствие изменения процентов не считается fallback/ошибкой. |
| M08 | Ошибка с fallback старого снимка; повторить с известным asOf и nil asOf. | Старые значения сохраняются, исходный asOf не заменяется текущими часами. Последний успешный результат не объявляется новым; nil не получает выдуманную дату. |
| M09 | Retry-After: delta 0/1, положительный срок, прошлая/будущая HTTP-date, пустой/невалидный, отрицательный, дробный, чрезмерный и не конечный ввод. | Без crash/overflow/NaN deadline. Неизвестный срок остаётся неизвестным и не показывается выдуманным server countdown. Валидный долгий запрет не сокращается с ранней повторной отправкой. Конкретная политика bounds/parser передаётся координатором. |
| M10 | Ответ A опаздывает после запроса B; duplicate completion; выключение сервиса во время A; выключение/повторное включение и новый B. | Поздний/повторный ответ не заменяет B, не снимает его in-flight и не меняет его deadlines. Изменение выбора не публикует данные чужого поколения и не запускает выключенный сервис. |
| M11 | Подтверждённая auth-ошибка, недоступность локальных credentials, сетевая ошибка, stale без подтверждённой auth-проблемы. | Адресное recovery action соответствует сервису/причине. Обычный refresh не выдаёт разрешение на интерактивный login/system UI и не выполняет его. Stale/network не подменяются истёкшим входом. |
| M12 | Последнее успешное получение, последняя неудачная попытка и следующая автоматическая попытка имеют три разные даты. | Семантика дат различима, ручной refresh не меняет выбранное расписание. RU/EN тексты и Simple/Advanced проверяются отдельным QA; pure presentation API проверяется, только если входит в seam. |

Проверять результаты настоящей pure state machine и список её request intents;
oracle состоит из фиксированных ожидаемых результатов контракта, без копии production алгоритма.
Порядок завершений управляется вручную; thread/Task/dispatch запуск не нужен.

## Необходимые seams от разработчика через координатора

1. Отдельный Foundation-only `Sources/QuotaRefresh.swift`, без AppDelegate,
   AppKit/Security, сетевых/файловых/store/process эффектов и глобальных startup.
   Точная команда должна компилировать только этот файл и независимый harness.
2. Явные `now` для due/manual begin/completion/Retry-After либо injected clock;
   никакого скрытого `Date()` в этих путях. Наблюдаемые mode/interval/nextAutoAt,
   per-provider pending/lastSuccess/asOf/local pause/server wait и причины отказа.
3. Входы manual-all/manual-provider/automatic, выбранные сервисы, результаты
   fresh/fallback/network/auth/server restriction с синтетическими timestamps.
   Выход — request intents или token при begin, без автоматического вызова транспорта.
4. Request identity/generation и completion с тем же identity; invalidation при
   смене выбора. Это нужно для M10, включая stale completion во время нового pending.
5. Pure parser Retry-After с injected reference time, точная политика допустимых
   значений/bounds/unknown и короткая retry duration. Не фиксировать неоговорённый
   max timeout в тестах как продуктовое требование.
6. Типизированное recovery action/interaction policy либо доступная pure projection.
   Только наличие enum не доказывает отсутствие системного prompt в integration:
   это остаётся предметом code/security review и отдельно изолированного QA.

После появления API независимые фикстуры пишутся только в
`fixtures/manual-refresh-independent/`. Production и тесты автора не меняются.
Интерфейсы согласуются через координатора; прямых сообщений другим агентам нет.

## Изоляция и разрешение исполнения

Разрешены статическое чтение и запись назначенных файлов. До одобрения
координатором изоляции конкретного дифа и конкретной команды запрещены компиляция
с последующим запуском, запуск тестов/app/selftest и иных runtime-путей.
Предлагаемый harness: standalone Swift entry point с in-memory fake clock,
request recording и controlled completions. Запуск без production main/build.sh,
AppDelegate, credentials, Keychain, API/gist, userlogs, CLI home и defaults.
Новые runtime зависимости исключены; любой необходимый effect требует запрещающего
или recording fake до запуска. HOME/tmp сами по себе не обеспечивают изоляцию.

Координатору перед исполнением передаются точные paths, source/harness fingerprint,
проверка импортов и достижимых побочных эффектов, предложенная команда с output
только в назначенном каталоге либо отдельном `/private/tmp` и список тестов.
Точная одобренная команда и fingerprints приведены в
[README фикстуры](../fixtures/manual-refresh-independent/README.md); команда выполнена
после явного одобрения координатором полного pure source, harness и runner.
Одобрение приложения/native runtime не давалось.

## Реализованные проверки и пробелы API

`fixtures/manual-refresh-independent/ManualRefreshIndependent.swift` вызывает
настоящие `QuotaRefreshState.admit/setEnabled/complete/nextAttempt`,
`quotaRetryAfter`, `QuotaHTTPFailure`, `quotaFallback`, `quotaRefreshFeedback` и `quotaCountdown`.
FakeClock — простое синтетическое число;
ControlledProvider записывает допущенные tickets и принятые completions,
не вычисляет eligibility, не выполняет транспорт и не публикует quota snapshots.
Ожидания независимые: фиксированные deadlines и статусные контракты. Компиляция
использует ровно два source-файла без приложения и тестов автора.

- M01/M02: manual до 900 с, supplied schedule при 900/1800/3600/14400 с,
  отказ scheduled до срока, отсутствие немедленного дубликата, local/server distinction.
  Seam не представляет причину local error либо Auto mode: фактическое сохранение
  режима и вычисление error backoff в интеграции этой проверкой не доказаны.
- M03/M04/M06: server boundaries, short/long bans, busy/free/disabled состояния,
  exact 30-second guard и долгий in-flight. Состояния двух сервисов поданы отдельно:
  harness доказывает per-instance independence, не правильность маршрутизации UI.
- M05: раннее принятие одного completion при pending второго и целевой retry
  через dependency spy. Это частичное покрытие: нет API успеха/ошибки/snapshot,
  поэтому immediate partial-success publication и retry-кнопку UI не доказывает.
- M07/M08: после появления feedback и `quotaFallback` seam добавлены RU/EN fresh
  success против старой ошибки, old/nil dataAt при pending/failure, отдельные
  nextAutomaticAt и recovery actions. Pure reducer проверяет unchanged свежие
  session/weekly/reset с новым asOf; fallback сохраняет старые session/weekly/reset,
  scoped/plan/credits и известный/nil asOf, но передаёт текущие error/auth/Retry-After.
  Проверяется путь fallback → feedback. Настоящий completion/publisher и маршрутизация
  receipt по ticket остаются integration пробелами; fake publisher не добавляется.
- M09: delta/date parser, malformed/empty/negative/fractional/nonfinite/overflow,
  long valid ban без 1-hour cap; parser-to-scheduler путь, RU/EN feedback server/local/unknown,
  countdown finite/huge bounds, subsecond rounding и exact boundary. Нет выдуманного
  server countdown при неизвестном deadline; форматирование не меняет nextAutomaticAt.
- M10: duplicate/foreign/obsolete completion, re-selection и current pending.
  В текущем API старый worker остаётся reserved при disable/re-enable до его
  completion; тест проверяет отсутствие overlap и false publication permission.
  **Подтверждённый Security T2 P2:** start → disable/enable → completion с future
  server deadline → manual до deadline должен вернуть serverWait, при том что
  completion возвращает false для UI. Серверный запрет переживает смену выбора.
  Completion во время disabled сохраняет deadline для последующего enable.
  Поздние duplicate callbacks не снимают ограничение и не освобождают чужой flight.
  Реальное применение snapshots и реальная отмена транспорта здесь не представлены.
- M11: HTTP/OAuth auth evidence classification, отсутствие auth для 403/429/5xx,
  сосуществование auth и retry metadata; parser/state путь для 401 и token-endpoint
  invalid_grant сохраняет ban. RU/EN restoreAccess против network retry/stale/missing,
  pending не возвращает recovery action; restoreAccess сосуществует с server wait.
  Это **не доказывает** передачу metadata
  настоящим Claude adapter, адресную команду восстановления, no-interaction policy
  или отсутствие системного окна: эти integration surfaces не вызываются.
- M12: nextAttempt deadlines и RU/EN раздельные dataAt/nextAutomaticAt представлены;
  Auto mode persistence, Simple/Advanced и настоящий UI остаются QA пробелами.

Pure source менялся во время подготовки: исходный read hash `304bb52d…`, затем
feedback/init `bc735629…`, P2 fix `2046d824…`, перенос snapshot/reducer `0c684a88…`
и auth action при server wait `76b66aa0…`. Фикстура откорректирована по
контракту Security T2, а не по прежнему false expectation о потере serverUntil.
Копия `/private/tmp/ccl-manual-refresh-independent-baseline.N8T7rZ/QuotaRefresh.swift`
сохранена по разрешению координатора; её SHA совпал уже с source после P2 fix.
Она не является доисправленной базой, baseline FAIL не получен и не заявляется.

API прочитан в новом `Sources/QuotaRefresh.swift` после утверждения ранних случаев.
Поиск имён интеграции в monolithic `LimitsMonitor.swift` случайно вывел строки
старых встроенных selftest; их сценарии/ожидания не использованы при создании
фикстуры. Отдельные файлы тестов автора не читались.

## Фактическое состояние и ограничения

- Начальная read-only проверка: HEAD `189a60d19edfbd9fb2ace659d392ca9258ab541a`,
  ветка `codex/manual-quota-refresh`, `git status --short` пустой.
- Выполнены чтение AGENTS/контракта/памяти/006/011, поиск будущего pure API и
  `git diff --stat d607ff9..HEAD`: четыре документационных файла, 18 additions / 2 deletions.
  В момент первоначального поиска `QuotaRefresh.swift` ещё отсутствовал;
  при продолжении предоставлен отдельный Foundation-only API.
- HQ `now.md` отсутствует в подключённом HQ (read command exit 1); PROJECT_ROOT
  установлен прямо поручением, карта не использована как доказательство checkout.
- Выполнена ровно одобренная команда:
  `/bin/sh /private/tmp/ccl-manual-refresh.qMuRQa/fixtures/manual-refresh-independent/run.sh`.
  Pure compile/runtime: exit 0, 43 scenarios / 454 assertions / 0 failures.
  Runner проверил SHA copied inputs до компиляции; post-run source/harness/runner
  и copied-input SHA совпали. HEAD остался `189a60d19edfbd9fb2ace659d392ca9258ab541a`.
- Runtime source SHA `76b66aa05e6eb67af057c7a99744e645df1ca665900dfb35f0d75c6e39e3e6af`,
  harness SHA `bb1b1e826fb281d3c66f3684066c7f485ee97d7cf1d4ce706e26239a2ffab2ae`,
  runner SHA `eb70330cab4274bcca67c72cb06126d12110bb0a4875bd584f5bae0964af39b1`.
  Артефакты: `/private/tmp/ccl-manual-refresh-independent-run.drtyfP`; binary SHA
  `a6783c38ab867b8341ccdf30891e31f074453b6a6d4cffc3ac6951effd5d544c`.
- xcrun/xcodebuild вывели предупреждения FSEvents и confstr cache с fallback;
  компиляция и выполнение завершились успешно. Baseline FAIL, GUI,
  auth/no-prompt integration, native ACL, packaged bundle и реальные API не проверены.
- После запуска изменены мои README/test-plan для фиксации результата, затем по
  поручению координатора runner: absolute repo root вычисляется от каталога скрипта
  через ../.. с quoted paths и CDPATH отключённым для cd. SHA input guards и harness
  неизменны. Новый runner проверен только `/bin/sh -n`, exit 0; тесты повторно не
  запускались. Результат 43/454/0 относится к прежнему runner SHA, приведённому выше.
  В общем дереве есть чужие незакоммиченные production/docs правки, сохранённые
  без вмешательства. Новая команда из корня: `sh fixtures/manual-refresh-independent/run.sh`.
- Общую приёмку и запуск после ревью изоляции выполняет/разрешает координатор.

Координаторская фиксация последнего прогона: команда `sh fixtures/manual-refresh-independent/run.sh`,78scenarios/1089assertions/0fail, exit0. Inputs b118084f/8aea790e/6e5c67f6; артефакты /private/tmp/ccl-manual-refresh-independent-run.5qrJeA. После теста исполняемые входы не менялись. Реальные native/API/credentials не использовались.
