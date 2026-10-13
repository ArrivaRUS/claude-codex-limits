# REMOTE-LIMITS — тест-план (до кода, P13)

2026-10-12 · tester (Claude Opus). Тесты по этому плану ещё **не написаны и не запускались**. По нему разработчик видит критерии готовности каждого milestone, а tester потом пишет тесты. Источник правды — `arch/plan-synth.md` v2 с правками после T1 от вечера 2026-10-12 (контракт v1.1, §A–§G, milestones A1–A5 / B1–B2 / C1–C6). Ещё входы: модель угроз T1 `docs/security-remote-limits.md` (§6, Т1–Т36: все строки разнесены ниже), PRD `docs/prd-remote-limits.md` (F1–F9, RL-1…RL-23, G1–G4; редакция 2026-10-12 с правками B2/B6/C6/S1), UX `design/remote-limits-ux.md` (§4 V5, §11 «Приёмка»). Обязательные уроки: [006](../.patches/006-tests-touch-real-keyring.md), [011](../.patches/011-selftest-clock-can-escape-offline-fixture.md), [012](../.patches/012-stale-data-is-not-auth-expiry.md), [013](../.patches/013-background-keychain-prompts.md). План описывает только вход, ожидаемый результат, ловушку и фикстуру. Как устроена реализация, он не повторяет. Где v2 и T1 расходятся, тест следует более строгому требованию, а расхождение вынесено в §6 на решение Юрки.

## 0. Изоляция и общие фикстуры (готовятся в A1, до первого теста)

**Правила для каждого теста (без исключений):**
- **006.** Никаких реальных учёток, keyring/Keychain, журналов CLI, gist или API. `XDG_*` **и `HOME`** переводятся во временный каталог **до** `import ccl` (`_isolate.py`). Новые константы путей (`~/.claude.json`, `publisher.jsonl`, `publisher-state.json`, `rotation-pending-*`, `settings.json`) входят в список перенаправления `_isolate.py`. `test_zz_isolation.py` дополняется проверкой `stat` (наличие + mtime, содержимое **не читается**) реальных `~/.claude.json`, `~/.claude/.credentials.json`, `~/.codex/auth.json` и state-файлов издателя. `common.http`, `sync.transport`, `vault._ss*` — запрет по умолчанию. Тест подключает только свою записывающую подделку.
- **011.** Все часы фиксированные или инжектированы: `FakeClock` в Python, аргумент `now:` в Swift. Нет `sleep`, реального `time.time()`/`Date()` в проверяемых путях. «Не due» **не** считается доказательством. Каждый тест проверяет журнал транспорта (0 вызовов провайдера / PATCH) и `stat`+sha файлов, а не только возвращённое решение.
- **012.** Возраст данных, нет данных и `error` никогда не дают текстов/действий «вход истёк». Проверяется в каждом тесте V5/UI.
- **013.** 0 фоновых Keychain-обращений: в Swift-селфтестах счётчик-ловушка Keychain/helper (`OfflineSyncKeychain` + записывающий helper), ожидание 0 во всех путях читателя и при выключенном локальном опросе. Отсутствие системного окна селфтест не доказывает (граница — §4).

**Новая инфраструктура тестов (пишет tester; production не трогает):**

| Фикстура | Где | Что даёт |
|---|---|---|
| `RLEnv(SyncEnv)` | `linux/tests/_rl_env.py` | временный HOME с синтетическими `~/.claude.json` / `.credentials.json` / `auth.json` (фабрика состояний live·expiring·dead·absent·partial·empty-mid-write), `FakeClock`, `snap_cred()` = {sha256, size, mtime_ns, ino} файлов входа до/после |
| `Ledger` + `TrapTransport` | там же | **единый** журнал порядка вызовов: GET/PATCH GitHub, запросы к провайдерам, `/oauth/token`, записи `state.json`/`publisher-state.json` (обёртка `write_atomic`), с порядковым номером `seq`. Любой незаказанный вызов = FAIL |
| `FakeGist` | там же | gist с состоянием: файлы, ревизии, заголовок `Date` = часы + `skew`, сбои GET/PATCH по сценарию (5xx, сеть, 404, `public: true`), **задержка видимости** записи для другой машины (0 / 30 с / 5 мин), лимиты тел |
| `FakeProvider` | там же | Anthropic/OpenAI usage: 200 (синтетические проценты), 401, 429 + `Retry-After` (секунды/дата/мусор), 302 на чужой хост; счётчик по метке + время каждого запроса |
| `TwoMachineSim` | `linux/tests/_rl_sim.py` | две (или три) машины = два `RLEnv` со своими STATE/HOME, общий `FakeGist`, общий `FakeProvider`. Виртуальные 24 ч, таймер 5 мин с фазовым сдвигом, события по сценарию. Выход — пары запросов < 900 с по метке, GET/PATCH на машину |
| Золотые фикстуры | `fixtures/remote-limits/` (корень, **общие** для Python и Swift) | `machine-v11.json` (пример §A), `machine-v10.json` (тот же без новых ключей), `machine-v11-hostile.json`, `machine-v11-nonfinite.json` (NaN/Infinity/1e400 — не строгий JSON: Python принимает, Swift отвергает файл целиком) + детерминированный генератор больших случаев `gen_hostile.py` (10⁴ глубины, 100 файлов × 1 MiB, тела 9/20 MiB), `label-vectors.json`, `decide-vectors.json`, `resolver-vectors.json`, `sanitize-vectors.json`, `pii-sentinels.json` (синтетические email/имя/токены/UUID, собираются в рантайме, чтобы не ловиться `secrets-check`) |
| Паритет Swift | `tools/gen-rl-fixtures.py` → `Sources/RemoteLimitsFixtures.swift` | те же JSON как строковые литералы для селфтестов. `test_rl_fixture_parity.py` пересобирает файл и сравнивает побайтно (дрейф = FAIL) |
| Устаревший merge | `linux/tests/fixtures/legacy_merge_045.py` | замороженная копия `sync.merge()` из `linux-v0.4.5` (sha исходника в шапке). Для Swift — существующий `GitHubSync.merge`, его v2 не меняет |

Swift: C1/C4 — новые секции `--sync-selftest`, C2/C3 — `--subscriptions-selftest` (PNG там уже рождаются). Транспорт `OFFLINE_SYNC_HTTP` или записывающая подделка, `installMemorySelfTestDefaults()`, `now:` явный. Запуск — только после ревью изоляции точного дифа (практика MANUAL-REFRESH), сборка и прогон — через remote-hands на маке.

**Команды.** Linux: `cd <PROJECT_ROOT> && python3 -m unittest discover -s linux/tests -p 'test_rl_*.py' -v`, потом полный
`python3 -m unittest discover -s linux/tests -v` (последним идёт `test_zz_isolation`). GUI-тесты B1 — с `QT_QPA_PLATFORM=offscreen`. macOS: `sh build.sh`, затем `<app>/Contents/MacOS/<bin> --sync-selftest` и `--subscriptions-selftest` (exit 0, ни одной строки `FAIL`).

**Требования к швам (передать разработчику через Юрку):** `publisher.run_pass(kind, *, now, transport, providers)` или эквивалентная инжекция.
`coordination.decide` чистая. `accounts.label(gist_id, product, local_id)` чистая. Пути файлов входа — через `common.*`. `install.sh` принимает подменный `systemctl` из `PATH`. Swift: `resolveAccounts(... now:)`, `coordinationDecide`, `fetchCodex` и транспорт `syncNow` инжектируемы в селфтест. Без этих швов тест в строке пишется только как интеграционный на уровне CLI.

## 1. Матрица покрытия

### 1a. PRD (acceptance F1–F9, истории, цели) и UX §11

| Требование | Тесты | Milestone | Порт | Тип |
|---|---|---|---|---|
| F1 acc «один Codex на двух → одна карточка» · RL-1 · G4 | C1-04, A1-01, C1-01 | C1 | оба | pure (golden) |
| F1 acc «разные Codex → две карточки, свой расход/деньги» · RL-1 · RL-18 | C1-04, C2-03 | C1, C2 | Swift | селфтест |
| F1 acc «скан файла: нет email/`account_id`/`accountUuid`/`refresh`/`access_token`/`sk-`/`/home/`/`/Users/`» · RL-12 · S3 | A1-10 | A1 | Linux (+C4 Swift) | pure |
| F1 acc «смена Claude-аккаунта на VPS → новая метка, старый расход под старой» · A6 | A1-05, A1-06 | A1 | Linux | pure |
| F2 acc «старые 3.2.7 / 0.4.5 суммируют расход v1.1» · C1 · RL-3 | A1-09, C1-03 | A1, C1 | оба | pure (golden) |
| F2 acc «401 после успеха → `expired`, прежние значения и `asOf`» · C3 | A3-12, A2-01 | A3 | Linux | интеграционный |
| F2 acc «`pct` = `"80"`/`true`/`140` → окно отброшено, остальное принято» · C7 | A1-13, C1-02 | A1, C1 | оба | pure (golden) |
| F3 acc «Ubuntu без PyQt5 → снимки в gist ≤ 15 мин» · RL-4 · P1 | A4-05, A3-02, A5-руч. | A4, A5 | Linux | интегр. + ручной VPS |
| F3 acc «трей + издатель 2 ч → ≤ 1 запрос/15 мин» · RL-5 · P3 | B1-01 | B1 | Linux | интеграционный (offscreen) |
| F3 acc «нет входа в GitHub → 0 запросов, `status` объясняет» · P6 | A3-05, A4-03 | A3, A4 | Linux | интеграционный |
| F3 acc «мак с Codex → снимок Codex в файле мака» · RL-6 · P5 | C4-01 | C4 | Swift | селфтест |
| F4 acc «показание 5 мин назад: рестарт/таймер/перезагрузка → 0 запросов» · RL-7 · B3 | A3-07 | A3 | Linux | интеграционный |
| F4 acc «429 `Retry-After: 3600` → час тишины, мак тоже» · RL-9 · B6 | A3-08, A3-01(v), C4-05 | A3, C4 | оба | интегр. + pure |
| F4 acc «12 ч простоя → 4 ч, ≤ 10 запросов/сутки» · G1 | A3-20(b) | A3 | Linux | симулятор |
| F4 acc «VPS опросил 3 мин назад → мак не опрашивает» · RL-8 · B2 | A3-01, C4-04 | A3, C4 | оба | pure (golden) + селфтест |
| F4 acc «мак без Claude: «Обновить» = только чтение gist» · RL-10 · B8 · B10 | C4-06 | C4 | Swift | селфтест |
| RL-10 «VPS опросил 5 мин назад → «Опрос можно с HH:MM»» · «≥ 900 с и нет `retryUntil` → ровно 1 запрос» | C4-06, A3-15 | A3, C4 | оба | интегр. |
| F5 acc «14 дней, 0 повторных входов; 0 записей в файлы входа» · RL-11 · G2 · S1 | A2-01…A2-07, A5-руч. | A2, A5 | Linux | интегр. + ручной VPS |
| F5 acc «access истёк при «только чтение» → 0 `/oauth/token` и usage, `expired`, нет `claude login`» · 012 | A2-01, C3-01 | A2, C3 | оба | интегр. + селфтест |
| F5 acc «скан файла и журнала S3/S5» · S4 | A1-10, A3-17, A4-03 | A1, A3, A4 | Linux | pure |
| F6 acc «Claude с VPS 10 мин назад: Simple+Advanced, «данные с vps от HH:MM», темп, деньги» · RL-13 · UX 1 | C3-03, C3-10 (PNG) | C3 | Swift | селфтест + визуальный |
| F6 acc «Auto 4 ч, 3 ч 50 мин → не устарело» · V4 · UX 5 | C1-06, C3-04 | C1, C3 | Swift | pure (`now`) |
| F6 acc «VPS выключен 40 мин → состояние 5» · RL-14 · UX 5 | C1-06 | C1 | Swift | pure (`now`) |
| F6 acc «`asOf` 10:00, сброс 11:00, сейчас 11:20 → сброшено» · RL-15 · V6 · UX 6 | C3-05 | C3 | Swift | селфтест |
| F6 acc «старая 0.4.5 Codex без метки → «аккаунт не указан»» · RL-17 · V7 | C1-05 | C1 | Swift | pure |
| F7 acc «`max_20x` → $200 без «оценки»» · U3 · G4 · RL-18 | C2-02 | C2 | Swift | селфтест |
| F7 acc «два Codex → раздельные столбики/деньги» · U1 | C2-03 | C2 | Swift | селфтест |
| F8 acc «мак с выключенным Claude → карточка VPS, 0 запросов и 0 Keychain по Claude» · RL-19 · N3 · UX 12 · 013 | C2-01, C2-05 | C2 | Swift | селфтест (ловушка Keychain) |
| F8 acc «скрытый аккаунт пропал из карточек/меню/расхода, на других машинах виден» · N1 | C2-06 | C2 | Swift | селфтест |
| F9 O1 журнал · O2 `status` · RL-20 | A3-17, A4-03 | A3, A4 | Linux | интегр. |
| PRD §4 сквозной сценарий (VPS + мак, 30 мин) | A3-20(a) + ручной A5 + визуальный C3 | A3, A5, C6 | оба | симулятор + ручной |
| G1 / G2 / G3 / G4 — замер 14 дней · PRD §5 `reader_card_state` | C6-01 (редьюсер журналов), C2-08, ручной C6 | C2, C6 | оба | pure + селфтест + ручной |
| RL-2 подписи (Should) | C5-01, C5-02 | C5 | оба | pure + селфтест |
| RL-16 строка меню · V8 · UX 10 | C2-07, C3-08 | C2, C3 | Swift | селфтест + визуальный |
| RL-21 Linux-трей (Should, 2-я очередь) | B2-01; показ — вне плана (§4) | B2 | Linux | интегр. |
| RL-22 звуки, RL-23 > 4 аккаунтов (Could) | не планируются в этой поставке (§4) | — | — | — |
| UX §11 п. 2, 8 (высоты, сетка 544 pt) | C3-06 | C3 | Swift | селфтест (геометрия) + визуальный |
| UX §11 п. 3 (V5 1–7 × RU/EN × узкая/широкая/Advanced, фазы ручного) | C3-02, C3-10 | C3 | Swift | селфтест (строки) + PNG |
| UX §11 п. 4 (нет `claude login`/`claudefix`; клик → страница) · 012 | C3-01 | C3 | Swift | селфтест |
| UX §11 п. 7, 9, 11, 13 | C1-04 / C3-07 / C3-09 / C3-10 + ручная сверка | C1, C3 | Swift | селфтест + визуальный |

### 1b. Обязательные проверки T1 (Т1–Т36) → тест → milestone

| Т | Тест | MS | Порт | | Т | Тест | MS | Порт |
|---|---|---|---|---|---|---|---|---|
| Т1 | A1-01, C1-01 | A1, C1 | оба | | Т19 | A1-13(d), C1-02 | A1, C1 | оба |
| Т2 | A1-02, A3-04 | A1, A3 | Linux | | Т20 | A4-01 | A4 | Linux |
| Т3 | A1-07 | A1 | Linux | | Т21 | A3-17 | A3 | Linux (+C4 Swift) |
| Т4 | A1-05 (редакция Юрки) | A1 | Linux | | Т22 | A4-03 | A4 | Linux |
| Т5 | A3-17, A4-03 | A3, A4 | Linux | | Т23 | A3-01(f) | A3 (+C4) | оба |
| Т6 | A1-03 | A1 | Linux | | Т24 | A3-20(c) | A3 | Linux (sim) |
| Т7 | A2-01 | A2 | Linux | | Т25 | A3-01(g) | A3 | оба |
| Т8 | A2-02 | A2 | Linux | | Т26 | B1-01, B1-04 | B1 | Linux |
| Т9 | A2-05, A2-09 (единое правило) | A2 | Linux | | Т27 | A3-19 | Т27: замок `sync` держит «трей» (дочерний процесс) 40 с / 70 с; `quota` занят > 30 с | `open_cycle` ждёт `sync` **блокирующе ≤ 60 с**: 40 с → gist прочитан; 70 с → как недоступный gist (P6: своё расписание, блок позже); `quota` занят → `pass_skipped busy`, Ledger пуст | реальный `flock`, инжектированный таймаут |
| Т10 | A2-06 | A2 | Linux | | Т28 | A4-04 | A4 | Linux |
| Т11 | C4-07 | C4 | Swift | | Т29 | A3-13 | A3 | Linux (+C4) |
| Т12 | A1-10, A3-17, A4-03, C4-09 | A1, A3, A4, C4 | оба | | Т30 | A1-14, C1-02, A4-03 | A1, C1, A4 | оба |
| Т13 | A1-11, C1-08 | A1, C1 | оба | | Т31 | A3-01(h), A3-09 | A3 | оба |
| Т14 | A1-12, C3-11 | A1, C3 | оба | | Т32 | A3-20(d), A3-10, A3-15, C4-06 | A3, C4 | оба |
| Т15 | A1-13, C1-02 | A1, C1 | оба | | Т33 | A2-07, A2-06, A4-02 | A2, A4 | Linux |
| Т16 | C3-01 | C3 | Swift | | Т34 | A3-11 | A3 | Linux |
| Т17 | B1-06 | B1 | Linux | | Т35 | A2-08, C4-10 | A2, C4 | оба |
| Т18 | A1-14 | пределы читателя по v2 §A C7: `raw_url` 8 МиБ / 8 МиБ+1; 65 файлов `machine-*`; суммарно > 64 МиБ; тело ответа > 16 МиБ; `pct` NaN/inf; `machine.name/os/app` и строки блока с `Cc`/`Cf` (ESC, bidi, zero-width) | 8 МиБ принят, +1 байт — отказ; > 64 файлов / > 64 МиБ / > 16 МиБ → ошибка «слишком большой ответ»; тело читается с `read(cap+1)`, а не целиком (подделка считает байты); не-`isfinite` → отброс; строка с управляющими символами **отброшена** | `FakeGist`, подделка `urlopen` |

Ручные проверки §7 T1 (1)–(5) — раздел 3 этого плана, срез A5.

## 2. Тесты по milestone

Колонки: **ID · вход · ожидание · ловушка/фикстура**. «Ledger пуст» = 0 вызовов провайдеров, `/oauth/token` и PATCH, если не сказано иначе.

### A1 — контракт v1.1 и идентичность (Linux, pure; файл `test_rl_contract.py`)

| ID | Вход | Ожидание | Ловушка / фикстура |
|---|---|---|---|
| A1-01 | `label-vectors.json`: gist id × продукт × UUID в вариантах регистра и пробелов | одна метка на UUID (нормализация до HMAC); два gist id → разные; claude/codex с одним UUID → разные; длина 16, `[0-9a-f]` | golden, тот же файл в C1-01 |
| A1-02 | `~/.claude.json`: (a) полный `oauthAccount` с синтетическими email/`fullName`/`displayName`/`organization*`; (b) без `accountUuid`, но с `organizationUuid`; (c) без `oauthAccount`; (d) файла нет | (a) в результате чтения только `accountUuid` (глубокий `repr` без сентинелей); (b) `label: null`, `labelReason: no_account_uuid`, `organizationUuid` не используется **нигде**; (c, d) `no_login` | `pii-sentinels.json` |
| A1-03 | `~/.claude.json` 20 МБ / глубина 10⁴ / не JSON / пустой (запись в процессе) | `label: null`, `labelReason: unreadable`, исключения нет; повтор 5×0,2 с идёт через инжектированный `sleep` (5 вызовов, реального ожидания нет) | генератор, `RLEnv` |
| A1-04 | `~/.codex/auth.json` с `tokens.account_id`, `id_token`, `OPENAI_API_KEY` | идентичность = `account_id`; `id_token`/ключ в структуры не попадают | сентинели |
| A1-05 | Т4 в редакции Юрки (без привязки к поколению): (a) ротация access/refresh в `.credentials.json` при том же `accountUuid`; (b) `accountUuid` сменился; (c) поле пропало | `accountUuid` перечитывается каждый проход: (a) метка та же; (b) новая метка (`label_changed` в O1 — A3); (c) `label: null`, `labelReason: no_account_uuid` | `RLEnv` |
| A1-06 | индексация транскриптов: день D под A, вход сменился на B в середине D, затем D+1 | `accountByDay[p][D] = localId(A)` не меняется; D+1 → B; две корзины, суммы не смешаны; `null` → `unattributedDays` | синтетические транскрипты в tmp HOME |
| A1-07 | тот же индекс, gist id сменился | метки всех дней пересчитаны одинаково; в блоке нет второй записи продукта с «осиротевшими» `days`; в `usage-index.json` нет ни одной 16-hex метки (только `localId`) | grep по файлу индекса |
| A1-08 | 2 аккаунта + `unattributedDays` | корневой `days` = Σ `accounts[*].days` + `unattributedDays` по продукту | — |
| A1-09 | `machine-v11.json` и `machine-v10.json` через `legacy_merge_045.merge` | результаты равны (C1). Тот же файл через текущий `sync.merge` — тоже равен | golden |
| A1-10 | `machine.build` на фикстуре с сентинелями (токены, `OPENAI_API_KEY`, email, имя, организация, hostname, UUID) | (a) ни значение, ни первые 8 символов не встречаются; (b) нет шаблонов: email, UUID ≠ `machine.id`, `eyJ`, `sk-`, `Bearer`, `/home/`, `/Users/`; (c) все ключи ∈ allow-list v1.1 (`cli_refresh_pending` разрешён) | `pii-sentinels.json`; тот же сканер — A3-17, A4-03, C4-09 |
| A1-11 | `sanitize-vectors.json`: `machineName` = «MacBook Pro — Алекс», `macbook`, `vps`; без `machineName` hostname `vps-12345.hoster.ru`, `ubuntu-s-4vcpu-8gb-nyc1`, пусто, эмодзи | `macbook-pro`, `macbook`, `vps`; `vps-12345`, `ubuntu-s-4vcpu-8`; пусто/эмодзи → `linux`; всё ∈ `[a-z0-9-]{1,16}` (тег мака владельца — `macbook`) | golden, общий с C1-08 |
| A1-12 | у писателя: подпись/`models[].name` с `Cc`/`Cf`, bidi, zero-width, 10 000 символов, `<img src=…>`, `%@%n`, `@`, `/` | отброшено/обрезано до 32/48 после NFC; `@` и `/` в подписи отклонены; ≤ 8 аккаунтов, ≤ 8 моделей, ≤ 4 КБ метаданных на запись | golden |
| A1-13 | читатель Linux на `machine-v11-hostile.json`: (a) `pct` `"80"`/`true`/`140`/`NaN`/`Infinity`/`1e400`; (b) `asOf` 9999-12-31, год 99999, `null`; (c) `models` 100, `accounts` 50, `captions` 10⁴ ключей, глубина 10⁴; (d) корень ≠ Σ `accounts.days`; (e) дубль `(product,label)`; неизвестный `status`; `label` не hex | без исключений; валидные окна приняты, `isfinite` отсекает NaN/Inf; (d) лишний корень → «не указан», суммы **не** удвоены; (e) берётся максимальный `asOf`; `status → error`; `label → null`; `days` той машины приняты | golden |
| A1-14 | пределы читателя: `raw_url` 8 MiB / 9 MiB; 100 файлов × 1 MiB; тело GET gist 20 MiB; тело ошибки 20 MiB; `machine.name/os/app` с ESC | 8 MiB принят; 9 MiB и сверх суммарных пределов → ошибка «слишком большой ответ»; читается `cap+1`, а не всё тело (подделка считает прочитанные байты); ESC вычищены, ≤ 64 | `FakeGist` с потоковым телом |
| A1-15 | пример JSON из `docs/sync-protocol.md` v1.1 | парсится и проходит валидатор без потерь (C8) | doc-test |
| A1-16 | N1/M2 (T2): одиночный суррогат `\ud800` (JSON-escape, файл остаётся ASCII) в `machine.name`/`os`/`app`/`tz`/ключе продукта/дня/модели корневого `days` чужого файла + нормальный файл | `sync_cycle` без исключения; нормальная машина слита с её расходом; `sync-remote.json` записан и читается строгим UTF-8; `lastOkAt` сдвинулся; ни одной строки/ключа с одиночным суррогатом в `merge` и в кэше | `machine-v11-surrogate.json` + по файлу на каждое поле; `test_rl_contract_fixes.py` `TestA116LoneSurrogate` |
| A1-17 | N2/M1 (T2): `cmd_status` по живому gist (`machine-v11-hostile.json`, ESC `\x1b[2J`, C1 `\x9b`, bidi `\u202e`, zero-width `\u200b`, `os`/`app` × 100, `name` × 40, одиночный суррогат; 70 файлов `machine-*`) и `cmd_dump --merged` с такими же ключами моделей | stdout строгий UTF-8, исключения нет; в выводе нет `Cc` (кроме `\n`) и `Cf`; нет `os`/`app` длиннее 64 и `name` длиннее 16; `status` перечисляет ≤ 64 машин | подделка `sync.gh` (FakeGitHub), `TextIOWrapper(errors="strict")`; `TestA117TerminalOutput` |
| A1-18 | N3 (T2): `sync._raw` через настоящий `common.http`: 302 с бесконечным телом; 302 на `http://`; 302 на чужой хост; цепочка из 5 переходов; полный цикл с одним таким файлом; 302 на авторизованном `gh` | ни одного чтения тела без предела, всего ≤ cap+1 байт; на `http://` и чужой хост перехода нет; > 3 переходов → не 200; в цикле файл пропущен, остальные слиты, `lastOkAt` сдвинулся; `api.github.com` с токеном — редиректы выключены (страж, зелёный) | in-memory сервер вместо `HTTP(S)Handler` urllib, считает URL и байты тел; `TestA118RawRedirects` |
| A1-19 | N4/m2 (T2): 9 raw по 7,5 МиБ; 65 файлов `machine-*` | транспорт прочитал ≤ 64 МиБ + 1 байт (счёт по проводу, не по сохранённому); слито 1…8 машин; превышение бюджета и > 64 файлов → `res.ok=False`, «слишком большой ответ» в `lastError`, `lastOkAt` сдвинулся (R1) | тот же in-memory сервер; `TestA119TotalBudget` |
| A1-20 | N5 (T2): писатель, `models[].name` = `alice@example.org`, `/home/alice/x`, `C:/Users/alice` + `ok-model` | в блоке нет `@` и `/` в именах моделей (строка отброшена, как у подписей), чистое имя сохранено; скан блока без email и `/home/` | `accounts.build`; `TestA120WriterModelNames` |
| A1-21 | N6 (T2): `usage-index.json` с `accountByDay` = `{"claude": []}`, `{"claude": "garbage"}`, вложенный мусор (`["x"]`, `{"deep": …}`, `"codex": 5`), `[]` | `usage.refresh` и `prune` без исключения; старый расход цел, новый посчитан; в сохранённом индексе `accountByDay[p]` — dict, значения — строки | синтетический транскрипт в tmp HOME; `TestA121BrokenAccountByDay` |
| A1-23 | m1: один файл (< 8 МиБ) с массивом `accounts` из 120 000 сырых элементов | `validate_entry` вызван ≤ 64 раз (счётчик, не время); ≤ 8 записей; Σ `accounts.days` + «не указан» = корень | `mock.patch(wraps=validate_entry)` через `sync.merge`; `TestA123RawAccountsBound` |
| A1-24 | N12: `accountUuid`/`account_id` длиной 129, 65 и 7, с не-ASCII (`Ä`, `İ`), с пробелом/табом внутри, пустой; затем нормальный UUID в верхнем регистре с пробелами по краям и границы 8/64 | форма после `strip().lower()` — `^[0-9a-z-]{8,64}$` (решение Юрки); плохие → `(None, "no_account_uuid")`, в `accountByDay` не попадают (день без владельца); нормальный UUID и границы 8/64 проходят (страж, зелёный) | `RLEnv`; `TestA124LocalIdShape` |
| A1-25 | R3/r2-m2 (T2-r2, дополнение A1-18): в цикле (а) `raw_url` gist-хоста отвечает 302 на `http://`; (б) `raw_url` от API на чужом хосте (`https://evil.example/…`) и на `http://gist.githubusercontent.com/…`; рядом нормальная машина; путь raw с «секретными» gist id и sha | плохой файл пропущен, на чужой хост и `http://` запросов нет; нормальная машина слита с расходом; `lastOkAt` сдвинулся; `res.ok=False`; в `lastError` — сообщение об отказе (редирект/`raw_url`), **без** URL, `gist.githubusercontent.com`, `/raw/`, gist id и sha; в `sync-state.json` их тоже нет | in-memory сервер с журналом заголовков; `test_rl_contract_fixes2.py` `TestA125RawRefusalVisible` (исходный A1-18 не тронут) |
| A1-26 | N1, второй рубеж (T2-r2 рек. 1): `common.write_json(SYNC_REMOTE_PATH)` бросает `OSError` ENOSPC / `PermissionError` EACCES с путём-сентинелем в тексте; отдельно — после этого падает и запись `sync-state.json` (диск полон) | `sync_cycle` без исключения; `res.ok=False`; `lastError` = `res.error`, один и тот же фиксированный текст для обоих исключений, без текста исключения, errno, путей и строк из gist; `lastOkAt` не двигается (1000.0 до и после); следующий цикл без сбоя — `ok`, `lastOkAt` сдвинулся, `lastError` снят; при сбое и записи состояния результат с ошибкой есть в памяти | `mock.patch.object(common, "write_json")` с пропуском прочих путей; `TestA126CacheWriteFailure` |
| A1-27 | r2-m3: `usage-index.json` (ASCII-файл с JSON-escape `\ud800`) — одиночный суррогат во владельце, в ключе дня, в ключе продукта `accountByDay`; плюс запись `"bad": null`, чтобы индекс перезаписывался | `usage.refresh` дважды подряд без исключения; записи с суррогатом отброшены (в памяти и на диске); файл читается строгим UTF-8; валидная запись `recent → U_A` и расход `days` целы | `RLEnv`; `TestA127AccountByDaySurrogate` |
| A1-28 | r2-m4/N5 (NFKC): писатель `accounts.build`, `models[].name` = `alice＠example.org`, `alice﹫example.org`, `／home／alice／x`, `C:\Users\alice`, `C:＼Users＼alice`, `a×50 + ＠x.org`, `b×45 + \x` + `ok-model`; подписи с теми же приёмами + чистая «Рабочий аккаунт» | строка отброшена целиком, решение по `NFKC` до обрезки (нет усечённых «aaaa…»/«cccc…»); после NFKC в именах нет `@`, `/`, `\`; чистые имя и подпись сохранены; скан блока после NFKC без email, `/home/`, `Users` | `accounts.build`; `TestA128WriterNfkc` |
| A1-29 | R4: `tz` чужого файла длиной 65, 207, 1 МиБ; страж — `Europe/Moscow` и ровно 64 | длиннее 64 → `tz` отброшен (пусто), машина и расход сохранены; 64 и обычная зона проходят (страж, зелёный) | `sync.merge`; `TestA129TzBound` |
| A1-30 | R2/n3: прямой `common.http` на gist raw с `Authorization`, `Cookie`, `Proxy-Authorization`, `User-Agent`; 302 на тот же хост | переход выполнен (2 запроса, итог 200); во втором запросе нет `Authorization`/`Cookie`/`Proxy-Authorization`, `User-Agent` тот же; в обычные заголовки второго запроса не скопированы unredirected первого (`Host`) | in-memory сервер пишет `header_items()` и `headers` каждого запроса; `TestA130RedirectHeaders` |
| A1-31 | n4: маркер «response body too large»; raw_url отвечает 404 с бесконечным телом (путь `HTTPError`; путь 200 — A1-19) | `common.BODY_TOO_LARGE` — единственный литерал в `common.py`; в `sync.py` нет своей копии (присваивание/сравнение с литералом; `_BODY_TOO_LARGE`, если остался, — тот же объект); 404 с большим телом → прочитано ≤ cap+1, файл пропущен с ошибкой «слишком большой», не «GET raw_url», цикл не провален, `lastOkAt` сдвинулся (страж, зелёный) | исходники `linux/ccl`; in-memory сервер; `TestA131BodyTooLargeMarker` |
| A1-32 | регрессии §4 T2-r2: (а) `ccl-sync status` без живого gist на старом враждебном `sync-remote.json` (ESC, C1, bidi, ZWSP, суррогат, `name`×40, `os`×100); (б) `dump --merged` и `--json` на нём же; (в) 302 → 300/304/305 и 302 → 404/410 с бесконечным телом; (г) `_raw_cap` после успеха, после исключения транспорта и с внешним значением | (а)(б) строгий UTF-8 stdout, без исключения, нет `Cc` (кроме `\n`) и `Cf`, длины ≤ 16/64, JSON валиден; (в) тело 302 не читается, 3xx — 0 байт, 4xx — ≤ cap+1, не 200; (г) `None` после вызова, внешнее значение восстановлено (все — стражи, зелёные) | `TextIOWrapper(errors="strict")`, in-memory сервер; `TestA132Regressions` |

### A2 — политика токенов (Linux; `test_rl_tokens.py`; цикл правок 1 — `test_rl_tokens_fixes.py`)

| ID | Вход | Ожидание | Ловушка / фикстура |
|---|---|---|---|
| A2-01 | `never` × Claude/Codex × {live, expiring, dead, absent, partial, пустой файл в процессе записи} | `snap_cred()` до = после (байты, mtime_ns, ino); `/oauth/token` 0; usage — только в live; статусы по таблице §E: `ok` / `expired`+`cli_refresh_pending` с прежними значениями и `asOf` / `expired`+`signin_required` / `signed_out` без значений / `error` | `RLEnv`, `TrapTransport`; `common.http` = запрет |
| A2-02 | `never`, `_PENDING[p]` искусственно непуст, вызов `_save_*` и `_rewrite_json` напрямую | файл не тронут, `policy_violation` в O1, результат `error/credentials`; `deadRefresh`/`deadCodexRefresh` не меняются | Ledger записей файлов |
| A2-03 | `never` + путь replay `_PENDING` из `fetch_claude`/`codex_access_token` | guard срабатывает **до** replay: файла нет в Ledger записей, `_PENDING` не наполняется | — |
| A2-04 | `set_credential_write()`: (a) замок `quota` держит другой процесс; (b) маркер `rotation-pending-<p>` с живым pid; (c) с мёртвым pid; (d) живой pid, но boot-id прошлой загрузки | (a) ждёт ≤ 60 с (инжектированное время), затем отказ; (b) отказ с текстом про ротацию; (c) и (d) маркер мёртвый (в (d) pid переиспользован, решение Юрки 2026-10-13): удалён, смена прошла | реальный `flock` во временном каталоге + дочерний процесс, держащий замок |
| A2-05 | `publisher: true` + `credential_write: guarded` в `settings.json` | действует `never`, событие `policy_forced_never`, строка в `status` (П3-в, v2 §E) | — |
| A2-06 | guarded-регресс: существующие `test_manual_refresh.py` (стр. ~444–625: `_PENDING`, перечитывание, `deadRefresh`) | зелёные с явным opt-in `guarded` в `SyntheticCase.setUp` (2 строки: `common.credential_write` → `"guarded"`, заглушка `accounts.read_local_id`; решение Юрки 2026-10-13), ожидания не меняются; по умолчанию на любой машине действует `never`, `guarded` — только явный opt-in со строкой в `status` (Т33, v2 §E; PRD S1 подтверждено владельцем 2026-10-12) | — |
| A2-07 | `guarded`-воркер с непустым `_PENDING` + смена настройки + штатный выход | пара дописана **или** `pending_rotation_lost` в O1; файл CLI не испорчен (sha = одна из двух валидных пар) | `RLEnv` |
| A2-08 | usage и `/oauth/token`: ответ 302 на чужой хост | запрос на чужой хост не ушёл, `Authorization` за пределы исходного хоста не вышел, попытка = `error/http` | `TrapTransport` |
| A2-09 | Т9 в редакции «единое правило»: `settings.json` меняется между попытками; смена во время попытки (замок `quota` занят); `credentials --write` при непустом `_PENDING` / маркере ротации с живым pid | политика читается в начале **каждой** попытки под `file_lock("quota")` (CLI, издатель, трей одинаково) — новая действует со следующей попытки, никогда с середины; смена — только под тем же замком и только при пустом `_PENDING` и без живого маркера, иначе отказ | Ledger: чтение политики после захвата замка, до запроса |
| A2-10 | Codex, `never`, refresh есть: (a) JWT `exp` прошёл ровно сейчас (без запаса); (b) `exp` в (now, now+60] | (a) 0 запросов, `expired` + `cli_refresh_pending`; (b) = live (решение Юрки 2026-10-13): 1 usage, refresh нет; usage 401 → `expired` + `cli_refresh_pending`, `deadCodexRefresh` не ставится | `FakeClock` |
| A2-11 | П2-в: live-попытка Claude/Codex; во время запроса к провайдеру другой процесс меняет `~/.claude.json` / `auth.json` на другой аккаунт; у Codex `account_id` в файле в смешанном регистре (`ACCT-Fixture-0001-aaaa`) | `LimitData.account` = нормализованный id, снятый **до** запроса (Codex — то же чтение `auth.json`, что и токен: 1 чтение до запроса); **`chatgpt-account-id` = `tokens.account_id` из файла как есть, без strip/lower** (цикл правок m5/N7, решение Юрки 2026-10-13; было «= `account`»); нет `~/.claude.json` → `None` | `Trap.on_call` подменяет файл |
| A2-12 | M1/N1, `guarded`, Claude и Codex (`fetch_claude`, `codex_access_token`, `codex_usage_live`, `fetch_codex`), access истёк; маркер ротации не пишется: `STATE_DIR` 0500 (`quota.lock` есть) / нет `boot_id` (`ENOENT`) / `boot_id` не той формы (`ValueError`); две попытки подряд. Страж: POST дал 400 / сеть (0) / 200 | маркер пишется **до** POST: POST `/oauth/token` = 0 (refresh не потрачен), usage 0, `failure_kind = credentials`, исключение наружу не выходит, файл входа не тронут, `_PENDING` пуст, маркера нет, `deadRefresh*` не ставится. Страж: после POST без пары и после успешной записи маркера нет, `_PENDING` пуст | сбой на границе ОС: права каталога, подмена `os.open`/`open` только для `/proc/sys/kernel/random/boot_id` |
| A2-13 | N2: (a) свой маркер; (b) живой дочерний guarded-процесс B с незавершённой ротацией (настоящий путь) + процесс A со своей; CLI перелогинился, A снимает свою ротацию; потом B завершается без flush; (c) маркер живого B с boot-id прошлой загрузки | (a) имя `rotation-pending-<p>-<pid>`; (b) маркер B переживает уборку A, свой маркер A снят; `set_credential_write` и `credentials --write never` отказывают, пока B жив; после смерти B маркер удалён, смена прошла; (c) маркер удалён, смена прошла (страж) | дочерний процесс через настоящую ротацию, держится до EOF stdin |
| A2-14 | m1/N5: `quota` держит другой процесс дольше предела ожидания; файлы входа live; Claude и Codex (4 точки входа) | ожидание > 0 и ≤ 60 с (инжектированное время); `failure_kind = busy`, `auth = ok` (не `readError`), `expired_reason = None`, `poll_failed`, не `api_fresh`; текст ошибки без слов про вход/файл входа; 0 запросов; файлы не тронуты | реальный `flock` в дочернем процессе, `FakeClock` |
| A2-15 | m2: `quota.lock` не открывается (`chmod 000` → `PermissionError`); `ccl-sync credentials --write guarded` / `never` при том же сбое и при незаписываемом `settings.json` (каталог 0500) | `fetch_*`/`codex_access_token` возвращают ошибку (`credentials` или `busy`), не бросают, 0 запросов, файлы не тронуты, текст без имени/текста исключения; CLI — код ≠ 0, человеко-читаемая строка без traceback, настройка не сменилась | права файла/каталога в песочнице (под root — skip) |
| A2-16 | m4: маркер живого чужого процесса повреждён — `{`, `{}`, symlink (`ELOOP`) | fail-closed: отказ, файл не удаляется сам; текст исключения и CLI называет полный путь маркера и способ восстановления (остановить трей/издатель, удалить файл), не советует повторный вход CLI; код CLI ≠ 0, без traceback | дочерний процесс-владелец, порча его маркера |
| A2-17 | m5/N7: Codex live, `never` и `guarded`; `account_id` = `ACCT-Fixture-0001-AAAA` / с пробелами по краям / UUID в верхнем регистре; вне формы после нормализации: длина 7, 65, `_`, `.`, `+/=` | заголовок `chatgpt-account-id` = значение из файла как есть; `LimitData.account` = нормализованное; вне формы → `account = None`, usage-запрос идёт, `auth = ok`, не `loggedOut`, значения не сбрасываются | `Trap` |
| A2-18 | m7: `publisher: true`, `ccl-sync credentials --write guarded`; страж — без `publisher` | вывод называет действующую `never` и что издатель переопределил `guarded`; код 0; `credential_write()` = `never`. Страж: без издателя — «guarded», без пометки издателя | — |

**Уточнения A2 (tester, 2026-10-13; тесты `linux/tests/test_rl_tokens.py`, API — в шапке файла).**
- **API, не зафиксированный v2/plans (выбран tester-ом):** `common.credential_write()` — действующая политика, перечитывает `settings.json` при каждом вызове (`publisher: true` + `guarded` → `never` + O1 `policy_forced_never`); `common.set_credential_write(value)` + исключение `common.CredentialPolicyRefused`; маркер `STATE_DIR/rotation-pending-<p>` (формат содержимого — за разработчиком, тесты создают маркер только настоящим путём ротации); `LimitData.expired_reason` ∈ {`cli_refresh_pending`, `signin_required`} (ключ контракта `expiredReason`); `LimitData.account`; `limits.flush_pending()` — штатный выход guarded-процесса; O1 = `STATE_DIR/publisher.jsonl`, имя события в `ev` (как в plan-claude O1); `_save_*` в `never` → `"refused"`; CLI `ccl-sync credentials --write never|guarded`; строка `status` «Политика токенов: …» / «Token policy: …».
- **Кто берёт `quota`:** попытка в `limits` сама берёт `file_lock("quota")` (с пределом ожидания), если поток его ещё не держит; вложенный блокирующий захват в том же потоке = deadlock (flock на новый fd) — тест ловит это как отказ, а не зависание.
- **Состояния A2-01:** `partial` = обрезанный JSON, `empty` = файл 0 байт → оба `error` (класс `credentials`) после ≥ 5 чтений (§E «5×0,2 с»); файл, дописанный на 3-м чтении, читается. Claude `expiring` включает `expiresAt` = now+60 с (< 2 мин) — 0 запросов в `never`.
- **A2-08 расширен по T2-r2 R1:** 302 на чужой хост **и** на тот же хост — для usage и `/oauth/token` Claude и Codex; тело 3xx не дренируется (≤ cap+1), бесконечное тело 200/500 читается ≤ 16 МиБ + 1; вызовы `common.http` идут с `follow_redirects=False` и `max_body` ≤ 16 МиБ; `update.fetch_deb`/`apply` — `max_body` ≤ `MAX_DEB`/`MAX_TARBALL`. Токен-эндпоинт проверяется в `guarded` (в `never` POST нет).
- **A2-06 (решено Юркой 2026-10-13):** в `test_manual_refresh.py` добавлены 2 строки в `SyntheticCase.setUp` (явный `guarded` через `mock.patch.object(..., create=True)` и заглушка `accounts.read_local_id`), больше файл не менялся. Чтобы этих строк хватило, реализация: маркер и boot-id — через `os.*`, не `open`/`write_atomic`; повтор чтения Claude — своим циклом с `open`, не `_read_json_retry`; политика — только через `common.credential_write()`.
- **Т9:** действует редакция plan-synth (политика в начале каждой попытки); формулировка T1 §6 «при старте процесса» устарела (решение Юрки 2026-10-13).
- **Цикл правок 1 (tester, 2026-10-13; `linux/tests/test_rl_tokens_fixes.py`, контракт — в шапке файла).** Источник: `docs/review-remote-limits-a2.md` (M1, m1, m2, m4, m5, m7), `docs/security-remote-limits-a2-t2.md` (N1, N2, N5, N7), `docs/plans.md` §A2 «Ревью A2». Выбрано tester-ом: занятый `quota` → `failure_kind = "busy"` при `auth = ok` (новое значение рядом с network/http/auth/credentials/invalid_response); сбой открытия `quota.lock` → `credentials` или `busy` (оба приняты); повреждённый маркер = содержимое не разбирается или symlink, имя файла с живым pid не делает его читаемым. Правки старого файла: помощник `markers()` принимает оба имени маркера (`rotation-pending-<p>` и `rotation-pending-<p>-<pid>`), A2-04/A2-07 и проверки «маркера нет» в A2-01…A2-03 переведены на него (ожидания те же); A2-11 Codex — новое ожидание заголовка (m5/N7). Не в этом цикле: N3, N4, `flush_pending` у издателя (A3); N5-текст панели, N6/m3, D1 (B1); N8 (A4).

### A3 — ядро издателя и координация (Linux; `test_rl_coordination.py`, `test_rl_publisher.py`, `test_rl_sim.py`)

**A3-01 `decide` (pure, `decide-vectors.json` общий с C4-04).** Векторы вход → `poll | skip(reason)`: (a) чужая `attemptAt` 959 с назад → `remote_attempt`; 961 с → `poll`. (b) чужой `asOf` при I = 900: `now − asOf` = I+59 → `fresh_remote`; I+61 → `poll`; то же при I = 14 400. (c) свой `server_until` > now → `retry_after`. (d) тай-брейк: чужой `nextAt` в ±60 с, `lastSeenAt` ≤ 15 мин, младший `machineId` → пропуск один раз, `tie_wait` запомнен; та же пара второй раз → `poll`; источник мёртв (`lastSeenAt` 16 мин) → без тай-брейка. (e) неудачная чужая попытка (`status: error`) тоже держит 960 с. (f) Т23: чужой `asOf`/`attemptAt` = now+30 с → пропуск; now+10 мин, 2099, мусор, отсутствует → **не** свежий (`poll`); (g) Т25: чужая запись с `lastSeenAt` старше 30 мин не подавляет дольше `I_мой`; (h) Т31: чужой `retryUntil` = now+1 ч → ждём; now+10 лет → ждём до `firstSeenAt + 24 ч`, затем `poll` и `remote_retry_capped`; свой `server_until` = now+48 ч → ждём 48 ч, не режется; (i) инварианты И1–И4 T1 §П7 — свойство-тест (fuzz 10⁴ случайных чужих записей, seed фиксирован): `decide` никогда не даёт `poll` там, где одиночный Auto не дал бы (чужое только откладывает). Ledger не нужен: функция чистая, но импорт под запретом сети.

| ID | Вход | Ожидание | Ловушка / фикстура |
|---|---|---|---|
| A3-02 | due-продукт, gist доступен, провайдер 200 | Ledger строго: запись `state.json`/`publisher-state.json` (`attemptAt`) → GET → **PATCH №1 с этим `attemptAt` в теле** → запрос провайдера → PATCH №2 с `status: ok`, новым `asOf`. Всего ≤ 1 GET + 2 PATCH | `Ledger.seq`, `FakeGist`, `FakeProvider` |
| A3-03 | PATCH №1: 500 / сеть / 404 / таймаут | 0 запросов провайдера; `poll_skipped publish_failed`, `publish failed`; `last_attempt` в `state.json` восстановлен (байты = до прохода); следующий тик повторяет PATCH №1 | Ledger |
| A3-04 | `labelReason` = `unreadable` / `no_login` / `no_gist` | 0 запросов; `poll_skipped no_label` / `no_login` / нет опроса (P6); статус `error` / `signed_out` | — |
| A3-05 | нет входа в GitHub / вход отозван | `poll_skipped no_github` на оба продукта, Ledger пуст (и GET тоже) | — |
| A3-06 | GET gist не прошёл (5xx/сеть), продукт due | запрос провайдера **есть** по своему расписанию (B1), PATCH нет; блок уходит первым же удачным проходом (проверка тела PATCH) | `FakeGist` сбой GET |
| A3-07 | показание 5 мин назад, I = 900: новый процесс (state с диска), «перезагрузка» (`OnBootSec`), тик таймера | Ledger без запросов провайдера на каждом варианте (011: проверяется Ledger, не только `not_due`) | `FakeClock`, пересоздание модулей |
| A3-08 | провайдер 429 `Retry-After: 3600`; затем тики каждые 5 мин и `--now` | 0 запросов до +3600 (граница ±1 с); `retryUntil` опубликован; `Retry-After` 48 ч сохранён целиком (свой, без потолка) | `FakeProvider` |
| A3-09 | Т31: тот же чужой `retryUntil` = now+10 лет перечитывается каждые 5 мин, 3 рестарта процесса | ожидание кончается ровно в `firstSeenAt + 24 ч` (`firstSeenAt` на диске); `server_until` и `AutoPollState.serverRetryAt` чужим не тронуты | `RLEnv`, рестарт |
| A3-10 | B3: `OSError` при сохранении попытки (диск полон) | 0 запросов, `poll_skipped state_unsaved`, ошибка видна в `status` | подделка `write_atomic` |
| A3-11 | Т34: остановка (исключение-«kill») после durable `begin`; после отправки запроса; перед PATCH №2 | новый процесс через 60 с и через 899 с не шлёт повторный запрос; блок уходит в первый удачный цикл | `FakeClock`, рестарт |
| A3-12 | 401 после успеха час назад | статус `expired`, значения и `asOf` прежние (C3) | — |
| A3-13 | Т29: идентичность A→B→A во время HTTP (файл подменяется в колбэке `FakeProvider`) | ответ A не применяется к B; 429 A не ставит `retryUntil` B; возврат в A сохраняет его бюджет, `retryUntil`, последнее хорошее показание; fallback между аккаунтами запрещён; новый аккаунт без значений до первого успеха (№3) | колбэк провайдера; событие `identity_changed` (v2 §B) |
| A3-14 | правило записи: (a) расход изменился через 300 с после PATCH; (b) изменились только метаданные; (c) ничего не изменилось 600 с; (d) два не-due тика подряд в 600 с; (e) due-тик | (a) PATCH нет до 570 с; (b) PATCH сразу; (c) heartbeat-PATCH, меняется только `lastSeenAt`, не `asOf`/попытка/интервал/наблюдения Auto; (d) 0 PATCH — нет самоподдерживающейся записи; (e) ≤ 1 GET + 2 PATCH, иначе ≤ 1 GET + ≤ 1 PATCH | Ledger, diff тел PATCH |
| A3-15 | `ccl-sync publisher --now` (ручной): своя попытка 899/900 с; чужая `attemptAt` 959/960 с; `retryUntil` действует | ровно 1 запрос только при (≥ 900, ≥ 960, нет `retryUntil`); иначе только чтение gist и «опрос можно с HH:MM» = max(своя+900, чужая+960, `retryUntil`) | Ledger |
| A3-16 | `open_cycle/write`: два PATCH в пределах 120 с после одного GET; > 120 с; PATCH 404; gist стал `public: true` | один GET обслуживает два PATCH; после 120 с нужен новый GET; 404 → сброс id/хеша, без discovery внутри `write`; публичный → записи нет | `FakeGist` |
| A3-17 | журнал O1 и state: umask 022 | `publisher.jsonl` 0600, каталог 0700; ротация > 1 МБ атомарна, старше 45 дней отброшено; поля только из перечня (allow-list событий и причин `poll_skipped` §C); исключение транспорта → класс, текста нет; сканер A1-10 по журналу и `publisher-state.json` чист (Т5, Т12, Т21, S5) | `os.stat`, сентинели |
| A3-18 | `Date` GitHub со сдвигом 0 / ±59 / ±120 с | `clockSkew` сохранён; > 60 с → событие `clock_skew` с секундами, строка в `status`; ≤ 60 → события нет | `FakeGist.skew` |
| A3-19 | Т27: замок `sync` держит «трей» (дочерний процесс) 40 с / 70 с; `quota` занят > 30 с | ждёт `sync` ≤ 60 с и читает gist (40 с); 70 с → «gist не прочитан» по правилу P6; `quota` занят → `pass_skipped busy`, Ledger пуст | реальный `flock`, инжектированный таймаут |
| A3-20 | **Симулятор двух машин** (`TwoMachineSim`, 24 ч виртуального времени; сетка: I ∈ {15 мин, 4 ч} × задержка видимости gist {0, 30 с, 5 мин} × skew {0, ±59 с}; фаза таймеров 0…299 с, seed фиксирован) | (a) установившийся режим: **0 пар < 900 с** по метке; GET/PATCH на машину ≤ таблицы бюджета §C; (b) простой 12 ч на одной машине → интервал 4 ч, ≤ 10 запросов/сутки; (c) Т24: fuzz чужих файлов → мои запросы ≤ одиночного Auto; при мусорных/будущих чужих полях ≥ 1 запрос за `max(I, 24 ч)`; (d) Т32: события «старт», «смена входа», «Auto упал до 15 мин», «выровненные тики» → **≤ 1 пара на событие**; простой gist 3 ч → ≤ 1 пары на 15 мин простоя, восстановление ≤ 1; перевод часов назад + рестарт не обходят пол 900 с; повторяющийся тай-брейк задерживает ≤ 1 тика; (e) skew ±120 с: гарантия не заявляется, тест только фиксирует, что `clock_skew` записан и пары < 900 с ≤ 1 на событие | `_rl_sim.py`; отчёт симулятора: пары, GET/PATCH, события |
| A3-21 | `run_pass` при любом неожиданном исключении (подделка бросает `KeyError`, `ValueError`) | проход завершён, замок снят, в O1 класс события без текста; следующий тик работает | — |

### A4 — установка и `status` (Linux; `test_rl_install.py`)

| ID | Вход | Ожидание | Ловушка / фикстура |
|---|---|---|---|
| A4-01 | `sh linux/install.sh --publisher --no-tray --name vps` во временном HOME, подменный `systemctl` в `PATH` | юнит без env/токена в `ExecStart`, `OnUnitActiveSec=5min`, `OnBootSec=2min`; нет `.desktop`/autostart; `settings.json` = `{publisher: true, autoPoll: true, credential_write: "never", machineName: "vps"}`; `XDG_RUNTIME_DIR` выставлен, только если каталог есть | записи подменного `systemctl` |
| A4-02 | `install.sh --publisher` при запущенном процессе трея (подменный `pgrep`) | **отказ, rc ≠ 0**, напечатана команда остановки трея; юнит не установлен, `settings.json` не изменён | подменный `pgrep`, `systemctl` |
| A4-03 | `ccl-sync status`: нет входа; `busy`-замок; полный диск; ESC в чужом `machine.name` | на продукт: подпись, попытка/вид, успех, режим/интервал, следующая попытка, `retryUntil`, класс ошибки, счётчики 24 ч, `clockSkew`; чужие аккаунты со свежестью; печатаются политика `credential_write` и путь state-каталога; сканер A1-10: нет токена, email, текста исключений, ESC | сентинели |
| A4-04 | Т28: два процесса с разными `XDG_STATE_HOME` | `status` и трей печатают разные пути; тест-детектор сообщает «два state-каталога» (требование установки задокументировано) | два `RLEnv` |
| A4-05 | `python3 -I` с блокировкой импорта `PyQt5`/`dbus`/`secretstorage` → `ccl-sync push --auto` с издателем | проход отрабатывает, ни один из модулей не импортирован (P1) | `sys.modules[...] = None` |
| A4-06 | CLI: `publisher --enable/--disable/--products/--mode fixed 3600/--status`, `credentials --write never|guarded` | настройки меняются только через замок; `--mode` принимает только 900/1800/3600/14400 | — |
| A4-07 | `test_deb.py` | зелёный без изменений (`.deb` не меняется) | существующий |

### A5 — выкатка на VPS (ручная, раздел 3)

### B1 — трей Linux в режиме `delegated` (offscreen; `test_rl_tray.py`)

| ID | Вход | Ожидание | Ловушка / фикстура |
|---|---|---|---|
| B1-01 | Т26: таймер-издатель + трей `delegated`, 2 ч виртуального времени, клик «Обновить» каждые 10 с, активность в транскриптах | ≤ 1 запроса на аккаунт за любые 15 мин; попытка сохранена до HTTP; `OSError` → запроса нет | `TrapTransport`, `FakeClock`, без `TrayApp`-синка (006) |
| B1-02 | `on_activity` в `delegated` | `state.json` по sha/mtime не изменён; `save_poll_states` — no-op | `snap` state |
| B1-03 | циклы синка трея в `delegated` | 0 PATCH от трея (`allow_push=False`) | Ledger |
| B1-04 | П8-в: двойной клик, клик во время прохода | второй воркер не стартует (`in_flight`/`delegated`) | Ledger |
| B1-05 | не-делегированная машина: воркер трея | берёт `quota` на `fetch + apply` (≤ 10 с, иначе `poll_skipped busy`); попытка сохраняется до `Thread.start` | Ledger записей |
| B1-06 | Т17: строки снимка (`machine.name`, подпись) с `<img src="http://…">` в виджетах трея | вывод `PlainText`/`drawText`; HTML не интерпретируется; сетевой загрузки нет | `common.http` = запрет; проверка `textFormat()` |

### B2 — Linux-трей publish-only

| ID | Вход | Ожидание | Ловушка / фикстура |
|---|---|---|---|
| B2-01 | трей с локальным Codex, `publisher: false` | в файле машины блок Codex той же формы, что у издателя (A1-10 сканер чист); политика по умолчанию `never` (П3-д) | `RLEnv`, `FakeGist` |

### C1 — macOS: merge v1.1 и резолвер (`--sync-selftest`, `now` явный)

| ID | Вход | Ожидание | Фикстура |
|---|---|---|---|
| C1-01 | `label-vectors.json` | те же метки, что A1-01 (паритет Python ↔ Swift) | `RemoteLimitsFixtures.swift` |
| C1-02 | `machine-v11-hostile.json` + генератор (как A1-13/A1-14): (a) `pct` строка/bool/140/`1e400`; (b) даты; (c) объёмы; (d) проекция; (e) Т36: `resetAt`/`asOf` с годом 99999, `+99:00`, дробью 10⁶ знаков; пределы тел 9/20 MiB, 100 файлов | без падения; поля отброшены, карточка рисуется; суммы `days` = файл без блока; лишняя проекция → «не указан» | golden |
| C1-03 | `machine-v11.json` vs `machine-v10.json` через существующий `GitHubSync.merge` | равные `days` (C1) | golden |
| C1-04 | `resolver-vectors.json`: один Codex на маке и VPS; два разных; Claude только на VPS; неудачный снимок новее успешного; равный `asOf` | одна карточка `Codex · mac, vps`; две; V3 = max `asOf`, при равенстве локальный; неудача не вытесняет успех, но её статус в V5; порядок V2 | golden |
| C1-05 | старая 0.4.5 с расходом Codex без метки | группа V7 без `AccountView`-карточки; суммы известных аккаунтов не изменились | golden |
| C1-06 | V5 с `now`: каждое из 7 состояний отдельно и попарные пересечения | приоритет 7 > 6 > 5 > 3 > 4 > 2 > 1; `freshUntil = (nextAt ?? asOf+I) + 20 мин` (граница ±1 с); Auto 4 ч, `asOf` 3 ч 50 мин, `lastSeenAt` 5 мин → 1; `lastSeenAt` 40 мин → 5; без `lastSeenAt` → по `updated`; 7 (`off`/`revoked`/`awaitingCode`) → удалённых `AccountView` **нет** (№14) | golden + `ReaderSyncState` |
| C1-07 | старый `sync-remote.json` без `lastSeenAt`/`accounts` | декодируется, `nil`-поля; `asOf` в будущем > 5 мин → возраст 0, темп не считается | — |
| C1-08 | `machineTag()`: векторы `sanitize-vectors.json` (тег мака по умолчанию владельца — `macbook`) | те же результаты, что A1-11 | golden |

### C2 — macOS: настройки, деньги, история (`--subscriptions-selftest`)

| ID | Вход | Ожидание | Ловушка |
|---|---|---|---|
| C2-01 | `monitor_claude = false`, чужие `asOf` Claude из gist | темп и история по `acct` (метка) считаются; переписанный селфтест ~7108: «remote usage of a visible account survives a disabled local poll»; `fetchClaude()` не читает Keychain | счётчик Keychain/helper = 0 (013) |
| C2-02 | tier `max_20x` / `max_5x` / `pro` / нет tier; локальный `claudeTier = max_5x` | $200 / $100 / $20 без «оценки»; без tier — запасной с «оценкой»; локальный tier к чужому не применён | — |
| C2-03 | два Codex-аккаунта | раздельные дни, календарь, деньги; общая сумма не выдана за один аккаунт | — |
| C2-04 | история: строка без `a`; дубль `(acct, t)`; локальный ключ после смены gist | `l:legacy`; дубль не пишется; локальный `l:`-ключ не меняется | — |
| C2-05 | миграция N3: прежний `productEnabled(claude) = false` | «опрос выключен», `hiddenAccounts` пуст, диалогов нет; карточка VPS видна после входа в GitHub; 0 запросов к Anthropic | Keychain-счётчик 0, транспорт-ловушка |
| C2-06 | `hiddenAccounts = {метка}` | нет в карточках, строке меню, расходе; тело PATCH файла мака не изменилось от скрытия | Ledger PATCH |
| C2-07 | `menuAccount`: по умолчанию; выбранный скрыт или пропал | локальный, иначе первый по V2; при пропаже — снова по умолчанию | — |
| C2-08 | `reader_card_state` (PRD §5): успешный синк с 3 видимыми аккаунтами в разных состояниях V5; скрытый аккаунт; синк `.failed` | в `poll-log.jsonl` по строке на видимый аккаунт: метка, состояние V5, возраст показания; скрытого нет; при `.failed` строк нет; сканер A1-10 чист; файл 0600 | записывающий журнал, сентинели |

### C3 — macOS UI (`--subscriptions-selftest` + PNG)

| ID | Вход | Ожидание | Фикстура |
|---|---|---|---|
| C3-01 | Т16 + 012: карточка без входа в 3a/3b/2/5 и `error`; `caption` = `javascript:…`/`file://…` | `limitCanFix(remote:) = false`; hit всегда `open:<константный URL продукта>`; нет `claude login`, `claude → /login`, «Как починить?», `claudefix`, бейджа «вход истёк»; поле снимка в URL нет | golden |
| C3-02 | строки V5 (1–7, 3a/3b) и фазы ручного обновления × RU/EN × узкая/широкая | тексты байт-в-байт по UX §4; полный текст в tooltip и AX value; amber только 3–5, `ADV_LINK` в 6–7; время/дата не обрезаются | таблица ожиданий из UX |
| C3-03 | Claude только с VPS, 10 мин назад | Simple `Claude · vps`, Advanced `Claude Code` + `Max 20x` + `· vps`; строка 1 `Данные с vps от HH:MM`; в Advanced темп, прогноз, $200 | — |
| C3-04 | `snapshotHorizon` в трёх точках (`metricIsStale`, `advVerdict`, `isStale`) | Auto 4 ч / 3 ч 50 мин → не stale во всех трёх | `now` |
| C3-05 | `asOf` 10:00, сброс 11:00, now 11:20; `asOf` в будущем > 5 мин | `окно сброшено`, кольцо серое; «Нет свежих данных · темп не считаем» | `now` |
| C3-06 | Simple с 1/2/3/4 карточками; Advanced | высота карточки без входа = локальной (0 pt разницы); 3 → 2+1 широкая, окно 544 pt (с модельной строкой); 4 → 2+2; нет наложений шкалы/авторства | геометрия + PNG |
| C3-07 | футер Auto: 0 / 1 локальный аккаунт + чужие | подсвечены только локальные; при 0 — `noSubscriptions` с новым текстом | — |
| C3-08 | строка меню: состояния 2/3/5/6/7 и 4 при свежем | тусклые числа (альфа 0,4) в 2/3/5/6/7; 4 — обычные; tooltip кнопки = подпись + источник | — |
| C3-09 | Настройки: `ОПРАШИВАТЬ НА ЭТОМ КОМПЬЮТЕРЕ`, «Аккаунты» (правка 32, Enter/Esc/Сбросить), GitHub в Simple, ссылка V10 без входа | блоки и строки по UX §9 | — |
| C3-10 | **PNG-превью** (детерминированные, `now` фиксирован): 7 состояний × RU/EN × Simple узкая/широкая/Advanced; фазы ручного обновления; 3 и 4 карточки; два Codex / один на двух машинах; меню и настройки | файлы и манифест SHA; дальше визуальная приёмка (раздел 3) | `previewDir` во временном каталоге |
| C3-11 | Т14 у читателя: подписи/модели с управляющими, bidi, 10 000 символов, `%@%n` | выведены как текст ≤ лимита; статическая проверка: `String(format:)` не получает строк снимка (grep-тест по `RemoteLimits.swift`) | golden |

### C4 — macOS: издатель и B2 (`--sync-selftest`)

| ID | Вход | Ожидание | Ловушка |
|---|---|---|---|
| C4-01 | локальный Codex-вход (синтетический `auth.json` во временном каталоге) | `machineFile` содержит блок Codex с меткой; `cache.json[p].accountId` = `localId` | — |
| C4-02 | due Codex, метку публикует и VPS | порядок: `syncNow(.full)` → `decide` по кэшу **из исхода** → `begin`+`saveAutoStates` → PATCH (`.writeOnly`, `attemptAt` в теле) **до** вызова `fetchCodex` → PATCH результата | записывающий транспорт + счётчик `fetchCodex` с `seq` |
| C4-03 | PATCH попытки упал; `.failed` чтения; нет completion 60 с | `fetchCodex` не вызван, `lastAttempt` восстановлен, `publish_failed`; `.failed`/таймаут → своё расписание (B1); каждый ранний `return` в `syncBody` даёт `.failed` (перебор инжектированных отказов) | — |
| C4-04 | `decide-vectors.json` | те же решения, что A3-01 (паритет) | golden |
| C4-05 | VPS опубликовал `retryUntil` +1 ч для общей метки | мак не опрашивает до срока, в т. ч. ручным (RL-9) | — |
| C4-06 | ручное «Обновить»: Claude без входа; Codex со входом, VPS опросил 5 мин назад; чужая `attemptAt` свежая / `asOf` старый / `status: error`; ≥ 900/960 с без `retryUntil` | только чтение gist (защита 30 с), «Опрос можно с HH:MM» (UX §4 (а)); 0 запросов до 900/960 с; в последнем случае ровно 1 запрос | транспорт-ловушка |
| C4-07 | Т11: `credentialWrite = never` | `codexAccessToken()` → `expired/cli_refresh_pending`, 0 POST, `auth.json` sha/mtime тот же; `persistClaudeQuotaUpdate` не вызван (ловушка helper); `legacy` — запись атомарна и только при совпадении пары, фикстура «CLI успел переписать» → `superseded`, файл CLI цел | запись helper, `snap` файла |
| C4-08 | `.writeOnly` при валидирующем чтении > 120 с назад | отказ без PATCH | — |
| C4-09 | файл мака + `poll-log.jsonl` | сканер A1-10 чист; журнал 0600 | сентинели |
| C4-10 | Т35 регресс: 302 на чужой хост для usage/oauth | не следуем (`noRedirects`), `error/http` | — |
| C4-11 | `Date` со сдвигом ±120 с | `clockSkew` сохранён, подсказка «часы расходятся…» | — |

### C5 — подписи и список N1 (Should)

| ID | Вход | Ожидание | Ловушка / фикстура |
|---|---|---|---|
| C5-01 | две машины пишут `captions` для одной метки с разным `setAt` | побеждает поздний `setAt` на обоих портах; Linux-читатель видит подпись, заданную на маке (RL-2) | golden, `FakeGist` |
| C5-02 | ввод подписи: 33 символа, перевод строки, управляющие, `@`, `/`, пусто, «Сбросить» | обрезка до 32 / отброшено / отклонено / подпись по умолчанию | селфтест |

### C6 — релиз и замер

| ID | Вход | Ожидание | Ловушка / фикстура |
|---|---|---|---|
| C6-01 | синтетические журналы O1 двух машин: пары 899/900 с, окна `publish failed`, `label_changed` посреди окна | редьюсер G1 считает пары по метке, сшивает метки по `label_changed`, периоды «gist недоступен» выделяет отдельно; G2 = число `token_refresh` с записью | `tools/` скрипт сведения + pure-тест |

**Итог по числу тестов (ID; многие ID — табличные под-кейсы):** A1 — 15 · A2 — 18 (A2-01…A2-18; прежнее «10» не учитывало A2-11) · A3 — 21 (A3-01 ≈ 30 векторов, A3-20 — сетка 2×3×3 + события) · A4 — 7 · B1 — 6 · B2 — 1 · C1 — 8 · C2 — 8 · C3 — 11 · C4 — 11 · C5 — 2 · C6 — 1. **Всего 109 ID**, из них Linux 69 (+1 общий C5-01), Swift 39; плюс ручные проверки A5 и визуальная приёмка C3/C6.

## 3. Ручные проверки (Юрка) и визуальная приёмка

**A5 — VPS после среза A** (T1 §7 + гейт v2 §G A5). Записать в `docs/remote-limits-verification.md`:
1. `stat -c '%y %s %i' ~/.claude/.credentials.json ~/.codex/auth.json` до включения издателя и через 24 ч. Изменения есть только там, где их объясняет работа самого CLI (сверить с активностью команды). В O1 `credentialWrite = 0` (журнал того же UID сам по себе не доказательство).
2. Файл машины VPS в gist глазами: тег `vps`, нет имени, хоста, UUID кроме `machine.id`, email, путей. Плюс сканер A1-10, прогнанный по скачанному файлу.
3. `journalctl --user -u ccl-sync --since -24h`: нет токена, email, тел ответов.
4. Старый трей на `:20` остановлен **до** `install.sh --publisher`; после установки `ccl-sync status` и трей показывают один путь state-каталога.
5. Риск 1 по замеру Юрки снят (`history` в ответах — 30 последних ревизий). Контроль: размер ответа `GET /gists/{id}` до и после суток не растёт сверх ~60 КБ на три файла. Решения по пересозданию gist (П4-б) и `chmod 700 ~/.codex` (П6-б) остаются за владельцем.
6. 24 ч журнала: G1 — 0 пар < 900 с, ≤ 10 запросов в простой, 0 × 429; G2 — 0 записей; `status` без ошибок; мак 3.2.7 и ThinkPad 0.4.5 по-прежнему суммируют расход VPS (C1 вживую).

**Визуальная приёмка на маке (после C3, через remote-hands).** design-reviewer поэлементно сверяет PNG C3-10 с макетом `design/remote-limits-card.html` и таблицами UX §4/§6/§9 (урок 014: геометрия без PNG-сравнения не считается). Потом Юрка в реальном приложении 3.3.x (окно 360 pt, RU и EN, системный шрифт) проходит UX §11 п. 1, 5, 7, 10, 12, 13. Обязательно: 7 состояний V5 воспроизведены живыми фикстурами gist, строка меню на реальном статус-баре (урок 004), отсутствие Keychain-окон после обновления с выключенным Claude (013 — смотрит человек, тест этого не доказывает).

**C6 — 14 дней:** сведение журналов VPS и мака редьюсером C6-01; 10 ручных сверок свежести владельца (G3); проверка набора карточек и $200 (G4).

## 4. Что НЕ покрывается офлайн и почему

- **Реальные API Anthropic/OpenAI.** Форма usage-ответа, реальные `Retry-After`, поведение `/oauth/token`, 302 — только синтетика. Дрейф формата поймает A5/C6, а не тесты.
- **Реальный GitHub.** Рост `history` ревизий, точность `Date`, задержка распространения записи между репликами, лимиты 500/ч PATCH, поведение `raw_url`. Задержку gist симулятор моделирует числом, а не реальной системой. Поэтому гейт A5 п. 5 ручной.
- **Живые CLI.** Как Claude Code/Codex реально переписывают файлы входа (неатомарность, частота ротации), лаг `oauthAccount` (issue #81231). Фикстуры моделируют только известные состояния. G2 доказывает только 14 дней на VPS.
- **Живой ALSE/ThinkPad и XFCE `:20` на VPS.** Breeze/KWallet/реальная сессия D-Bus, совпадение XDG у systemd и графической сессии, реальный запуск таймера под Linger и `OnBootSec` после перезагрузки. Офлайн проверяются только юнит-файлы и печать путей (A4-01, A4-04). Linux-трей как **читатель** удалённых карточек (RL-21 показ) не входит в milestones v2 — тестов нет.
- **macOS native.** Системные окна Keychain (013), фокус/tooltip/AX в живом окне, реальный статус-бар (004), подпись/Gatekeeper. Селфтесты и PNG дают строки, геометрию и пиксели превью, но не поведение живого AppKit.
- **Атака агента того же UID** (правка кода/юнита/настроек) — принятая граница T1 П3-в; тест A2-05 защищает только от ошибочной настройки.
- **Часы с расхождением > 60 с.** Гарантия B2 не заявляется (v2 §D). Тест фиксирует только журнал и `status`, а не отсутствие пар.
- **G1/G3 как статистика** (≥ 95% времени «свежо», 10 сверок) — только замер C6.
- RL-22 (звуки) и RL-23 (> 4 аккаунтов) — Could, тестов в этой поставке нет.

## 5. Порядок готовности

Milestone закрыт, когда все его ID зелёные, полный Linux-набор и `test_zz_isolation` зелёные, а у Swift-milestone селфтест прошёл на маке после ревью изоляции. A1 → A2 → A3 → A4 → (A5 ручной) → B1/B2 и C1 → C2 → C3 → C4 → C5 → C6. Паритетные тесты (C1-01, C1-08, C4-04) не могут быть зелёными раньше соответствующих Linux-векторов. Это нормально.

## 6. Расхождения и нетестируемое как записано

Сверено с v2 и `docs/plans.md` после решений Юрки 2026-10-12. Закрыты: будущие чужие поля (Т23), потолок чужого `retryUntil` (Т31),
`no_account_uuid` (Т2), Т4 без привязки к поколению, `identity_changed` (Т29), `never` по умолчанию на всех портах (Т33/П3-д, подтверждено
владельцем 2026-10-12), единое правило политики в начале каждой попытки (Т9 → A2-09), отказ установки при живом трее (A4-02), ожидание `sync` ≤ 60 с
(A3-19), пределы читателя в C7 (A1-14, C1-02), `reader_card_state` (C2-08), тег `macbook`, UX строка 7. Остаётся мелкое:

1. **Т24 «≥ 1 запрос за `max(I, 24 ч)`»** противоречит инварианту, снятому в самом T1 П7. В A3-20(c) сужен до мусорных/будущих чужих полей.
2. **Т32 «heartbeat меняет только `lastSeenAt` и хеш»** ↔ v2 №11 (`lastSeenAt` вне отпечатков, свой срок 600 с). A3-14(c, d) — по v2.
3. **Управляющие символы: отбросить или вычистить.** v2 C7 у читателя: строка **отбрасывается**. T1 П4-в/П5-е и `plans.md` A1 у писателя:
   «без `Cc`/`Cf`» (вычистить?). Тесты проверяют инвариант «на выходе нет `Cc`/`Cf`, длина в пределе», а не способ.
4. **UX-примеры** используют `mac` (`Codex · mac, vps`), тег владельца — `macbook`. Тексты C3-02 берутся из UX как шаблон с подстановкой тега.
