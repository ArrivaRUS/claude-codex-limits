# Ревью REMOTE-LIMITS C1 (macOS) — code-reviewer, 2026-10-18

Нужно от Юрки: решение по M1 (это задумано или нет) и по m7 (synth §F и sync-protocol расходятся); T2 — security-analyst, поскольку Security surface = да.

**Итог:** блокеров нет. Нужен один цикл правок: 2 major и minor-находки. Ревью статическое (Linux-VPS, Swift не собирался), поэтому сборку и `--sync-selftest` нужно прогнать на маке.
**Ревизия:** `git diff d54864e..e3a5ac6 -- Sources build.sh` (`RemoteLimits.swift` — новый файл, `LimitsMonitor.swift` +186/−8, `QuotaRefresh.swift` +1, `build.sh`). Контракт тестов — `RemoteLimitsSelfTests.swift` (301d0dc). Сверка с `linux/ccl/sync.py`, `accounts.py`, `common.parse_iso`, `docs/sync-protocol.md` §Reader limits/Grouping и `arch/plan-synth.md` §F.

## Компилируемость

**Уверенных ошибок компиляции нет** (Codex Sol пришёл к тому же). Места, которые отметил разработчик, проверены — все корректны:
- `RemoteLimits.swift:108/150`, `LimitsMonitor.swift:2265`: `(48...57).contains($0)` с UInt8 — диапазон выводится как `ClosedRange<UInt8>`.
- `:110–113`: `import CryptoKit` есть в обоих файлах (`RemoteLimits.swift:3`, `LimitsMonitor.swift:12`). `Data(SHA256Digest)`, `SymmetricKey(data:)`, `HMAC<SHA256>.authenticationCode(...).prefix(8)` — дайджест и MAC являются `Sequence<UInt8>`. Конфликтующих `SHA256` в проекте нет.
- `:156`: `String(cString: n.objCType)` — допустимо.
- `:375/388/425/447`: вложенный `$0` во внутреннем замыкании допустим. Внешнее замыкание с именованным параметром `new` плюс внутреннее с `$0` тоже допустимо.
- `:423–477`: локальная функция `make` захватывает `var own` — допустимо, функция не escaping и не `@Sendable`.
- Однострочные `switch` с `;` (`:404`, `:532`) — допустимы, `SyncPhase` перечислен полностью (4 case).
- `LimitsMonitor.swift:98–127`: `URLSessionDataDelegate` — сигнатуры совпадают (внутренние имена `chunk`/`failure` не важны). Без `@Sendable` у completionHandler — так же, как в уже компилирующемся `SyncNoRedirects`.
- Вложенный кортеж `((0, nil, "…", [:]), true)` → `(reply: SyncHTTPResult, refused: Bool)` получает контекстный тип; `min(by:)` с захватом inout-параметра в non-escaping замыкании допустим.
- Memberwise-инициализаторы, которые нужны тестам (`LimitData(present:)`, `SyncCachedMachine(id:name:os:updated:)`, `DayModelUsage(input:…)`, `ScopedLimit(…)`), существуют.

**Риски (не ошибки):** `RemoteLimits.swift:141` `contains(where: unsafe)` — в Swift ≥ 6.2 `unsafe` контекстное ключевое слово. После него идёт `)`, поэтому парсится как идентификатор, но лучше переименовать в `isUnsafe`. Длинные булевы цепочки `:425`, `:439–440` — небольшой риск «unable to type-check in reasonable time».

## Блокирующее мерж (blocker/major)

- **M1 major (латентный, до C2)** `RemoteLimits.swift:441–444` — если на локальной карточке побеждает чужой снимок, `values = limitData(best)` целиком заменяет `own`. Теряются локальные `auth`, `credentialIssue`, `refreshInFlight`, `permissionRequestInFlight`, `pollFailed`, `nextPollAt`, `localRetryAt`, `serverRetryAt`, `error`. После подключения в C2 при VPS-издателе (свежее каждые 15 мин) исчезнут спиннер ручного обновления, просьба о доступе к Связке ключей и «вход истёк» этого Мака. **Как показать:** селфтест — локальный `LimitData` с `auth = .expired`, `refreshInFlight = true`, `asOf` старше `vps` → у `card.data` будет `auth == .ok` и `refreshInFlight == false`. **Фикс:** начинать с `own` и переписывать только поля снимка (session/weekly/resets/scoped/plan/resetCredits/asOf/apiFresh/fromCache) + `source`. Если поведение задумано — нужна запись в решениях.
- **M2 major (Codex: major; то же в Linux `sync.py:1146`)** `LimitsMonitor.swift:2853–2855` — `rejectRaw` вызывается, когда тело больше `cap = min(8 МиБ, остаток бюджета)`. Обычный файл на 2 МиБ при остатке бюджета 1 МиБ на 24 ч попадает в кэш отказов. Это противоречит `sync-protocol.md:511–512` (в кэш идёт только превышение 8 МиБ). Последствия смягчает то, что в `raw_url` есть SHA ревизии: запрет держится до следующей записи этой машины. **Как показать:** фейковый транспорт, прочитано 63 МиБ, следующий файл на 2 МиБ → его ключ оказывается в `syncRejectedRaw`, и на следующем цикле со свободным бюджетом файл пропущен. **Фикс:** кэшировать отказ только при `cap == syncMaxMachineBody`, а исчерпанный бюджет учитывать лишь в текущем цикле. Исправить в обоих портах.

## Находки minor / nit

- minor `RemoteLimits.swift:273` — предел метаданных 4 КиБ считается по `JSONEncoder`: `Date` уходит как Double, `label: nil` опускается, `/` экранируется. Linux считает исходные ISO-строки, поэтому даты с дробью ~3000 знаков дают разную атрибуцию (Codex + моя находка). Фикс: считать по очищенному wire-словарю с исходными строками дат.
- minor `LimitsMonitor.swift:1455` — ответы POST/PATCH читаются без предела, а у Linux `_transport` предел 16 МиБ стоит на всех ответах (Codex).
- minor `LimitsMonitor.swift:2836–2870` — нет общего срока чтения raw (у Linux `_read_timeout(30)`): до 64 файлов × 4 перехода × 25 с в очереди синка.
- minor `RemoteLimits.swift:330` + `:179–181` — `updated` проверяется через `text()` с пределом 4096 и обрезкой только `.whitespaces`. У Linux `parse_iso` нет ни того ни другого (`strip()` снимает все пробельные символы, `\d` принимает Unicode-цифры). На враждебном `updated` Swift отбрасывает весь файл, а Linux его оставляет.
- minor `RemoteLimits.swift:164–167, 226, 327` — `legacyInteger` принимает `1.0` для счётчиков и `schema` (так задумано для совместимости со старым маковским reader), Linux такое отвергает. В фикстурах этого случая нет. Фикс: записать расхождение в sync-protocol или добавить фикстуру.
- minor `RemoteLimits.swift:351` — `machineLastSeenAt = lastSeen ?? updated` включает состояние 5 «оффлайн» для файлов без `lastSeenAt`. Так требует synth §F, но `sync-protocol.md:521–522` говорит обратное — документы нужно согласовать.
- minor `LimitsMonitor.swift:2469` — при выходе из GitHub не очищается `syncRejectedRaw`.
- minor `QuotaRefresh.swift:46` — `QuotaRefresh.swift` больше не собирается отдельно: `RemoteSource` лежит в `RemoteLimits.swift`, а тому нужны типы из main. Из-за этого ломается `fixtures/manual-refresh-independent/run.sh` (его sha-пин к тому же устарел). Фикс: перенести `RemoteSource` (только Foundation) в `QuotaRefresh.swift`.
- nit `RemoteLimits.swift:384` — подписи перебираются в отсортированном порядке, а у Linux — в порядке файла: при числе подписей больше 64 выбирается другой набор.
- nit `RemoteLimits.swift:461` — у локальной карточки в подписи буквально `"mac"`, а не `machineTag`; `:473` — подписи из кэша показываются и при выключенном синке.
- nit `LimitsMonitor.swift:2834–2870` — `readWarning` перезаписывается последним событием, а Linux предпочитает `size_error`. `mergeV11` заново реализует корневые `days`, а не вызывает существующий `merge` (synth §F) — это оправдано паритетом с Linux.

## Расширения вне C1

1. **`syncRejectedRaw` — принять.** Хранится только `sha256(raw_url)[:16]` в hex → время отказа. Сам URL и gist id не хранятся (A1-25 соблюдён). Срок 24 ч проверяется при чтении, записи с будущим временем отбрасываются, не больше 64 записей, при переполнении вытесняется самая старая — паритет с Linux `_raw_key`/`_rejected_raw`. Остаются M2 и очистка при выходе (minor).
2. **Все GET `syncHTTP` через ограниченный транспорт, включая `/user`, — принять.** Для API предел 16 МиБ, редиректы по-прежнему отклоняются (раньше это делал `requestHTTP(noRedirects:)`), сессия ephemeral, без cookies и credential storage. Неавторизованный GET разрешён только на `gist.githubusercontent.com`, причём проверка повторяется на каждом переходе. `http()` и `latestRelease()` это не затрагивает. Пробел — POST/PATCH (minor).
3. **Имя чужой машины ≤ 16 символов и «?» при управляющих символах — принять.** Паритет с Linux `_machine_text`. Для пиров v1.0 это строгое улучшение: раньше `m["name"]` попадал в UI вообще без очистки. Цена — длинные hostname обрезаются до 16 символов.
4. **`LimitData.source` — принять**, это требование `plans.md` §C1 и synth §F. Побочный эффект — minor про `QuotaRefresh.swift`.

## Codex-проход

`gpt-6.1-sol` @high, read-only, `service_tier=default`, по `~/.cache/ccl-review/c1.diff`; 429 не было, ~98,6 тыс. токенов. Нашёл M2 (major), POST/PATCH без предела (minor), предел 4 КиБ (minor). Ошибок компиляции не нашёл. Все три находки сверены с кодом и подтвердились.

## Security

Секретов нет, к raw не уходят ни bearer-токен, ни cookies. Списки допустимых хостов работают на каждом переходе редиректа, тело ограничивается потоково (`cap + 1`). Из проблем — только M2, а также minor про POST/PATCH и общий срок чтения.

**Security surface: да.** Диф трогает парсинг недоверенного входа (JSON машин из gist), сетевой транспорт (редиректы, пределы тела, allowlist URL) и постоянное состояние в `UserDefaults` → T2 `security-analyst` до мержа.

**Вердикт:** нужен ≥1 цикл правок (M1, M2 + minor по решению Юрки), затем сборка и `--sync-selftest` на маке.
