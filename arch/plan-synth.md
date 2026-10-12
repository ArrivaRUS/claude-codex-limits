# REMOTE-LIMITS — синтез архитектуры, версия 2 (самодостаточный план)

Дата: 2026-10-12. Заменяет v1 (`arch/plan-synth-v1.md` — дельты к плану #1). Входы: план #1 `arch/plan-claude.md` (база), план #2
`arch/plan-codex.md`, челлендж Astra `arch/challenge-codex.md` (14 несостыковок), PRD `docs/prd-remote-limits.md` (G1, решения
владельца 1–7), UX `design/remote-limits-ux.md` (G2b), код macOS 3.2.7 / Linux 0.4.5 (строки проверены заново). Решения Юрки по
спорным пунктам применены без обсуждения. Статус: T1 пройден (`docs/security-remote-limits.md`, 0 blocker), execution-pack — `docs/plans.md`.
Правки после T1 и замера (2026-10-12, вечер): риск 1 закрыт (`history` = 30 последних ревизий); `credential_write: never` по умолчанию на
всех портах (П3-д); потолок чужого `retryUntil` 24 ч от `firstSeenAt` (П7); `organizationUuid` снят (П1-а); сквозная привязка идентичности
(П2-в); теги машин `vps`/`macbook`/`thinkpad`; по расхождениям тест-плана (§6, решения Юрки): единая политика в начале каждой попытки
под замком, Т4 без привязки к поколению, отказ установки при живом трее, ожидание `sync` ≤ 60 с, пределы читателя в C7, `reader_card_state`.

## Итог

Один аддитивный блок `accounts` в `machine-<id>.json` (`schema: 1`), метка аккаунта = HMAC от **локальной** идентичности с ключом из id
gist, считается только при сборке блока; все локальные хранилища живут под локальной идентичностью. На VPS — проход издателя внутри
штатного `ccl-sync push --auto` (таймер 5 мин) под `file_lock("quota")`: GET gist → решение B2 → **PATCH попытки → запрос к провайдеру
→ PATCH результата**; три отпечатка записи (расход с полом 10 мин · метаданные без пола · heartbeat раз в 10 мин). B2 — «чужая
попытка моложе 960 с или чужой успех моложе I+60 с → пропуск», часы сверяются по заголовку `Date` GitHub. Токены: `credential_write:
never` на машине с живым CLI, смена политики только под замком. На маке — чистый резолвер аккаунтов поверх `SyncRemoteCache`, два
слота `claude`/`codex` как сегодня, B2 через `syncNow(completion:)`.

## Закрытие 14 несостыковок челленджа (все закрыты; №7 — иначе, чем предлагала Astra)

| № | Что изменено | Где |
|---|---|---|
| 1 | Смена `credential_write` только под `file_lock("quota")` при отсутствии ротации в памяти любого процесса (маркер `rotation-pending-<p>` с pid); все запросы к провайдеру в любом процессе идут под тем же замком; guard и в `_save_*`/`_rewrite_json` | §E |
| 2 | Трей в `delegated` не пишет `autoPollState`/`quotaServerRetryAt` вообще (и в `on_activity`): `save_poll_states` — no-op, `local_activity` применяет только проход; циклы синка трея `allow_push=False` | §C «Трей» |
| 3 | `cache.json[p].accountId` и `publisher-state.json` под локальной идентичностью; C3-fallback только внутри того же аккаунта; для нового аккаунта до первого успеха значений нет | §B, §C шаг 6c, §F |
| 4 | `GitHubSync.syncNow(mode:completion:)` с исходом `.read(generation, cache)/.failed/.skipped` через единый `defer`; продолжение B2 только из completion, `onChange` — только UI | §F «B2 на маке» |
| 5 | Последовательность «PATCH `attemptAt` → запрос → PATCH результата» явно в проходе; одно имя `attemptAt`; отказ PATCH попытки → `poll_skipped publish_failed`, запроса нет; бюджет пересчитан | §C шаги 6–7, таблица бюджета |
| 6 | Тай-брейк ждёт не больше одного тика на конкретную пару `(machineId, nextAt)`, только при живом источнике (`lastSeenAt` ≤ 15 мин); неизменная запись второй раз не задерживает | §D правило 4 |
| 7 | Привязка к поколению `.credentials.json` снята; источник только `~/.claude.json → oauthAccount.accountUuid`, перечитывается каждый проход; смена значения = смена аккаунта; нет поля → `label: null`; лаг кэша после смены аккаунта — известное ограничение; `identity_unknown` не вводится (решение Юрки) | §B |
| 8 | История/кэш/индекс под локальной `(product, localId)`; HMAC-метка только при сборке блока под текущий gist id; смена gist меняет метки у всех, ссылки читателей по меткам сбрасываются (редко, задокументировано) | §B |
| 9 | Отдельные числа допуска: установившийся 0 · событие ≤ 1 пара · gist недоступен ≤ 1 пара на 15 мин простоя · восстановление ≤ 1; «≤ 3 событий/сутки» убрано; в замере G1 периоды недоступности помечаются | §D «Допуск» |
| 10 | Запас 60 с и к `attemptAt` (960 с); опора времени — `Date` ответов GitHub, `clockSkew` в состоянии, > 60 с → `clock_skew` в журнал, status, гарантия B2 не заявляется | §D «Часы» |
| 11 | Три отпечатка: `pushHash` (расход, пол 570 с) · `metaHash` (попытка/результат/подпись, без пола) · `heartbeatAt` (свой срок 600 с); бюджет 1 GET + ≤ 2 PATCH на due-тик, иначе 1 GET + ≤ 1 PATCH | §C «Правило записи» |
| 12 | `RemoteAccount.machineLastSeenAt`, `SyncCachedMachine.lastSeenAt`, чистый `ReaderSyncState{phase, warning}` в аргументах резолвера; состояние 7 — без удалённых карточек | §F |
| 13 | История темпа по ключу `acct` (локальный отпечаток для своих, метка для чужих); приём чужих `asOf` без guard `productEnabled`; дедуп по `(acct, t)` | §F «История» |
| 14 | Обещание мгновенного возврата кэша снято; состояние 7 — без значений до первого успешного синка; UX-спек правится | §F.1 п. 5 |

## A. Контракт gist v1.1

Файл `machine-<id>.json` — целый идемпотентный снимок; `schema` остаётся `1`; новые ключи необязательны, старые читатели их игнорируют.

```json
{ "schema": 1, "machine": {"id": "5f0c…", "name": "vps", "os": "Ubuntu 26.04", "app": "linux 0.5.0"},
  "updated": "2026-10-12T10:15:03Z", "tz": "Etc/UTC", "lastSeenAt": "2026-10-12T10:15:03Z",
  "days": { "claude": { "2026-10-12": { "claude-fable-5-1": {"input": 1200, "output": 3400, "cacheRead": 900000,
                                                            "cacheWrite5m": 0, "cacheWrite1h": 52000, "turns": 41} } },
            "codex":  { "2026-10-10": { "gpt-6-astra": {"input": 1, "output": 1, "cacheRead": 0, "cacheWrite5m": 0, "cacheWrite1h": 0, "turns": 1} } } },
  "accounts": [
    { "product": "claude", "label": "3f9a0c71b2d4e5f6", "plan": "max", "tier": "default_claude_max_20x",
      "status": "ok", "asOf": "2026-10-12T10:15:02Z", "attemptAt": "2026-10-12T10:15:00Z", "attemptKind": "auto",
      "windows": { "session": {"pct": 42.5, "resetAt": "2026-10-12T13:00:00Z"}, "weekly": {"pct": 61.0, "resetAt": "2026-10-15T07:00:00Z"} },
      "models": [ {"name": "Fable 5.1", "pct": 70.2, "resetAt": "2026-10-15T07:00:00Z"} ],
      "schedule": { "mode": "auto", "interval": 900, "nextAt": "2026-10-12T10:30:00Z", "backoff": false }, "retryUntil": null,
      "days": { "2026-10-12": { "claude-fable-5-1": {"input": 1200, "output": 3400, "cacheRead": 900000, "cacheWrite5m": 0, "cacheWrite1h": 52000, "turns": 41} } } },
    { "product": "codex", "label": "a1b2c3d4e5f60718", "plan": "pro", "status": "expired", "expiredReason": "cli_refresh_pending",
      "asOf": "2026-10-12T06:40:11Z", "attemptAt": "2026-10-12T10:15:00Z", "attemptKind": "auto", "windows": {"session": {"pct": 12.0, "resetAt": "2026-10-12T11:40:00Z"}},
      "resetCredits": 2, "schedule": { "mode": "auto", "interval": 3600, "nextAt": "2026-10-12T11:15:00Z", "backoff": true },
      "days": { "2026-10-10": { "gpt-6-astra": {"input": 1, "output": 1, "cacheRead": 0, "cacheWrite5m": 0, "cacheWrite1h": 0, "turns": 1} } } }
  ],
  "unattributedDays": {},
  "captions": { "3f9a0c71b2d4e5f6": { "text": "команда", "setAt": "2026-10-12T09:00:00Z" } } }
```

**Верхний уровень.** `lastSeenAt` — heartbeat (PRD C6): писатель обновляет не чаще раза в 600 с; читатель: V5 №5 = `lastSeenAt < now − 30 мин`
(у файлов без поля — `updated`). `accounts` ≤ 8 записей. `unattributedDays` — форма `days` (расход без известной идентичности).
`captions` — `{label: {text ≤ 32, setAt}}`, побеждает поздний `setAt` (RL-2, Should). `machine.name` — санитизированный тег без ПДн (§F.1 п. 1).

**Запись аккаунта.** `product` ∈ {claude, codex} (обяз.); `label` — 16 hex или `null` (+ `labelReason` ∈ {no_login, no_account_uuid, unreadable, no_gist});
`status` ∈ {ok, stale, signed_out, expired, rate_limited, error} (обяз.); `expiredReason` ∈ {cli_refresh_pending, signin_required};
`asOf` — время **успешного** ответа API, отсутствует до первого успеха **этого** аккаунта (C3/C4); `attemptAt` — время последней попытки
(единственное имя поля; `lastAttemptAt` нигде не используется), `attemptKind` ∈ {auto, activity, manual, initial}; `windows.{session,weekly}`
= `{pct 0…100, resetAt}`; `models` ≤ 8 × `{name ≤ 48, pct, resetAt}`; `resetCredits` int 0…1000; `schedule` = `{mode ∈ {auto, fixed},
interval ∈ {900, 1800, 3600, 14400}, nextAt, backoff bool}`; `retryUntil` ISO или `null`; `days` — **всегда** есть (может быть `{}`), форма как в v1,
без уровня продукта. `plan`/`tier` ≤ 64. Лимиты: ≤ 4 КБ метаданных на запись (без `days`), файл ≤ 8 МиБ; > 1 МБ → API усекает → `raw_url` (путь v1).

**Правила.** (1) Корневой `days` = Σ `accounts[*].days` по продукту + `unattributedDays` — проекция для старых читателей (C1). Новый читатель
берёт разбиение по аккаунтам; при расхождении проекции по продукту его корневой расход идёт в «не указан», двойного счёта нет.
(2) Атрибуция дня (A6): индекс хранит `accountByDay[product][day] = localId` при первой индексации строк дня, потом не меняется;
`null` → `unattributedDays`. (3) Запись — §C «Правило записи». (4) Валидация C7: `pct` не число/bool или вне 0…100 → окно отброшено;
непарсимое время → поле отброшено (`asOf` битый → запись без показания); `label` не 16 hex → `null`; неизвестный `status` → `error`;
нет `product`/`status` → запись отброшена; `models` > 8 → хвост отброшен; длинные строки отброшены; `asOf` в будущем > 5 мин → возраст 0,
темп не считать (V6); битый блок не трогает приём `days`. **Пределы читателя** (T1 Т18/Т30, оба порта): ≤ 64 файлов `machine-*.json` на gist, суммарно
≤ 64 МиБ, тело одного ответа ≤ 16 МиБ — чтение прерывается на cap+1 (`raw_url` ≤ 8 МиБ), Linux `_raw`/`common.http` получают предел
тела; числа — `isfinite` (NaN/inf → отброс); управляющие символы (`Cc`/`Cf`) в строке → строка отброшена, включая `machine.name/os/app`. (5) Публикуются только `api_fresh` показания своей машины; чужие записи не
перепубликуются. (6) Совместимость по коду: Linux `sync.merge()` (`sync.py` 355–402) читает только `schema/machine/updated/tz/days`;
macOS `GitHubSync.merge` (2740–2775) — то же через `as?`; манифест не трогаем. Тест: фикстура v1.1 через **старый** merge = та же
фикстура без блока. (7) Протокол v1.1 (`docs/sync-protocol.md`): проход издателя делает до двух PATCH после одного валидирующего GET в
пределах 120 с; смена gist меняет метки (§B).

## B. Метка и локальная идентичность

- **Локальная идентичность `localId`** (никогда не покидает машину): Claude — `~/.claude.json` → `oauthAccount.accountUuid`
  (парсер извлекает только этот ключ; `emailAddress`, `displayName`, `organizationUuid` и прочие ключи объекта в структуры приложения
  не попадают — S3); Codex — `~/.codex/auth.json` → `tokens.account_id` (`id_token` не читается). Перечитывается **каждый проход**
  (`_read_json_retry`, 5×0,2 с): значение изменилось → новая метка; поля нет → `null`; ротация access/refresh без смены `accountUuid`
  метку не меняет (Т4 в редакции Юрки; привязки к поколению входа нет). Не читается → `label: null`, `labelReason: unreadable`, статус `error`, **запроса нет** (B2 без метки
  невозможна; план #1 §B). Файла/блока нет → `no_login` → `signed_out`, 0 запросов. Нет gist id → `no_gist`, опроса нет (P6). Запасной источник `organizationUuid` **снят** (T1 П1-а: метка организации
  общая для всех её членов): нет `accountUuid` → `label: null`, `labelReason: no_account_uuid`, запроса нет. `~/.claude.json` парсится с
  пределом 8 МБ и `RecursionError` (П2-б).
- **Сквозная привязка (T1 П2-в).** `localId` снимается тем же чтением файла входа, что и токен, и едет в `LimitData.account`; если после
  запроса `localId` другой → результат отброшен как `identity_changed`, попытка потрачена; C3-fallback, попытки и `retryUntil` — только
  внутри того же `localId`.
- **Смена значения = смена аккаунта (A6).** Новая корзина истории; записи `cache.json`/`publisher-state.json` старого аккаунта для нового
  не используются (№3): до первого успеха — только статус попытки, без значений и `asOf`. Журнал: `label_changed`.
- **Известное ограничение (№7).** `oauthAccount` — кэш профиля Claude Code; после смены аккаунта он может отставать от действующего
  токена (issue #81231) — метка на время лага прежняя. У владельца один Claude-аккаунт на машину → принято для первой поставки;
  `GET /api/oauth/profile` остаётся Could; состояние `identity_unknown` не вводится.
- **Метка.** `label = hex(HMAC_SHA256(K, "ccl-account-v1|" + product + "|" + localId))[:16]`, `K = SHA256("ccl-label-key-v1|" + gist_id)`.
  Считается **только** при сборке блока и строки журнала под gist id, актуальным в этот момент (№8). Ни одно локальное хранилище меток не
  содержит: `usage-index.json.accountByDay`, `cache.json[p].accountId`, `publisher-state.json[p].accountId`, mac `UsageIndex.accountByDay`
  — все под `localId`. Для стороннего без gist прообраз (UUID v4) неподбираем; держатель содержимого gist и так знает его id (T1).
- **Смена gist** (сход к самому раннему; только при одновременном создании двух gist): метки меняются у каждой машины при её следующей
  сборке после собственного discovery (до 24 ч разброса → временные дубли карточек ≤ 1 суток). Читатели: `hiddenAccounts`,
  `captions`, `menuAccount` ключуются меткой → при исчезновении метки сбрасываются к умолчаниям. Журналы несут метки → при сведении G1
  смена видна по `label_changed`. Задокументировать в протоколе как редкое событие.
- **Подпись по умолчанию** строит читатель: `<Продукт> <план> · <машины>` (тир `max_20x` → «Max 20x»); `captions` — Should.

## C. Headless-издатель на VPS

**Модули.** `linux/ccl/publisher.py` (проход, чистое ядро с инжекцией часов/транспорта), `accounts.py` (идентичность, сборка/разбор/
валидация блока, подписи), `coordination.py` (чистое `decide`), `sync.py` += `open_cycle()`/`write()` (расщепление `_sync_cycle` на
чтение и запись; `accounts=` в файле), `limits.py` += guard §E, `cli.py` += `publisher --enable|--disable|--products|--mode|--now|--status`,
`status` O2, `install.sh --publisher`. PyQt5 не импортируется; нормализация интервала переезжает из `gui/panel` в `polling.py`.

**Проход `publisher.run_pass(kind ∈ {auto, manual})`** (таймер 5 мин; каждый шаг — без человека):
0. `usage.refresh()` (индекс + `activity`); прочитать `localId` обоих продуктов; настройки (`credential_write`, продукты).
1. Нет входа в GitHub/отозван → `poll_skipped no_github` на продукт, выход (0 запросов; ранний выход в `cli.main` остаётся).
2. `file_lock("quota")` (ожидание ≤ 30 с; занято → `pass_skipped busy`, выход).
3. Под замком: перечитать `state.json` (`autoPollState`, `quotaServerRetryAt`) и `publisher-state.json`; применить `local_activity`
   (**только здесь**, №2); `due` по `PollState.due(now, manual)` и `server_until`.
4. `session = sync.open_cycle(auto=True)`: `file_lock("sync")` **блокирующе, ожидание ≤ 60 с** (не пропуск `busy`; истекло → как
   недоступный gist — T1 П8-а/Т27) → доступ → GET gist (`public == false`) → merge чужих в `sync-remote.json` → `clockSkew` из заголовка
   `Date` (§D). Неудача → `session = None` (gist недоступен, P6).
5. По каждому due-продукту решение в порядке: `no_login` → `no_label` → `retry_after` (локальный `server_until` ∪ чужие `retryUntil` моей
   метки) → `token_policy` (§E, 0 запросов) → `coordination.decide` (§D: `remote_attempt` / `fresh_remote` / `tie_break` / `poll`).
6. Если хотя бы один продукт решил `poll`:
   a. **B3:** `begin(now)` → записать `state.json` и `publisher-state.json` (`attemptAt`, `attemptKind`, `attemptPublished: false`);
      `OSError` → `poll_skipped state_unsaved`, запроса нет.
   b. **Объявить попытку (№5):** при `session` — собрать блок с новым `attemptAt` → `sync.write(session, file)` = **PATCH №1** (метаданные,
      пол обходится). Любая неудача (не-2xx, сеть, 404) → журнал `publish failed`, `poll_skipped publish_failed`, в `state.json` вернуть
      прежний `last_attempt`, **запроса нет**; следующий тик повторит. При `session = None` объявления нет — запрос по собственному
      расписанию в рамках B1 (исключение PRD B2, №9), блок уйдёт в первый удачный проход.
   c. Журнал `poll_attempt` → `limits.fetch_claude()` / `fetch_codex(live=True)` (без изменений; guard §E внутри) → `PollState.observe` →
      `apply_provider_cache(product, data, account=localId)` (№3) → журнал `poll_result` → сохранить `state.json` + `publisher-state.json`
      (status, asOf, retryUntil, класс ошибки).
7. Собрать итоговый блок → `sync.write(session, file)`, если запись положена по правилу ниже (**PATCH №2** на due-тике; единственный PATCH
   на остальных). Журнал `publish` (changed/ok/failed, класс).
8. Снять замок. Порядок замков: `quota` → `sync` (`open_cycle`/`write` берут `sync` с ожиданием ≤ 60 с, не пропуском — T1 П8-а). `ccl-sync status` читает под неблокирующим
   `sync` как сегодня. Внутри замка худший случай ≈ 90 с (GET 20 + PATCH 20 + 2 запроса ×15 + PATCH 20), типично < 5 с.

**Правило записи (№11) — три отпечатка в `sync-state.json`:** `pushHash` = sha1(корневой `days`) — расход, пишется при изменении и
`now − pushedAt ≥ 570 с` (пол как сегодня); `metaHash` = sha1(`accounts` без `days` + `captions`) — попытка/результат/расписание/`retryUntil`/
статус/метка/подпись — пишется сразу; `heartbeatAt` — когда последний раз писался `lastSeenAt`, пишется при `now − heartbeatAt ≥ 600 с`.
Любой PATCH пишет весь файл (свежие `days`, `accounts`, `captions`, `lastSeenAt = now`) и обновляет все три. Heartbeat-PATCH меняет в
файле только `lastSeenAt` (не `asOf`, попытку, интервал, наблюдения Auto); самоподдерживающейся записи нет — два не-due тика подряд в
600 с дают 0 PATCH (тест-план A3-14). `lastSeenAt` — часть снимка,
но не часть отпечатков изменения (иначе каждая запись порождала бы следующую); формулировку PRD C6 «входит в хеш» уточнить как «входит
в снимок, пишется по своему 10-мин сроку». Бюджет: due-тик ≤ 1 GET + 2 PATCH; остальные 1 GET + ≤ 1 PATCH.

**`open_cycle()`/`write()`.** Один валидирующий GET на проход обслуживает до двух PATCH в пределах 120 с (протокол v1.1); PATCH 404 →
сброс gist id/хеша как сегодня; `write()` discovery не делает. Расщепление `_sync_cycle` — вместо двух полных циклов плана #1 (риск 3).

**Трей на машине с издателем (P3, №2).** При `settings.publisher = true` трей в режиме `delegated`: `refresh_limits` возвращает
`delegated` для всех продуктов; трей **не пишет** `autoPollState`/`quotaServerRetryAt` (`save_poll_states` — no-op, `on_activity` только
перечитывает; `local_activity` применяет проход); раз в 60 с перечитывает `cache.json`/`state.json`/`publisher-state.json` и показывает
«опрос ведёт издатель · следующая попытка HH:MM»; кнопка «Обновить» → `publisher.run_pass(manual=True)` в рабочем потоке (тот же замок);
свои циклы синка трей гоняет с `allow_push=False` (`gui/app.py:1379`). Старый трей 0.4.5 на `:20` режима не знает → `install.sh --publisher`
проверяет процесс трея пользователя и при живом **отказывает**, печатая команду остановки; перезапуск не делает (T1 П3-б, Т33; решение Юрки). На не-делегированных машинах рабочий поток трея берёт `file_lock("quota")` на время
`fetch + apply` (ожидание ≤ 10 с, иначе `poll_skipped busy`), попутно чинится порядок «сохранить попытку до старта воркера» (`:1226`, `:1305`).

**Таймер** 5 мин (`OnUnitActiveSec=5min`, `OnBootSec=2min`): проверка без due — 0 запросов к провайдерам. **Установка (P2):**
`sh linux/install.sh --publisher [--no-tray] [--name <tag>]` → `settings.json`: `publisher: true, autoPoll: true, credential_write: "never",
machineName: <tag>` (теги владельца `vps` / `macbook` / `thinkpad`; дефолт — санитизированный hostname, у VPS это `ubuntu-s-4vcpu-8` → ставить `--name vps`); `XDG_RUNTIME_DIR=/run/user/$UID`
при отсутствии; без autostart/.desktop при `--no-tray`; `.deb` не трогаем. **P6:** нет входа → 0 запросов; GET не прошёл → своё расписание,
блок хранится локально. **Журнал O1** `publisher.jsonl`: `poll_attempt`, `poll_result`, `poll_skipped` (`not_due · fresh_remote ·
remote_attempt · tie_break · retry_after · no_github · no_login · no_label · state_unsaved · publish_failed · token_policy · busy`),
`token_refresh`, `publish`, `clock_skew` (секунды), `label_changed`, `identity_changed`, `remote_retry_capped`, `policy_forced_never`,
`policy_violation`, `pending_rotation_lost`; только перечислимые строки и числа; файл 0600 через `O_APPEND|O_CREAT` (П6-а); ротация > 1 МБ → старше 45 дней
отбросить. **`ccl-sync status` (O2):** на продукт — подпись, попытка/вид, успех, режим/интервал, следующая попытка, `retryUntil`, класс
ошибки, счётчики 24 ч (запросы, 429, неудачные публикации), `clockSkew`; чужие аккаунты со свежестью.

**Бюджет запросов к GitHub в сутки** (одна учётка GitHub на все машины; лимиты: 5000/ч основной, ≤ 500/ч и ≤ 80/мин
content-generating (PATCH), 900 очков/мин при GET = 1, PATCH = 5 — docs.github.com «Rate limits»):

| Машина · режим | GET | PATCH (верхняя оценка) | Расчёт |
|---|---|---|---|
| VPS · Claude и Codex по 15 мин | 288 (12/ч) | ≤ 528 (≤ 22/ч), при совпадении тиков продуктов 336 | 288 тиков; 2 × 96 due-тиков × ≤ 2 PATCH + heartbeat ≤ 144 (только когда 10 мин без PATCH) |
| VPS · оба по 4 ч | 288 | ≤ 168 (7/ч) | 2 × 6 × 2 + 144 |
| Мак · Codex 15 мин | ≤ 240 (10/ч) | ≤ 336 (14/ч) | 144 циклов + 96 чтений перед опросом; 96 × 2 + 144 |
| Мак · Codex 4 ч | ≤ 150 | ≤ 156 | 144 + 6; 6 × 2 + 144 |
| Сумма VPS + мак + ThinkPad (худший) | ≈ 34/ч | ≈ 50/ч | 1,7 % от 5000/ч; 10 % от 500/ч; пик тика 11 очков ≪ 900/мин |

Рост ответов ограничен: `history` в ответах `GET /gists/{id}`/PATCH — только 30 последних ревизий (замер Юрки 2026-10-12: 56 895 байт
при трёх файлах), риск 1 снят.

## D. Координация B2 между машинами

**`coordination.decide(now, mine, remote, my_id, tie_wait) → poll | skip(reason)`** — чистая; `mine = {label, interval I, last_attempt,
server_until}`, `remote` = записи других машин с той же меткой `{machineId, asOf?, attemptAt?, status, retryUntil?, nextAt?, lastSeenAt}`.
Все запасы 60 с рассчитаны на |skew| ≤ 60 с; время из будущего = возраст 0 (безопасная сторона).
1. `retry_after`: `now < max(server_until, remote_effective)` → пропуск (B6). Чужой дедлайн хранится **отдельно** от своего
   (`remote_retry_until` + `firstSeenAt` на диске, не в `server_until`/`serverRetryAt`): `remote_effective = min(retryUntil,
   firstSeenAt + 24 ч)` (T1 П7); повторные доставки, heartbeat и рестарты `firstSeenAt` не сдвигают; чужие записи с `lastSeenAt` старше
   30 мин в подавлении не участвуют, но уже принятое ограничение действует до `remote_effective`. Чужие `asOf`/`attemptAt`/`nextAt`
   > `now + 60 с` или несогласованные между собой → для B2 запись не свежая (для показа — возраст 0, V6).
2. `remote_attempt` (№5, №10): есть чужая `attemptAt` с `now − attemptAt < 900 + 60` → пропуск (неудачная попытка тоже тратит бюджет).
3. `fresh_remote`: максимальный чужой успешный `asOf` с `now − asOf < I + 60` → пропуск (B2).
4. `tie_break` (№6): чужая `nextAt` в ±60 с от моего срока, `remote.lastSeenAt ≥ now − 900`, `remote.machineId < my_id` и
   `(machineId, nextAt) ≠ tie_wait` → пропуск один раз, запомнить `tie_wait`; иначе → `poll` и очистить `tie_wait`.
5. Иначе `poll`.
**Ручное (решение владельца 1):** `PollState.due(manual=True)` (свои ≥ 900 с) + правила 1–2 (`now − чужой attemptAt ≥ 960`); иначе только
чтение gist (защита 30 с) и «опрос можно с HH:MM» = max(свой `last_attempt` + 900, чужой `attemptAt` + 960, `retryUntil`).
**Auto не кормим чужим (B5):** пропущенная машина не двигает `last_attempt`/интервал, перепроверяет каждый тик; чужие показания не идут в
`observe`; чужие `asOf` — в историю темпа читателя (§F).
**Часы (№10).** `clockSkew = Date(GitHub) − now` по каждому ответу GitHub (`Resp.headers["date"]` на Linux, `r.headers` на маке; RTT ≪ 60 с),
хранится `clockSkew`/`clockSkewAt`; |skew| > 60 с → журнал `clock_skew`, `status` и подсказка карточки «часы расходятся с GitHub на N с —
пол между машинами не гарантирован»; автокоррекции нет (NTP). Гарантия B2 заявляется только при |skew| ≤ 60 с на обеих машинах.
**Окно гонки.** Пара возможна, только если обе машины прошли правила 1–4 внутри «окна решения» друг друга — GET → решение → PATCH попытки
(типично 1–3 с, ≤ 40 с при таймаутах 20 с); после объявления другая сторона видит `attemptAt` при своём следующем GET (≤ 5 мин VPS,
≤ 10 мин мак, либо при чтении перед собственным опросом). Сходимость: в установившемся режиме поздняя машина видит раннюю попытку
(< 960 с) или успех (< I + 60) и молчит, пока ранняя жива; аккаунт опрашивается одной машиной по её Auto; машина ушла → её записи
стареют → вторая подхватывает ≤ 1 тик после I + 60. При выровненных тиках тай-брейк разводит фазы на 5 мин один раз.
**Допуск (№9) — числа в PRD, решение 7 (заменяют «≤ 3 событий/сутки»):**
- установившийся режим, gist доступен обеим, |skew| ≤ 60 с — **0 пар < 900 с**;
- событие сходимости (старт процесса, смена входа, падение Auto до 15 мин, выровненные тики) — **≤ 1 пара на аккаунт на событие**;
- gist недоступен машине (GET не прошёл) — своё расписание в рамках B1, **≤ 1 пара на 15 мин простоя** на аккаунт (обе по 15 мин);
- восстановление (первый удачный GET после простоя) — **≤ 1 пара**;
- замер G1: пары считаются по журналам обеих машин по метке; периоды с неудачными `publish`/GET в любом журнале помечаются «gist
  недоступен» и отчитываются отдельно;
- инварианты T1 И1–И4 в редакции тест-плана A3-20(c)/(d) (Т24/Т32): чужой ввод только откладывает мой опрос и никогда не учащает его
  сверх моего Auto; при мусорных/будущих чужих полях — ≥ 1 запрос за `max(I, 24 ч)`; требования «≥ 1 запрос в сутки при любом чужом
  вводе» нет — здоровый сосед подавляет законно.
**B6.** Свой `Retry-After` хранится полностью (> 24 ч не режется, проверяется на конечность) и публикуется как `retryUntil`; чужой
соблюдается не дольше 24 ч от `firstSeenAt` — затем событие `remote_retry_capped` и своё расписание (сервер при необходимости взведёт уже
**свой** дедлайн без потолка); букву PRD B6 правит PM. Backoff GitHub
(cap 1 ч, `sync.py:495`) к провайдерам не применяется; `quota_refresh.retry_after` без cap — как сегодня.

## E. Политика токенов (S1, S2) — №1

Настройка `credential_write ∈ {never, guarded}`; **`never` — значение по умолчанию на всех портах** (VPS, Linux-трей, мак; T1 П3-д —
решение Юрки, ждёт «да» владельца, планируется как принятое); `guarded` = сегодняшнее поведение Linux — явный opt-in только там, где
CLI на машине не используется (строка в `status`); при `publisher: true` значение `guarded` игнорируется → `never` + событие
`policy_forced_never` (П3-в). **Единое правило (решение Юрки по тест-плану §6 п. 1):** политика читается в начале **каждой** попытки
под `file_lock("quota")` — CLI, издатель и трей одинаково; смена политики — под тем же замком при пустом `_PENDING` и без маркера
ротации (абзац «Смена политики» ниже); процесс в `guarded` при штатном выходе делает одну попытку replay `_PENDING`, иначе
`pending_rotation_lost` (П3-б). Запросы к провайдерам и `/oauth/token` — с `follow_redirects=False` (T1 §5).

| Состояние | Условие (каждая попытка перечитывает файл входа) | Запросы | Публикуется |
|---|---|---|---|
| live | access валиден ≥ 2 мин | usage 1 | `ok`, новый `asOf` |
| expiring (never) | access истёк/< 2 мин, refresh есть (Claude: `refreshTokenExpiresAt > now`; Codex: `exp` JWT прошёл) | 0 | `expired` + `cli_refresh_pending`, прежние значения и `asOf` (C3) |
| dead | Claude `refreshTokenExpiresAt ≤ now`, нет refresh, (guarded) отпечаток в `deadRefresh` | 0 | `expired` + `signin_required` |
| signed_out | файла/блока нет | 0 | `signed_out`, значений нет (C4) |
| read_error | не читается после 5×0,2 с | 0 | `error` (класс credentials), шаг Auto вверх |

**Guard-точки:** (1) перед POST `/v1/oauth/token` (`limits.py` ~219) и `auth.openai.com/oauth/token` (~527); (2) **до** replay `_PENDING`
(~187, ~497), потому что replay сам пишет файл; (3) внутри `_save_claude_tokens`/`_save_codex_tokens`/`_rewrite_json` → `refused`
(глубокая защита). В `never` `_PENDING` не наполняется, `deadRefresh` не трогается; guarded-ветка не меняется.
**Смена политики (№1):** только `ccl-sync publisher --enable|--disable` / `ccl-sync credentials --write never|guarded` →
`common.set_credential_write()` под `file_lock("quota")` (ожидание ≤ 60 с). Замок доказывает, что ни в одном процессе нет попытки (и
ротационного POST) в полёте: **каждый** запрос к провайдеру — под `quota` (проход; воркер трея; CLI). Несохранённая пара в памяти
другого процесса видна через маркер `STATE_DIR/rotation-pending-<product>` (атомарно при установке `_PENDING[product]`, содержимое
`pid + boot-id`, удаляется при `pop`): маркер с живым pid → отказ «ротация входа <продукт> не завершена; повторите после обновления входа
CLI»; мёртвый pid → пара и так потеряна, маркер удаляется, смена проходит. `limits.py` читает политику в начале попытки под тем же замком
→ смена не попадает в середину попытки. Журнал: `token_refresh` только в guarded; на VPS `credentialWrite` = 0 (G2).
**macOS (S2):** ключ defaults `credentialWrite ∈ {never, legacy}`, **по умолчанию `never`** (П3-д): `codexAccessToken()` возвращает
`expired/cli_refresh_pending` вместо refresh (сегодня `LimitsMonitor.swift:527–533` переписывает `auth.json` без перечитывания);
`legacy` — явный opt-in, и в нём запись становится атомарной с перечитыванием/сравнением пары, guard политики — до POST и в функции
записи (П3-а); `persistClaudeQuotaUpdate` при `never` не вызывается. Тексты читателя — UX 3a/3b; `limitCanFix` = false для чужих (урок 012).

## F. macOS — читатель и издатель

**Модель (новый файл `Sources/RemoteLimits.swift`, в `LimitsMonitor.swift` — точки подключения).** `struct RemoteAccount: Codable`
(поля §A + `machineId`, `machineName`, `machineLastSeenAt: Date?` из `lastSeenAt` файла, fallback `updated`); валидатор C7; `mergeV11`
(`accounts` + `unattributedDays` + `captions`, старый `days` через существующий `merge`); `SyncCachedMachine` += `lastSeenAt: Date?`
(optional → старые кэши декодируются); `SyncRemoteCache` += `accounts: [RemoteAccount]?`, `captions`, `unattributedDays`.
`struct ReaderSyncState { phase: SyncPhase; warning: String? }` считается на main из `syncUIState()`/`syncWarning()` до вызова (№12).
`resolveAccounts(local: (LimitData, LimitData), localIds: [String: String], remote: SyncRemoteCache, hidden: Set<String>,
menu: [String: String], sync: ReaderSyncState, now: Date) -> [AccountView]` — чистая: группировка по (product, label), где метка
локального = HMAC(localId) под текущим gist id; V3 (max `asOf`, при равенстве локальный); V5 по таблице; порядок V2; расход без метки →
группа V7 без карточки. `AccountView { product, label?, historyKey, caption, data: LimitData, isLocal, tier?, usageDays, machines }`;
`LimitData.source: RemoteSource?` = `{machineId, machineName, asOf, attemptAt, nextAt, interval, mode, status, retryUntil, lastSeenAt, freshUntil}`.
**V5:** 7 — `sync.phase ∈ {off, revoked, awaitingCode}` → удалённых `AccountView` **нет** (значений нет до первого успешного синка, №14;
объяснение — строка пустого состояния UX §10 и ссылка §9 п. 2; у `revoked` остаётся оранжевый баннер); 6 — `sync.warning != nil`;
5 — `machineLastSeenAt < now − 30 мин`; 3 — `expired`/`signed_out`; 4 — `retryUntil > now`; 2 — `now > freshUntil`; 1 — иначе.
Приоритет 7 > 6 > 5 > 3 > 4 > 2 > 1; `freshUntil = (nextAt ?? asOf + interval) + 20 мин`; `snapshotHorizon` — F.1 п. 2.
**История темпа (№13).** `UsageSample` += `acct` (ключ истории): локальный — `"l:" + sha256(product + "|" + localId)[:16]` (локальный
отпечаток, не покидает машину, переживает смену gist), чужой — метка. `record(d, product:, acct:)` — локальные (guard локального опроса
как сегодня); `recordRemote(product:, label:, sample)` из `mergeV11` **без** `productEnabled`, дедуп по `(acct, t)`; `samples`/`recentRate`
по `(product, acct)`; строка файла получает поле `a`, старые строки без `a` → `acct = "l:legacy"` (уходят по сроку хранения).
**Издатель мака (P5) и B2 (№4).** `machineFile` += блок Codex из `last.1` + `autoStates["codex"]` + `quotaStates` дедлайн + `localId` из
`~/.codex/auth.json` + `accountByDay`; `cache.json[p].accountId` в `cacheQuotaCompletion` (№3). `GitHubSync.syncNow(force:, mode: .full |
.writeOnly, completion: ((SyncOutcome) -> Void)?)`; `SyncOutcome = .read(generation: UInt64, cache: SyncRemoteCache) | .failed(reason) |
.skipped(reason)`, доставляется на main из `syncBody` единым `defer` (каждый ранний `return` даёт `.failed`); `.writeOnly` — PATCH без GET
против gist, валидированного чтением ≤ 120 с назад; `onChange` — только UI. `doRefresh(codex)`, когда мою метку публикует другая машина:
допуск → `syncNow(completion)` → `coordination.decide` по кэшу из исхода (не по `_remote`) → `poll`: `begin` + `saveAutoStates` →
`syncNow(force: true, mode: .writeOnly, completion)` = PATCH попытки → неудача → `publish_failed`, вернуть `lastAttempt`, запроса нет →
успех → `fetchCodex` → `syncNow(force: true, mode: .writeOnly)` результата. `.failed` чтения → своё расписание (B1); нет completion за
60 с (очередь занята) → как `.failed`. Журнал O1: `~/.claude-limits-monitor/poll-log.jsonl` + событие `reader_card_state` (PRD §5: метка, состояние V5, возраст показания по
каждому видимому аккаунту, без ПДн) при каждом успешном синке и рендере — под замер G3/G4 (C2/C3); Linux-читатель — вторая очередь.
`clockSkew` из `Date` — как на Linux.
**Настройки, деньги, UI** — как план #1 §F: `monitor_*` = «опрашивать на этом Маке», `hiddenAccounts`, `mergedUsageIndex` по
`hiddenAccounts` (U2), аудит `productEnabled` (оставить в `fetchClaude`/`fetchCodex`/`UsageLogs.scan`/`snapshotJSON`/`record` — урок 013),
селфтест ~7108 → «remote usage of a visible account survives a disabled local poll», `subscriptionUSD(tier:)`, `menuAccount` (V8),
4 точки рисования (подпись, строка источника, `limitCanFix`, свежесть), PNG-превью 7 состояний; `captions`/список N1 — C5.

### F.1 Решения по UX-спеке
1. **Тег машины без ПДн** — `machineName` (mac: новый ключ defaults; Linux: `settings.machineName`; теги владельца `vps`/`macbook`/
   `thinkpad`), иначе санитизированный hostname (первая DNS-метка); NFKD → ASCII,
   нижний регистр, `[a-z0-9-]`, ≤ 16; пусто → `mac`/`linux`; тест «MacBook Pro — Алекс» → `macbook-pro`; скан S3 на имя владельца.
2. **Горизонт свежести** `snapshotHorizon(d)` = `source != nil ? max(0, freshUntil − asOf) : SNAPSHOT_MAX_AGE`, три точки (`metricIsStale`
   ~3097, `advVerdict` ~4254, `isStale`); тест Auto 4 ч / 3 ч 50 мин → не stale.
3. **Клик по чужой карточке** — `limitCanFix(remote:)` = false, hit всегда `open:<url>`; тест: `expired` с VPS → нет `claudefix`.
4. **Плашка плана** — `AdvCard.tier` из `AccountView`; общий `planLabel`; локальный `claudeTier` к чужому не применяется ($100 у `max_5x`).
5. **Состояние 7 (№14).** Кэш снимков — в `sync-remote.json` под привязкой `authEpoch/authUserID`; `off`/`revoked` → удалённые карточки не
   показываются и значений нет; после входа карточки появляются **после первого успешного синка** (новый epoch удаляет кэш —
   `LimitsMonitor.swift:2230–2235`, это штатно); непривязанного кэша нет (межаккаунтная утечка). Править UX: строка 7 таблицы §4
   («показаны данные из кэша» снять) и последнее предложение §12.

## G. Порядок сборки (по зависимостям; тесты офлайн, без реальных учёток/API — уроки 006/011)

**Срез A — сервер (проверяется журналом VPS).**
1. **A1 контракт + идентичность.** `accounts.py` (чтение `localId` с извлечением одного ключа, метка, блок, подписи, `unattributedDays`),
   `usage.py` `accountByDay`, `common.machine_tag()`, `docs/sync-protocol.md` v1.1, фикстуры `machine-v11.json` / `-hostile` / `-v10`.
   Тесты: детерминизм метки (один id → одна метка; два gist id → разные; та же локальная история переименовывается); проекция `days` и
   расхождение → «не указан»; **старый** `sync.merge()` на v1.1 = без блока; C7 hostile; скан S3 (email, `account_id`, `accountUuid`,
   `refresh`, `access_token`, `sk-`, `/home/`, `/Users/`); фикстура `~/.claude.json` с ПДн-ключами → в структурах только `accountUuid`.
2. **A2 политика токенов.** Три guard-точки, `never` по умолчанию, маркер ротации, `set_credential_write()` под `quota`,
   `policy_forced_never`, `LimitData.account` из того же чтения (П2-в), `follow_redirects=False` к провайдерам (T1 §5). Тесты: синтетические
   файлы входа (live/expiring/dead/absent/partial) при `common.http = no_network` → 0 запросов, верные статусы; guarded-регресс; отказ смены
   при маркере с живым pid, разрешение при мёртвом; политика читается под замком.
3. **A3 ядро издателя + координация** (B1 плана #1 входит сюда: проход без `decide` невозможен). `sync.open_cycle()/write()`, три
   отпечатка, `publisher.run_pass`, `coordination.decide`, `clockSkew`, журнал, `ccl-sync publisher`, хук в `cmd_push`,
   `identity_changed` (П2-в), чужой дедлайн отдельно с потолком 24 ч от `firstSeenAt` (П7), пределы читателя Linux — `isfinite`, `raw_url`
   ≤ 8 МиБ через `read(cap+1)`, ≤ 64 файлов / ≤ 64 МиБ / тело ≤ 16 МиБ, чистка `machine.*` (П5 в–е), ожидание `sync` ≤ 60 с (П8-а). Тесты (фикс. часы,
   `FakeGitHub` считает GET/PATCH и умеет ронять PATCH, фейковые провайдеры): порядок транспорта — PATCH с `attemptAt` **раньше** запроса к
   провайдеру; `publish_failed` → 0 запросов и `last_attempt` восстановлен; gist недоступен → запрос есть, блок уходит следующим проходом;
   B3 `OSError` → 0 запросов; due/not_due через перезапуск и «перезагрузку»; Retry-After > 24 ч сохранён; правило записи (расход < 570 с →
   нет PATCH; метаданные → PATCH; heartbeat на 600 с; due-тик ≤ 2 PATCH); `decide`: чужая попытка 959 с → пропуск, 961 с → опрос,
   `fresh_remote`, `retry_after`, тай-брейк ждёт один раз и опрашивает при неизменной записи, мёртвый источник → без тай-брейка;
   skew > 60 → `clock_skew`; симулятор двух машин 24 ч при 15 мин и 4 ч → 0 пар в установившемся, ≤ 1 на событие, GET/PATCH в пределах
   таблицы §C; скан журнала на секреты.
4. **A4 установка и статус.** `--publisher/--no-tray/--name`, таймер 5 мин, `XDG_RUNTIME_DIR` (только при существующем каталоге), без
   `.desktop` при `--no-tray` (П6-в), отказ при живом старом трее (П3-б), политика и путь state-каталога в `status` (П3-в, П8-б), `status` O2. Тест:
   install.sh во временном `HOME` с подменным `systemctl`; `test_deb` зелёный.
5. **A5 выкатка на VPS.** Владелец: `ccl-sync login`; проверка риска 1 (`history` ≤ 30 записей, ответ `GET /gists/{id}` ≤ 100 КБ);
   ручные сверки Юрки по T1 §7 (`stat` файлов входа до/после суток, файл в gist глазами, journald без токена/email); 24 ч журнала → G1 (≥ 900 с, ≤ 10/сутки при простое), G2 (`credentialWrite` = 0), старые читатели суммируют расход.

**Срез B — трей Linux.**
6. **B1 трей `delegated` (№2)** + воркер под `quota` на не-делегированных машинах + порядок «сохранить до воркера». Тесты в стиле
   `test_auto_ui`: 2 ч трей + таймер → ≤ 1 запрос/15 мин; `on_activity` в `delegated` не меняет `state.json` (mtime); циклы синка без PATCH.
7. **B2 Linux-трей publish-only** (вторая очередь, тот же `accounts.build`).

**Срез C — мак (сборка через remote-hands, установка — владелец).**
8. **C1 merge v1.1 + резолвер** (+ `ReaderSyncState`, `lastSeenAt`, V5 с инжекцией `now`, в т. ч. 5/6/7; старый/новый файл → те же `days`;
   hostile; один Codex на двух машинах → одна карточка; два → две; пределы читателя, константный URL клика, чистка строк — T1 П5 а/г/д/е, Т36).
9. **C2 настройки, деньги, история (№13):** история по `acct`; выключенный локальный опрос Claude + чужие `asOf` → темп считается;
   селфтест 7108 переписан; `subscriptionUSD(tier)`; U2.
10. **C3 UI:** подписи, строка источника, тексты V5, `limitCanFix(remote:)`, `snapshotHorizon`, плашка, строка меню; состояние 7 без
    карточек; PNG-превью; сверка Юркой в реальном приложении.
11. **C4 издатель мака + B2 (№4):** `syncNow(mode:completion:)`, `.writeOnly`, попытка до запроса (селфтест с транспорт-ловушкой: PATCH
    с `attemptAt` зафиксирован **до** вызова `fetchCodex`; упавший PATCH → `fetchCodex` не вызван), `cache.json.accountId`, ключ
    `credentialWrite` (`never` по умолчанию; guard до POST и в функции записи, атомарная запись в `legacy` — П3-а), чужой дедлайн с
    потолком 24 ч (П7), `poll-log.jsonl`, `clockSkew`.
12. **C5 подписи и список N1** (Should). 13. **C6 релиз:** документация, changelog, T3, 14-дневный замер G1–G4 по журналам обеих машин.

## Компоненты

| Компонент | Ответственность | Зависит от | Тест |
|---|---|---|---|
| `linux/ccl/accounts.py` | `localId` (один ключ), метка под gist id, блок `accounts`/`unattributedDays`/`captions`, подпись | `common`, `usage` | pure, фикстуры, скан S3 |
| `linux/ccl/publisher.py` | проход: due → open_cycle → decide → B3 → PATCH попытки → fetch → observe → cache → PATCH результата → журнал | `polling`, `limits`, `sync`, `accounts`, `coordination` | фикс. часы, `FakeGitHub`, фейковые файлы входа, порядок транспорта |
| `linux/ccl/coordination.py` | чистое `decide` (retry_after / remote_attempt / fresh_remote / tie_break), окно ручного | — | симулятор двух машин, граничные 959/961 с |
| `linux/ccl/sync.py` (+`open_cycle`/`write`, `accounts=`) | один GET → до двух PATCH, три отпечатка, `clockSkew`, разбор чужих блоков в `sync-remote.json` | `accounts` | `test_sync_merge` расширить, `FakeGitHub` |
| `linux/ccl/limits.py` (+guard, `account=`) | политика `credential_write` в трёх точках, маркер ротации, кэш под `accountId` | `common.settings` | синтетические файлы, `no_network`, маркер/pid |
| `linux/ccl/usage.py` (+`accountByDay`) | владелец дня при первой индексации | `accounts` | смена входа внутри дня → две корзины |
| `linux/ccl/cli.py`, `install.sh` | `publisher`/`credentials` подкоманды, `--publisher/--no-tray/--name`, таймер 5 мин, `status` O2 | `publisher` | install в tmp HOME, CLI-тесты |
| `linux/ccl/gui/app.py` (`delegated`) | трей без записей состояния, перечитывание, кнопка → проход, воркер под `quota` | `publisher` | `test_auto_ui`-стиль, mtime `state.json` |
| Swift `RemoteLimits.swift` | `RemoteAccount`, C7, `mergeV11`, `ReaderSyncState`, `resolveAccounts` V1–V7 | `SyncRemoteCache` | селфтест с `now`, фикстуры |
| Swift `GitHubSync` (+`syncNow(mode:completion:)`) | исход цикла, `.writeOnly`, блок Codex, `clockSkew` | `GitHubAuth` | транспорт-ловушка, порядок PATCH→fetch |
| Swift `UsageHistory` (+`acct`) | история по аккаунту, приём чужих `asOf` | резолвер | pace при выключенном локальном опросе |
| Swift settings/money/draw/menu | N1–N3, U2–U3, подпись, источник, V5, `canFix`, плашка, V8, состояние 7 | резолвер | селфтест 7108 (переписан), PNG + сверка |
| `machineTag()` (оба порта) | тег без ПДн | settings/hostName | санитизация, скан имени владельца |

## Риски и альтернативы

1. **Рост gist с каждой ревизией — закрыт замером (Юрка, 2026-10-12).** `GET /gists/{id}` владельческого gist (создан 2026-09-27,
   ≥ 144 PATCH/сутки) вернул `history` ровно из 30 последних ревизий (12:39Z…17:21Z), ответ 56 895 байт при файлах 8958 + 7285 + 136:
   GitHub отдаёт только 30 записей, рост ограничен ≈ 30 × 1,2 КБ. Транспорт v1 не меняем; в A5 — проверка «`history` ≤ 30, ответ ≤ 100 КБ».
   Запасная мера, если проверка когда-нибудь не пройдёт: чтение через `GET /gists` + `raw_url` (SHA ревизии как детектор) или ротация gist.
2. `~/.claude.json` недокументирован, `oauthAccount` может лагать/переехать → `label: null` или прежняя метка на время лага; Could — профиль
   1/сутки в бюджете B1.
3. Ключ из gist id vs секрет в манифесте — на T1; замена дешёвая (`accounts.label(id, key)` не меняется).
4. Два PATCH после одного GET в пределах 120 с: gist мог стать публичным/исчезнуть между ними — 404 обрабатывается, переключение в
   публичный внутри окна — тот же класс, что сегодняшний зазор GET→PATCH.
5. `LimitsMonitor.swift`: `source` касается нескольких draw-функций; только аддитивные правки, PNG-превью и сверка Юркой обязательны.
6. Расхождение часов > 60 с → гарантия не заявляется, видно в status/журнале; лечится NTP на VPS и маке.
7. Тай-брейк добавляет ≤ 5 мин задержки один раз на выравнивание тиков; при смерти младшего id вторая машина опрашивает через тик.
8. Маркер ротации с мёртвым pid после падения процесса — пара уже потеряна, смена политики разрешена; задокументировать в T1.
9. Старый трей 0.4.5 на `:20` не знает `delegated` → до включения издателя его нужно перезапустить (A4 делает это сам).
10. Атрибуция дня «первая индексация» приблизительна (PRD A6 принято); смена входа внутри дня даёт две корзины только по дням.
11. Замер G1 при смене gist в окне 14 дней: метки меняются — сводить через `label_changed`.
12. `credential_write: never` по умолчанию замораживает показания, пока CLI на машине не обновит вход (мак Codex, Linux-трей) — следствие
    решения 5 и T1 П3-д; «да» владельца ожидается, планируется как принятое.

## Что нужно подтвердить / вопросы владельцу

1. **PM → PRD:** решение 7 — заменить «≤ 3 событий/сутки» числами §D «Допуск»; B6 — чужой `retryUntil` соблюдается ≤ 24 ч от
   `firstSeenAt`, свой без потолка (T1 П7); C6 — «`lastSeenAt` входит в снимок, пишется по своему 10-мин сроку»; A5 — нет метки
   (`no_account_uuid`/`unreadable`/`no_gist`) → запроса нет. **UX:** строка 7 §4 и §12 — состояние 7 без значений (F.1 п. 5).
2. **Владелец:** «да» на `credential_write: never` по умолчанию на всех портах (T1 П3-д); планируется как принятое.
3. **Владелец (T1):** П4-б — пересоздать gist после выкатки (имя владельца в истории ревизий старого; метки сменятся у всех машин);
   П6-б — `chmod 700 ~/.codex` на VPS.
4. **T1 → исполнение:** П2-в, П3-а/б/в/д, П4-а, П5 а–е, П7, §5 разнесены по вехам в `docs/plans.md`; test-plan — Tester
   (`docs/test-plan-remote-limits.md`, Т1–Т36).

## Артефакты

- `/home/yurka/VibeCoding2/2026_06_UsageLimits/arch/plan-synth.md` (этот файл, v2) · `/home/yurka/VibeCoding2/2026_06_UsageLimits/arch/plan-synth-v1.md` (прежний синтез).
