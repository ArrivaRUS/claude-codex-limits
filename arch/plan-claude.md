# REMOTE-LIMITS — план архитектора #1 (Claude)

Дата: 2026-10-12. База: PRD `docs/prd-remote-limits.md` (G1 принят), контракт `docs/sync-protocol.md` v1, macOS 3.2.7, Linux 0.4.5.
Решения владельца 1–7 из брифа считаются принятыми и здесь не обсуждаются.

## Итог

Один новый блок `accounts` в существующем `machine-<id>.json` (schema остаётся 1), метка аккаунта = HMAC от локального
UUID аккаунта с ключом, выведенным из id gist. На VPS — модуль `publisher.py`, который внутри штатного прохода
`ccl-sync push --auto` (таймер 5 мин) опрашивает по неизменному `PollState`, никогда не пишет в файлы входа, и
публикует снимок в тот же PATCH, что и расход. Координация B2 — «свежее чужое показание → пропуск» с чтением gist
перед опросом и публикацией сразу после. На маке — чистый «резолвер аккаунтов» поверх `SyncRemoteCache`, который
кормит существующие два слота `claude`/`codex`; `LimitData` получает одно поле `source`.

## Прямые ответы на вопросы PRD §7 (архитектуре)

| Вопрос | Ответ |
|---|---|
| Форма расширения (C1) | Ключ `accounts` (и `captions`) в `machine-<id>.json`; `schema: 1`; старые читатели игнорируют (§A) |
| Метка (A1/A2/A4) | Claude: `~/.claude.json → oauthAccount.accountUuid`; Codex: `~/.codex/auth.json → tokens.account_id`; HMAC-SHA256, ключ из gist id; запросов «кто я» нет (§B) |
| Координация B2 и допуск | Пропуск при чужом `asOf` моложе `I_мой + 60 с`, чтение gist перед опросом, публикация сразу после; допуск ≤ 1 близкой пары на событие сходимости (§D) |
| Политика токенов S1 | `credential_write: never` на машине-издателе (VPS): при истёкшем access — 0 запросов, статус `expired` с причиной (§E) |
| Кто опрашивает при трее+издателе (P3) | Только «проход издателя» (один код, любой процесс) под `file_lock("quota")`; трей на такой машине сам не опрашивает (§C) |
| Период проверки B7 | 5 мин (§C) |
| Атрибуция расхода при смене входа (A6) | День получает метку, активную при первой индексации его строк («первая побеждает»); в gist — раздельные `days` у записей аккаунтов только при ≥ 2 метках продукта (§A) |

## A. Контракт gist v1.1

**Форма.** Файл `machine-<id>.json` остаётся целым идемпотентным снимком; добавляются необязательные верхнеуровневые
ключи. `days` остаётся суммой по продукту для старых читателей (C1/C5).

```json
{ "schema": 1, "machine": {…}, "updated": "…Z", "tz": "…", "days": {…},
  "accounts": [
    { "product": "claude", "label": "3f9a0c71b2d4e5f6", "plan": "max", "tier": "default_claude_max_20x",
      "status": "ok", "expiredReason": null,
      "asOf": "2026-10-12T10:15:00Z", "attemptAt": "2026-10-12T10:15:00Z", "attemptKind": "auto",
      "windows": { "session": {"pct": 42.5, "resetAt": "2026-10-12T13:00:00Z"},
                   "weekly":  {"pct": 61.0, "resetAt": "2026-10-15T07:00:00Z"} },
      "models": [ {"name": "Fable 5.1", "pct": 70.2, "resetAt": "2026-10-15T07:00:00Z"} ],
      "schedule": { "mode": "auto", "interval": 900, "nextAt": "2026-10-12T10:30:00Z", "backoff": false },
      "retryUntil": null },
    { "product": "codex", "label": "a1b2c3d4e5f60718", "plan": "pro", "status": "ok", "asOf": "…Z",
      "windows": {…}, "resetCredits": 2, "schedule": {…},
      "days": { "2026-10-10": { "gpt-6-astra": {"input": 1, "output": 1, "cacheRead": 0, "cacheWrite5m": 0, "cacheWrite1h": 0, "turns": 1} } } }
  ],
  "captions": { "3f9a0c71b2d4e5f6": { "text": "команда", "setAt": "2026-10-12T09:00:00Z" } } }
```

Поля записи: `product` ∈ {claude, codex} (обяз.); `label` — 16 hex или `null` (+ `labelReason` ∈ {no_login, unreadable,
no_gist}); `status` ∈ {ok, stale, signed_out, expired, rate_limited, error} (обяз.); `expiredReason` ∈
{cli_refresh_pending, signin_required}; `asOf` — время **успешного** ответа API (отсутствует, если успеха не было);
`attemptAt`/`attemptKind` ∈ {auto, activity, manual, initial}; `windows.{session,weekly}.pct` число 0…100,
`resetAt` ISO UTC; `models` ≤ 8, `name` ≤ 48 символов; `resetCredits` int 0…1000; `schedule.mode` ∈ {auto, fixed},
`interval` ∈ {900,1800,3600,14400}, `nextAt`, `backoff` bool; `retryUntil` ISO или отсутствует; `days` — как в v1, без
уровня продукта. Строки `plan`/`tier` ≤ 64. Лимит: ≤ 8 записей, ≤ 4 КБ на запись без `days`.
`machine.name` в v1.1 — санитизированный тег машины без личных имён (§F.1 п. 1).

**Правило `days` в записи (A6).** Продукт с одной записью → запись без `days`, владеет всем `days[product]` файла.
Продукт с ≥ 2 записями (смена входа за 45 дней) → у каждой записи свой `days`, верхний уровень — их сумма.
Продукт, у которого есть `days`, но нет записи, или файл без `accounts` → группа «аккаунт не указан» (A5/V7).
Две записи одного продукта без `days` → блок `accounts` файла отбрасывается, расход файла идёт в «не указан».

**Совместимость (доказательство по коду).** Linux `sync.merge()` (`sync.py` 355–402) читает только `schema`,
`machine`, `updated`, `tz`, `days`; `cli.cmd_status` — `machine`, `updated`. macOS `GitHubSync.merge` (2740–2775)
достаёт `schema`, `machine`, `updated`, `days` через `as?`-касты; `SyncRemoteCache` не меняется. Неизвестные
ключи обе стороны игнорируют; `schema` не растёт. Манифест `ccl-sync.json` не трогаем (его содержимое ни один
порт не парсит — `_find_gist` и `findGist` проверяют лишь наличие файла). Тест: одна фикстура `machine-v11.json`
в `linux/tests/fixtures/` и в Swift-селфтесте → сумма `days` идентична той же фикстуре без `accounts`.

**Запись (C6).** Хеш снимка = sha1(`days` + `accounts` + `captions`). Пол «раз в 10 мин» в auto-режиме действует
только когда блок `accounts` не изменился; новый `asOf`/`status`/`schedule`/`retryUntil`/подпись → PATCH сразу
(нужно для B2). Локальный опрос продукта выключен → записи нет (C4), как сегодня нет и его `days`.
Публикуются только показания `api_fresh`; офлайн-чтение rollout Codex в gist не идёт (asOf был бы не API).

**Валидация у читателя (C7).** `pct` не число/bool или вне 0…100 → окно отброшено; `resetAt`/`asOf` не парсится
→ поле отброшено (`asOf` битый → запись считается без показания); `label` не 16 hex → `null`; неизвестный `status`
→ `error`; запись без `product`/`status` → отброшена; `models` > 8 → хвост отброшен; строка длиннее лимита →
отброшена; `asOf` в будущем > 5 мин → возраст 0, темп не считать (V6). Битый блок `accounts` не влияет на
приём `days` того же файла. Всё выводится как текст.

## B. Метка аккаунта

- **Источник (только локальные файлы, чтение).** Claude: `~/.claude.json` → `oauthAccount.accountUuid` (UUID v4,
  пишет сам Claude Code при входе; проверено на VPS 2026-10-12: поле есть; запасной — `organizationUuid`). Codex:
  `~/.codex/auth.json` → `tokens.account_id` (UUID; это же значение CLI шлёт в `chatgpt-account-id`). `id_token`
  (JWT с email) **не используется**. Запрос `GET /api/oauth/profile` не нужен — остаётся документированным Could.
- **Псевдонимизация.** `label = hex(HMAC_SHA256(K, "ccl-account-v1|" + product + "|" + id))[:16]`,
  `K = SHA256("ccl-label-key-v1|" + gist_id)`. Gist id уже известен каждой машине набора (`gistId` в состоянии/defaults),
  совпадает на всех, не требует новой записи и гонки «кто создал ключ». Для стороннего без доступа к gist прообраз
  (UUID, 122 бита) неподбираем с ключом или без; для держателя содержимого gist ключ в манифесте и ключ из id
  эквивалентны (id — часть URL, по которому он содержимое и получил). Ротации нет: смена gist (сход к самому
  раннему) меняет метки у всех машин одновременно, возможен один цикл расхождения. Альтернатива для SecurityAnalyst:
  случайный `labelKey` в манифесте (+ PATCH манифеста и правило «ранний побеждает»).
- **Нет gist id** (первый цикл до discovery) → `label: null`, `labelReason: no_gist`, опроса нет (сходится с P6).
  Файла нет/не читается → `null` + причина, статус `signed_out`/`error`, 0 запросов.
- **Смена входа (A6).** Индекс расхода получает `labels[product][day] = label` при первой индексации строк дня;
  потом не меняется. Снимок машины строит записи по §A. Фикстура: индекс с двумя метками → две записи с `days`.
- **Подпись по умолчанию** строит читатель: `<Продукт> <план> · <машины>` («Claude Max 20x · vps»; план из `tier`:
  `max_20x`→«Max 20x», `max_5x`→«Max 5x», иначе `plan` с заглавной). Своя подпись (RL-2, Should) — `captions`,
  побеждает поздний `setAt`.

## C. Headless-издатель на VPS

- **Где живёт.** Новый модуль `linux/ccl/publisher.py` (чистое ядро с инжекцией часов/транспорта + тонкий I/O) и
  `linux/ccl/accounts.py` (метки, сборка/разбор/валидация блока — общий код для издателя, трея и `status`).
  Вход: `cli.cmd_push` вызывает `publisher.run_pass()` вместо прямого `sync_cycle`, когда `settings.publisher` истинно
  (и в `push --auto`, и в `push`). Новая подкоманда `ccl-sync publisher --enable|--disable | --products claude,codex |
  --mode auto|15|30|60|240 | --now | --status` (P7). PyQt5 не импортируется; нормализация интервала переезжает из
  `gui/panel.poll_interval` в `polling.py`.
- **Проход** (шаги 3–6 под `file_lock("quota")`; `file_lock("sync")` внутри `sync_cycle` как сегодня):
  1. `usage.refresh()` — индекс и `activity` (как сейчас).
  2. Нет входа в GitHub/отозван → `poll_skipped no_github` на каждый продукт, 0 запросов, выход (P6; ранний выход
     в `cli.main` остаётся).
  3. Загрузить `autoPollState`/`quotaServerRetryAt` из `state.json` **внутри замка**; применить `local_activity`;
     `due` по `PollState` (fixed/auto по `settings.autoPoll`/`interval`, у издателя по умолчанию `autoPoll: true`, P4).
  4. Если что-то `due` → `sync_cycle(days, accounts=prev_block, auto=True)` (чтение gist и обычная запись расхода)
     — свежий вид чужих показаний для B2. Если ничего не `due` → тот же один цикл, конец.
  5. По каждому due-продукту решение в порядке: `no_login` → `retry_after` (локальный `server_until` или чужой
     `retryUntil` той же метки) → `token_policy` (§E) → `fresh_remote` (§D) → **B3:** `begin(now)` +
     `state().update(autoPollState=…)`; `OSError` → `poll_skipped state_unsaved`, запроса нет → журнал `poll_attempt`
     → `limits.fetch_claude()` / `fetch_codex(live=True)` (без изменений) → `observe` → `apply_provider_cache` →
     `poll_result` → сохранить состояние и `publisher-state.json` (status, attemptAt, kind, retryUntil, label, причина).
  6. Собрать блок (`cache.json` + `publisher-state.json` + `PollState` + метки) → `sync_cycle(days, accounts=block)`:
     PATCH сразу, если блок изменился (пол 10 мин обходится, §A). Итого ≤ 2 GET + 1 PATCH на due-тик, 1 GET иначе.
- **Общее состояние с треем (P3).** На машине с `settings.publisher = true` трей **не допускает** собственных опросов
  (новый вид допуска `delegated` в `refresh_limits`), раз в 60 с перечитывает `cache.json`/`state.json` и показывает
  «опрос ведёт издатель · следующая попытка HH:MM»; кнопка «Обновить» запускает `publisher.run_pass(manual=True)`
  в рабочем потоке. Опрашивает один код (проход), любой процесс; `file_lock("quota")` сериализует таймер и трей, а
  `PollState` читается с диска внутри замка, поэтому второй видит `not_due`. Попутно чинится порядок в трее:
  сохранить попытку **до** старта воркера (B3; сейчас `save_poll_states()` идёт после `Thread.start`).
- **Таймер (B7) — 5 мин.** При тике 10 мин и попытке на тике шаг «15 мин» всегда даёт 20 мин (тики 0/10/20), а
  вид чужих показаний для B2 стареет до 10 мин; 5 мин убирает первое и вдвое режет второе. Цена: +1 GET gist
  на 10 мин (≤ 12/ч при лимите 5000/ч) и ~0,1 с CPU; записи по-прежнему ≤ 1 на опрос + расход раз в 10 мин.
  `OnBootSec=2min` и сохранённый `last_attempt` → внепланового опроса после перезагрузки нет.
- **Установка (P2).** `sh linux/install.sh --publisher [--no-tray]`: копия, таймер `OnUnitActiveSec=5min`,
  `settings.json`: `publisher: true, autoPoll: true, credential_write: "never"`; без autostart и .desktop при
  `--no-tray`; подсказка `ccl-sync login` → `ccl-sync publisher --status`. На этом VPS из не-login shell
  `systemctl --user` не видит шину («Failed to connect to user scope bus») — install.sh экспортирует
  `XDG_RUNTIME_DIR=/run/user/$UID`, если не задан. `.deb` в этом срезе не трогаем.
- **P6.** Временный сбой GitHub (сеть/5xx/backoff) → опрос по расписанию, блок лежит в `publisher-state.json` и
  уходит в первый удачный цикл; B2 без свежего gist → собственное расписание в рамках B1 (исключение PRD).
- **Журнал O1.** `~/.local/state/claude-codex-limits/publisher.jsonl`, строка = событие
  `{"t","ev","product","label","reason|class","interval","retryUntil","credentialWrite"}`; ротация на проходе: при
  > 1 МБ отбросить строки старше 45 дней (атомарная перезапись). Только перечислимые строки и числа, никаких тел,
  заголовков, путей, текстов исключений (S5, тест-скан).
- **`ccl-sync status` (O2).** По локальному продукту: подпись, попытка/вид, успех (`asOf`), режим/интервал, следующая
  попытка, `retryUntil`, класс ошибки, счётчики 24 ч из журнала; чужие аккаунты из `sync-remote.json` со свежестью.
  Диск полон → состояние не сохранить → опроса нет, причина в journald юнита (`journalctl --user -u ccl-sync`).

## D. Координация B2 между машинами

- **Правило пропуска** (машина с локальным входом в аккаунт L): `remote_fresh = max asOf` по записям других машин
  с меткой L и `status ok`; свой опрос пропускается, если `now − remote_fresh < I_мой + 60 с`
  (60 с — защита от расхождения часов; обе машины по NTP; чужой `asOf` в будущем = возраст 0 → пропуск).
  Также пропуск, если `now < max(retryUntil)` по той же метке (B6).
- **Окно гонки сжато до секунд:** чтение gist перед опросом (§C шаг 4; на маке — `syncNow()` с продолжением
  после завершения) и PATCH сразу после опроса (§A). Остаток — один round-trip GET/PATCH (< 10 с).
- **Тай-брейк** при одновременной готовности: если чужая запись показывает `schedule.nextAt` в пределах ±60 с от
  моего срока и чужой `machine.id < мой`, жду один тик.
- **Auto не кормим чужими показаниями (B5).** Пропущенная машина не двигает `last_attempt` и интервал; на каждом
  тике перепроверяет; когда чужое показание старше `I_мой`, опрашивает сама. Следствие: аккаунт опрашивается с
  частотой самой активной машины — ровно «не чаще одной машины по её Auto».
- **Сходимость.** Две машины с равными интервалами и сдвигом фаз δ: после первого пересечения опрашивает та, чья
  фаза позже; другая видит свежее показание и молчит. Разные интервалы: короткий побеждает. Машина ушла в офлайн →
  её файл стареет, показания стареют → вторая подхватывает через ≤ 1 тик после `I`.
- **Допуск переходного режима (числа для утверждения):** в установившемся режиме — 0 пар < 900 с. На событие
  сходимости (старт процесса, смена входа, падение интервала до 15 мин из-за активности, недоступный gist,
  возврат машины в сеть) — **≤ 1 пара < 900 с на аккаунт**, причём с чтением-перед-опросом она возможна только
  при решении обеих машин в одном окне ≈ 10 с; ожидаемо < 1 пары в неделю. Верхняя оценка: ≤ 3 события/день →
  ≤ 3 пар/аккаунт/день. Недоступный gist: собственное расписание (B1), пары между машинами возможны не чаще
  1 на 15 мин простоя gist. Замер G1: пары считаются по журналам обеих машин, с пометкой события сходимости.
- **Ручное (решение 1).** Для аккаунта с локальным входом: допуск только если `max(локальный last_attempt,
  чужой asOf) + 900 ≤ now`; иначе уведомление «VPS обновил в HH:MM · следующее через N мин» и внеочередное чтение
  gist (30 с защита остаётся только для чтения). `ccl-sync publisher --now` — то же правило.
- **B6 через gist.** Чужой `retryUntil` той же метки → `RefreshState.server_until = max(…)`,
  `AutoPollState.serverRetryAt`; дедлайн абсолютный, ничем не сокращается. Дедлайн > 24 ч: соблюдаем 24 ч, затем
  одна попытка по расписанию (сервер при необходимости взведёт снова); в `status` — «сервер просит ждать до <дата>».
- **Чужие показания в истории темпа.** Читатель кладёт новые чужие `asOf` в `history` по продукту (дедуп по `t`),
  так «недавний темп» считается без изменений кода темпа.

## E. Политика токенов (S1)

Настройка машины `credential_write ∈ {never, guarded}`; `never` по умолчанию при `publisher: true` (VPS),
`guarded` = сегодняшнее поведение (`_PENDING`, перечитывание перед записью, `deadRefresh`) на маке и трее.

| Состояние | Условие (каждая попытка перечитывает файл входа) | Запросы | Публикуется |
|---|---|---|---|
| live | access валиден ≥ 2 мин | usage 1 | `ok`, новый `asOf` |
| expiring (never) | access истёк/< 2 мин, refresh есть; Claude: `refreshTokenExpiresAt > now`; Codex: `exp` JWT прошёл, refresh есть | 0 | `expired` + `cli_refresh_pending`, прежние значения и `asOf` (C3) |
| dead | Claude `refreshTokenExpiresAt ≤ now`, или нет refresh, или (guarded) отпечаток в `deadRefresh` | 0 | `expired` + `signin_required` |
| signed_out | файла/блока нет | 0 | `signed_out`, значений нет (C4) |
| read_error | не читается после 5×0,2 с | 0 | `error` (класс credentials), шаг Auto вверх как сегодня |

Переходы: expiring → live, когда CLI перепишет файл (`expiresAt` ушёл в будущее) — издатель замечает на следующей
попытке; у Codex «навсегда» не различимо (нет срока refresh) — честно остаётся `cli_refresh_pending`.
Механизм: один guard перед POST `/v1/oauth/token` (`limits.py` ~219) и перед POST `auth.openai.com/oauth/token`
(~527): `if not credential_write_allowed(): return _credential_failure(d, EXPIRED, …)` с `d.expired_reason`.
В режиме `never` `_PENDING` не наполняется, `deadRefresh` не ставится; guarded-ветка не меняется (S2).
Журнал: `token_refresh` только в guarded; на VPS `credentialWrite` = 0 (G2). Читатель (V5 №3): «на машине vps
ждём обновления входа Claude Code — команда простаивает» / «на машине vps нужно войти в Claude Code заново»;
`limitCanFix` = false для чужих карточек (урок 012).

## F. macOS — читатель и издатель

- **Модель данных.** `struct RemoteAccount: Codable` (поля §A + `machineId/Name/Updated`) в
  `SyncRemoteCache.accounts: [RemoteAccount]?` (optional → старые кэши декодируются); заполняет `merge()` с C7.
  `struct AccountView { product, label?, caption, data: LimitData, isLocal, tier?, usageDays }`;
  `LimitData.source: RemoteSource?` (machine, asOf, nextAt, interval, mode, stateV5, freshUntil) — nil у локальных.
  `func resolveAccounts(local:(LimitData,LimitData), remote:SyncRemoteCache, localLabels:[String:String],
  hidden:Set<String>, now:Date) -> [AccountView]` — чистая: группировка по (product,label), V3 (самый свежий
  успешный `asOf`, при равенстве локальный), V5 по таблице ниже, порядок V2. Расход без метки → группа V7 без карточки.
- **Таблица V5** (чужая карточка): 1 свежо — `now ≤ freshUntil`, `freshUntil = (schedule.nextAt ?? asOf+interval) + 20 мин`;
  2 устарело — иначе, при живом источнике; 3 вход на источнике — `expired`/`signed_out`; 4 — `rate_limited` до
  `retryUntil`; 5 источник не на связи — `machineUpdated < now − 30 мин`; 6 — действующий баннер синка;
  7 — нет входа в GitHub. Приоритет 7 > 6 > 5 > 3 > 4 > 2 > 1. 4-часовое правило к чужим не применяется:
  `isStale`/`metricIsStale` при `source != nil` берут `freshUntil`.
- **Рендер — минимум движений.** Слоты `claude`/`codex` = первый `AccountView` своего продукта (набор владельца:
  Claude с VPS, Codex — слияние мака и VPS). Draw-код трогается в 4 точках: подпись карточки (`AdvCard.name`,
  `prods`-кортеж Simple), строка «данные с vps от HH:MM · <состояние>» в слоте `limitSnapshotNotice`/
  `limitSimpleStaleCopy`, `limitCanFix` (false при `source`), свежесть. Дополнительные аккаунты (3-й+) —
  milestone C5: цикл `advCards` и `prods` уже перебирают список, высоты считать от списка.
- **N1/N2 и миграция.** Ключи `monitor_*` сохраняют значение «опрашивать локально» (подпись в настройках:
  «Опрашивать на этом Маке»); новый `hiddenAccounts: [String]` (метки), по умолчанию пусто = видны все (N3 —
  записи миграции не нужны). Аудит `productEnabled`: **оставить** в `fetchClaude`/`fetchCodex` (0 Keychain/API при
  выключенном опросе, урок 013), `UsageLogs.scan`, `snapshotJSON` (загрузка расхода), `UsageHistory.record`;
  **заменить** в `mergedUsageIndex` (фильтр по `hiddenAccounts`, не по продукту — U2), `advCards`,
  `applyTrayImage`, `prods` Simple, `showMissingProduct` (на резолвер); `monitoringPaused` = «нет локальных опросов».
  Селфтест ~7108 переписывается: «remote usage of a visible account survives a disabled local poll».
  `cache.json` хранит только локальные показания; чужие живут в `sync-remote.json`.
- **U3.** `subscriptionUSD(product, plan, tier: String?)`: локальный — `claudeTier` как сегодня; чужой — `tier` из
  записи, nil → оценка. Цена на аккаунт `sub:<label>` — Should; `subClaude/subCodex` только для локальных.
- **V8 строка меню.** Слоты как выше ⇒ по умолчанию аккаунт с локальным входом, без него — Claude с VPS; устаревание
  через `freshUntil`. Выбор другого аккаунта (`trayAccount:<product>`) — Should.
- **P5 издатель.** `machineFile` += `accounts` из `last.1` (Codex) + `autoStates["codex"]` + метка из
  `~/.codex/auth.json` (чтение файла) + `quotaStates` дедлайн; хеш включает блок; после успешного опроса Codex →
  `GitHubSync.shared.syncNow()` (у мака нет пола записи). B2 на маке: при due для аккаунта, присутствующего у других
  машин, `doRefresh` ставит `pendingRemoteCheck[product]`, запускает `syncNow()`, по `onChange` повторяет допуск;
  неудача синка → своё расписание. Журнал O1: `~/.claude-limits-monitor/poll-log.jsonl`.
- **Сборка/проверка.** Селфтест `--remote-limits-selftest` (память-defaults, `OFFLINE_SYNC_HTTP`, фикстуры файлов,
  инжекция `now` — урок 011) + PNG-превью 7 состояний V5 для визуальной сверки Юркой через remote-hands.

### F.1 Решения по дополнению UX (`design/remote-limits-ux.md`)

1. **Имя машины без ПДн (A2/A3).** macOS сегодня пишет в `machine.name` `Host.current().localizedName`
   («MacBook Pro — Алекс») — это уже утечка в v1. Новые версии обоих портов пишут в `machine.name` **тег машины**:
   настройка `machineName` (mac — новый ключ defaults, Linux — существующий `settings.machineName`), иначе первая
   DNS-метка `hostName`; санитизация: NFKD → ASCII, нижний регистр, только `[a-z0-9-]`, ≤ 16 символов, пусто →
   `mac`/`linux`. Отдельного поля не вводим: `machine.name` только отображается (старые читатели покажут тег, это
   безвредно), а санитизация убирает существующую утечку. Протокол v1.1: «`machine.name` — тег без личных имён,
   писатель обязан санитизировать; читатель обрезает до 16». Подпись `<Продукт> <план> · <машины>` строится из тегов.
   Тест: `localizedName` «MacBook Pro — Алекс» → `machine.name == "macbook-pro"`; скан S3 на имя владельца.
2. **Горизонт свежести чужих показаний (V4).** Один помощник `snapshotHorizon(d) -> TimeInterval` =
   `d.source != nil ? max(0, source.freshUntil − asOf) : SNAPSHOT_MAX_AGE`; три точки вызова: `metricIsStale`
   (3097 — кольцо, строка меню, `.stale` в Advanced), `advVerdict` (4254), `isStale` через `metricIsStale`.
   `SNAPSHOT_MAX_AGE` для локальных не меняется. Тест: Auto 4 ч, показание 3 ч 50 мин, файл свежий → не stale;
   `freshUntil` прошёл → stale у всех трёх потребителей.
3. **Клик по чужой карточке (V5, п. 4 приёмки UX).** `limitCanFix(product:auth:remote: Bool)` → `false` при
   `source != nil`; `AdvCard.canFix` считается один раз из `AccountView` и используется в обеих точках
   (hit `claudefix` ~4494 и код `claude → /login` ~4494+), Simple-панель — та же функция. Hit чужой карточки всегда
   `open:<url>`. Тест: `expired` с VPS → hits не содержат `claudefix`, бейджа «вход истёк» нет.
4. **Бейдж плана из снимка (U3).** `AdvCard.tier: String?` из `AccountView` (локальный — `claudeTier`, чужой —
   `tier` записи); общий `planLabel(product:plan:tier:)` для плашки (~4485), подписи и `subscriptionUSD(tier:)`.
   Локальный `claudeTier` к чужому аккаунту не применяется (тест: tier у чужого `max_5x` при локальном `max_20x`
   → плашка «Max 5x», деньги $100).
5. **Кэш снимков после выхода из GitHub (состояние 7).** Снимки аккаунтов живут в том же `SyncRemoteCache`
   (`sync-remote.json`) под той же привязкой `authEpoch/authUserID`, что и `days`. `off`/`revoked` → из показа
   исключаются (как `remoteDays()` при `phase != .on`): состояние 7 показывает только призыв «Войдите в GitHub ›»
   без значений; явный выход или смена аккаунта GitHub → файл удаляется, как сегодня (2234, 2343). Отдельного
   непривязанного кэша не заводим: он вернул бы межаккаунтную утечку, которую убрала V2-привязка
   (`docs/sync-protocol.md`, Account-bound cache). Повторный вход тем же пользователем до удаления → кэш снова
   валиден без ожидания цикла. UX-спек: клауза «показаны данные из кэша» в состоянии 7 снимается, остаются строки
   разделов 9–10. Linux-читатель (вторая очередь) — то же: `logout()` уже удаляет `SYNC_REMOTE_PATH`.

## G. Порядок сборки (milestone по зависимостям; тесты офлайн, без реальных учёток/API — урок 006)

**Срез A — сервер (проверяется журналом VPS).**
1. **A1 контракт+метки.** `accounts.py` (label, build/parse/validate), `common.machine_tag()`, `docs/sync-protocol.md` §v1.1, фикстуры
   `machine-v11.json`, `machine-v11-hostile.json`. Тесты: детерминизм метки (один id → одна метка, два gist id → разные),
   скан запрещённых шаблонов (email, `account_id`, `accountUuid`, `refresh`, `access_token`, `sk-`, `/home/`, `/Users/`),
   `sync.merge()` на фикстуре = на фикстуре без блока, валидация C7 на hostile.
2. **A2 политика токенов.** `credential_write`, guard-ы в `limits.py`, `expired_reason`. Тесты: синтетические
   `.credentials.json`/`auth.json` (live/expiring/dead/absent/partial) при `common.http = no_network` → 0 запросов,
   верные статусы; guarded-ветка регрессом не меняется (существующие тесты).
3. **A3 ядро издателя.** `publisher.py` с инжекцией часов/транспорта; `sync_cycle(accounts=…)`: хеш, обход пола,
   разбор `accounts` в `sync-remote.json`; журнал; `ccl-sync publisher`; хук в `cmd_push`. Тесты (фикс. часы):
   due/not_due через перезапуск и «перезагрузку»; B3 — Store с инжектированным `OSError` → запроса нет;
   P6 — без входа 0 запросов; Retry-After сохранён и опубликован; запись сразу при новом `asOf`, пол при расходе;
   журнал без секретов; `FakeGitHub` ловит каждый лишний запрос.
4. **A4 установка и статус.** `install.sh --publisher/--no-tray`, таймер 5 мин, `XDG_RUNTIME_DIR`, `status` O2.
   Тест: install.sh в временном `HOME` с подменным `systemctl` в `PATH` → юниты/настройки ожидаемые; `test_deb` зелёный.
5. **A5 выкатка на VPS.** Владелец: `ccl-sync login`; 24 ч журнала → проверка G1 (интервалы ≥ 900 с, ≤ 10/день при
   простое), G2 (`credentialWrite` = 0, Claude Code без перевхода), файл в gist с блоком; старые читатели (мак 3.2.7)
   продолжают суммировать расход.

**Срез B — координация.**
6. **B1 решение B2.** Чистая `coordination.decide(now, my_state, remote_entries, my_id)` + тесты: fresh_remote →
   пропуск; состарилось → опрос; чужой `retryUntil`; защита 60 с; тай-брейк; gist недоступен → своё расписание;
   сходимость двух симулированных машин за ≤ 1 пересечение (пары < 900 с считаются и равны 0 после него).
7. **B2 трей на машине с издателем (P3).** Допуск `delegated`, перечитывание кэша, ручная кнопка → проход, сохранение
   попытки до воркера. Тесты в стиле `test_auto_ui` (Qt при наличии): 2 ч симуляции трей+таймер → ≤ 1 запрос/15 мин.
8. **B3 Linux-трей publish-only** (P1, дёшево: тот же `accounts.build` из `cache.json`+`autoPollState` при
   `publisher: false`). Может уйти во вторую очередь без влияния на мак.

**Срез C — мак (сборка через remote-hands, установка — владелец).**
9. **C1 merge v1.1 + резолвер.** Селфтесты: совместимость (старый/новый файл → одинаковые `days`), hostile-блок,
   резолвер V3 (один Codex на двух машинах → одна карточка; разные → две записи), V5 по таблице с инжекцией `now`.
10. **C2 настройки и деньги.** Семантика `monitor_*`, `hiddenAccounts`, `mergedUsageIndex`, селфтест 7108 →
    новая формулировка, `subscriptionUSD(tier)` ($200 без «оценки» для `max_20x` с VPS), U2.
11. **C3 UI.** Подпись и тег машины, строка источника, тексты V5 (от UX), `limitCanFix(remote:)`, `snapshotHorizon`,
    плашка плана из снимка, строка меню; PNG-превью 7 состояний; Юрка сверяет в реальном приложении (Simple и Advanced).
12. **C4 издатель мака и B2.** Блок Codex в `machineFile`, `syncNow()` после опроса, `pendingRemoteCheck`,
    ручное 900 с, `poll-log.jsonl`. Селфтест: после опроса файл содержит блок с меткой; при свежем чужом показании
    `doRefresh` не вызывает `fetchCodex` (транспорт-ловушка).
13. **C5 дополнительные аккаунты** (N карточек, `captions`, список N1 в настройках) — Should.
14. **C6 релиз.** Документация, changelog, ИБ-чек T3; 14-дневный замер G1–G4 по журналам обеих машин.

## Компоненты

| Компонент | Ответственность | Зависит от | Тест |
|---|---|---|---|
| `linux/ccl/accounts.py` | метка, сборка/разбор/валидация блока `accounts`, подпись по умолчанию | `common`, `usage` | pure, фикстуры, скан секретов |
| `linux/ccl/publisher.py` | проход: due → B2 → B3 → fetch → observe → cache → журнал → публикация | `polling`, `limits`, `sync`, `accounts` | фикс. часы, `FakeGitHub`, фейковые файлы входа |
| `linux/ccl/coordination.py` | чистое решение пропуска/тай-брейка/Retry-After | — | симуляция двух машин |
| `linux/ccl/limits.py` (+guard) | политика `credential_write` | `common.settings` | синтетические файлы, `no_network` |
| `linux/ccl/sync.py` (+`accounts=`) | хеш с блоком, обход пола, разбор чужих блоков | `accounts` | `test_sync_merge` расширить |
| `linux/ccl/cli.py`, `install.sh` | `publisher` подкоманда, `--publisher`, таймер 5 мин, `status` O2 | `publisher` | install в tmp HOME, CLI-тесты |
| `linux/ccl/gui/app.py` (delegated) | трей на машине с издателем | `publisher` | `test_auto_ui`-стиль |
| Swift `RemoteAccount`/`merge` | разбор v1.1 с C7 | `SyncRemoteCache` | `--sync-selftest` фикстуры |
| Swift `resolveAccounts` | V1–V7 чистая логика | `RemoteAccount`, `LimitData.source` | селфтест с `now` |
| Swift settings/money | N1–N3, U2–U3 | резолвер | селфтест 7108 (переписан), subscriptions |
| Swift draw/menu bar | подпись, источник, V5-тексты, горизонт свежести, `canFix`, плашка плана, V8 | резолвер | PNG-превью + визуальная сверка |
| `machineTag()` (оба порта) | тег машины без ПДн для `machine.name` и подписей | settings/hostName | санитизация, скан имени владельца |
| Swift publisher | блок Codex, `syncNow` после опроса, B2 на маке, poll-log | `AutoPollState`, `GitHubSync` | селфтест с транспорт-ловушкой |

## Риски и альтернативы

1. `~/.claude.json` — недокументированный файл CLI, поле может переехать. Деградация штатная: `label: null` →
   группа A5 + причина в журнале; Could — `GET /api/oauth/profile` 1/сутки в бюджете B1.
2. Ключ из gist id vs секрет в манифесте — SecurityAnalyst может предпочесть второе; смена стоит один PATCH
   манифеста и правило «ранний побеждает», интерфейс `accounts.label(id, key)` не меняется.
3. Два `sync_cycle` на due-тик вместо перестройки `_sync_cycle` на фазы чтение/запись: +1 GET, зато без правки
   чувствительного кода auth/401. Альтернатива — разнести `_sync_cycle` на `read()`/`write()` (больший дифф).
4. Трей в режиме `delegated` на реальном XFCE VPS не проверялся — вторая очередь; при отсутствии трея на VPS риск нулевой.
5. `LimitsMonitor.swift`: поле `source` касается нескольких draw-функций; правки только аддитивные, обязательны
   PNG-превью и сверка Юркой; сборка на маке через remote-hands (без сети — все тесты офлайн).
6. Расхождение часов > 60 с между машинами → возможна одна близкая пара на пересечение; журналы показывают
   `asOf` против `updated` файла, контролируется на замере.
7. Два разных Codex-аккаунта в Simple — раскладка N карточек требует решения UX; у владельца набор из одного Codex,
   данные и Advanced поддерживают N с C1/C5.
8. Атрибуция дня при смене входа «первая побеждает» — приблизительна по PRD A6, зафиксировать в протоколе.
9. `OnUnitActiveSec=5min` удваивает проходы; индекс инкрементальный, первая индексация 62+30 МБ только при установке.
10. Фоновое `syncNow()` перед ручным обновлением на маке добавляет секунды задержки — допустимо, показывать «читаю gist…».

## Артефакты

- `/home/yurka/VibeCoding2/2026_06_UsageLimits/arch/plan-claude.md` (этот файл).

## Вопросы к человеку

1. Утвердить числовой допуск B2 (§D): ≤ 1 пара < 900 с на аккаунт на событие сходимости, ≤ 3 событий/день;
   в установившемся режиме 0. PRD требует утверждения до кода.
2. Трей на VPS при включённом издателе сам не опрашивает (режим `delegated`, кнопка «Обновить» запускает проход
   издателя). Подходит?
