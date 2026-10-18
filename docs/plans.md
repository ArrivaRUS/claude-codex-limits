# REMOTE-LIMITS · 2026-10-12

> Источник правды исполнения (скилл execution-pack). Канонические входы: PRD [prd-remote-limits.md](prd-remote-limits.md) (G1, решения владельца 1–7), UX [../design/remote-limits-ux.md](../design/remote-limits-ux.md) (G2b), архитектура [../arch/plan-synth.md](../arch/plan-synth.md) v2 (G4; челлендж Astra 14/14 закрыт), модель угроз T1 [security-remote-limits.md](security-remote-limits.md) (вердикт «можно дальше» при включении П2-в, П3-а/б/в/д, П4-а, П5 а–е, П7, §5). База кода `c950fb1` (macOS 3.2.7, Linux 0.4.5). Тест-план пишет Tester отдельно — [test-plan-remote-limits.md](test-plan-remote-limits.md) (строки Т1–Т36 из T1 §6 и проверки §G synth v2); здесь он не дублируется. Живой статус — [status.md](status.md). Обновлено: 2026-10-12.

## Допущения

1. Решения владельца 1–7 PRD приняты. PM правит PRD до кода: решение 7 — допуск B2 по synth v2 §D (установившийся режим 0 пар · ≤ 1 на событие сходимости · ≤ 1 на 15 мин простоя gist · ≤ 1 на восстановление; «≤ 3 событий/сутки» снято); B6 — чужой `retryUntil` соблюдается не дольше 24 ч от `firstSeenAt`, свой — без потолка (T1 П7); C6 — `lastSeenAt` входит в снимок и пишется по своему 10-мин сроку; A5 — нет метки → запроса нет. UX: строка 7 §4 и §12 — состояние 7 без значений до первого успешного синка.
2. `credential_write: never` — значение по умолчанию на **всех** портах (T1 П3-д); `guarded` (Linux) / `legacy` (мак) — явный opt-in только там, где CLI на машине не используется. Ждёт «да» владельца, планируется как принятое.
3. Теги машин `vps` / `macbook` / `alse` (настройка `machineName`; дефолт — санитизированный hostname, `[a-z0-9-]{1,16}`).
4. Рост ответа gist снят замером 2026-10-12: `GET /gists/{id}` отдаёт только 30 последних ревизий в `history` (56 895 байт при трёх файлах); транспорт v1 не меняется; в A5 — простая проверка.
5. Все тесты офлайн (уроки 006/011): временные `XDG_*` до импорта `ccl` (`linux/tests/_isolate.py`), `common.http`/`sync.transport` — запрещающие заглушки, часы инжектированы; реальные файлы входа, keyring, gist и API не используются; `/usr/bin/security` не вызывается.
6. Сборка и селфтесты macOS — на маке владельца через remote-hands (`tools/remote/codex-job.sh macbook ccl --write`, только Юрка); у Codex на маке нет сети, `git pull` и установка в `/Applications` — владелец.
7. Linux-трей как полноценный читатель/издатель — вторая очередь (решение владельца 6): B2 может идти после среза C без влияния на мак.
8. Граница UID на VPS принята как в v1 (агенты того же пользователя могут править настройки и код); журнал O1 того же UID — не доказательство для G2, поэтому Юрка сверяет `stat` файлов входа руками (A5, T1 §7).

## Команды валидации (допущения: имена новых модулей/фикстур задаёт Tester в test-plan)

```sh
cd /home/yurka/VibeCoding2/2026_06_UsageLimits
# Linux: модули фичи test_rl_*.py (имена — по test-plan; изоляция — _isolate внутри теста; Qt/dpkg-тесты вне CI пропускаются)
QT_QPA_PLATFORM=offscreen PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s linux/tests -p 'test_rl_*.py' -v
# Linux: весь набор локально
QT_QPA_PLATFORM=offscreen PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s linux/tests -p 'test_*.py' -v
# Linux: эталон — Ubuntu CI .github/workflows/linux.yml (контейнер --network none, учётка ccltest) → 0 ошибок, 0 пропусков
QT_QPA_PLATFORM=offscreen CCL_PREVIEW_DIR=/tmp/ccl-previews PYTHONDONTWRITEBYTECODE=1 /usr/bin/python3 linux/tests/_ci_offline.py
# Установщик (A4): временный HOME + подменный systemctl в PATH (каталог подмены создаёт Tester)
HOME=$(mktemp -d) PATH="$PWD/linux/tests/fakebin:$PATH" sh linux/install.sh --publisher --no-tray --name vps
# macOS (на маке через remote-hands): сборка + офлайн-селфтесты
bash build.sh && APP="dist/Claude Codex Limits.app/Contents/MacOS/ClaudeCodexLimits" \
  && "$APP" --sync-selftest && "$APP" --subscriptions-selftest && "$APP" --auth-selftest
# (новые проверки фичи живут в существующих --sync-selftest / --subscriptions-selftest, как в test-plan; нового флага нет)
```

## Порядок вех

| ID | Веха | Зависит от | Статус |
|---|---|---|---|
| A0 | Протокол v1.1, test-plan и правки PRD/UX зафиксированы до кода | synth v2, T1 | [~] |
| A1 | Контракт + идентичность + тег: `accounts.py`, `accountByDay`, фикстуры | A0 | [ ] |
| A2 | Политика токенов `never` по умолчанию, маркер ротации, guard в записи, без редиректов | A1 | [ ] |
| A3 | Ядро издателя: проход, `open_cycle`/`write`, три отпечатка, `coordination.decide`, `clockSkew`, журнал O1, пределы читателя Linux | A2 | [x] `2b9b8b3` (условие N5 → A4) |
| A4 | Установка `--publisher/--no-tray/--name`, таймер 5 мин, `status` O2, отказ при старом трее | A3 | [x] `9dd3bb6` |
| A5 | Выкатка на VPS, 24 ч журнала, ручные сверки Юрки (G1/G2), проверка `history` ≤ 30 | A4, владелец | [ ] |
| B1 | Трей `delegated`: без записей состояния, воркер под `quota`, кнопка → проход | A3 | [ ] |
| B2 | Linux-трей publish-only (вторая очередь) | B1, C1 | [ ] |
| C1 | macOS: merge v1.1, `RemoteAccount`, `ReaderSyncState`, `resolveAccounts`, пределы читателя | A1 | [ ] |
| C2 | macOS: настройки N1–N3, деньги U3, история по `acct` | C1 | [ ] |
| C3 | macOS: UI карточек, состояния V5, строка меню, тег, превью 7 состояний | C2, UX | [ ] |
| C4 | macOS: издатель мака, B2 через `syncNow(completion)`, `credentialWrite: never`, poll-log | C3, A5 | [ ] |
| C5 | Подписи `captions` и список N1 (Should) | C4 | [ ] |
| C6 | Релиз: документация, changelog, T3, 14-дневный замер G1–G4 | C4 (C5 по готовности) | [ ] |

Stop-and-Fix: падение валидации любой вехи останавливает переход к следующей; баг, вернувшийся > 2 раз, — долг процесса (CLAUDE.md HQ, правило 2), урок в `.patches/`.

## A0 — протокол и test-plan до кода `[~]`

Зависит от: synth v2, T1. Файлы: `docs/sync-protocol.md` (раздел v1.1: пример JSON, правила C1–C7, три отпечатка записи, `lastSeenAt`, `attemptAt`, два PATCH после одного валидирующего GET в пределах 120 с, пределы читателя C7 (≤ 64 файлов, ≤ 64 МиБ, тело ≤ 16 МиБ, `isfinite`, чистка строк), смена gist и метки), `docs/test-plan-remote-limits.md` (Tester), правки PRD (решение 7, B6, C6, A5) и UX (строка 7 §4, §12).
Готово, когда: протокол, test-plan и правки PRD/UX закоммичены **до** первого изменения кода (как `f311c4e` в UI-Auto); Юрка сверил каждую строку Т1–Т36 с вехой ниже.
Валидация: `git log --oneline -- docs/test-plan-remote-limits.md docs/sync-protocol.md` показывает коммит раньше любого коммита этой фичи в `linux/ccl` и `Sources`.
T1: документы; правки PRD B6 (П7) и S1 (П3-д).

## A1 — контракт и идентичность `[x]` (2026-10-13, `4a53ebf`)

Зависит от: A0. Файлы: `linux/ccl/accounts.py` (новый), `linux/ccl/usage.py` (`accountByDay`), `linux/ccl/common.py` (`machine_tag()`, `http(max_body=)`), `linux/ccl/sync.py` (разбор блока у читателя, пределы, `_raw` с пределом тела), `linux/tests/fixtures/machine-v11.json`, `machine-v11-hostile.json`, `machine-v10.json`, `sanitize-vectors.json`, фикстура `~/.claude.json` с синтетическими ПДн.
Задачи: чтение `localId` одним парсером, извлекающим **только** `oauthAccount.accountUuid` / `tokens.account_id` (предел 8 МБ, `RecursionError`; `OPENAI_API_KEY` и `id_token` не читаются) — П2-б; `organizationUuid` не используется → `label: null`, `labelReason: no_account_uuid` — П1-а; метка HMAC под gist id **только при сборке блока**, UUID нормализован (нижний регистр, strip) — П1-б; `accountByDay[product][day]` при первой индексации; сборка блока: `accounts[*].days` + корневая проекция + `unattributedDays`; `captions`/`models[].name` — NFC, без `Cc`/`Cf`, ≤ 32/≤ 48, в подписи нет `@` и `/` — П4-в; `machine_tag()` `[a-z0-9-]{1,16}` из `machineName`, иначе санитизированный hostname (тег владельца для мака — `macbook`) — П4-а; валидация C7 с `isfinite`; пределы Linux-читателя: `raw_url` через `read(cap+1)` ≤ 8 МиБ, ≤ 64 файлов `machine-*`, ≤ 64 МиБ суммарно, тело любого ответа ≤ 16 МиБ, чистка `machine.name/os/app` (`Cc`/`Cf`, ≤ 64) — П5 в/г/д/е (тест-план A1-13/A1-14).
Готово, когда: старый `sync.merge()` на `machine-v11.json` даёт те же суммы, что на том же файле без блока; скан S3 файла машины чист; фикстура с ПДн-ключами не оставляет email/имя/организацию ни в одной структуре, журнале и `status`; hostile-фикстура и 9 МиБ `raw_url` не роняют читателя.
Валидация: `test_rl_contract.py` (A1-01…A1-14) — Т1–Т3; Т4 в редакции Юрки (`accountUuid` перечитывается каждый проход: изменился → новая метка, отсутствует → `null`, ротация токена без смены → метка та же); Т5, Т6, Т12–Т15, Т18, Т19, Т30; `test_sync_merge.py` расширен.
T1: П1-а, П1-б, П2-б, П4-а, П4-в (писатель), П5 в/г/д/е (Linux-читатель).
Ревью 1 (2026-10-12, `docs/review-remote-limits-a1.md`, T2 `docs/security-remote-limits-a1-t2.md`): цикл правок до коммита A1 — M2/N1 (суррогаты `Cs` в строках и ключах чужого файла), M1/N2 (`ccl-sync status`, `dump --merged` без чистки), N3 (редирект на raw-пути: тело 3xx не читать, только https `gist.githubusercontent.com`, ≤ 3 перехода), m1 (сырой перебор `accounts` ≤ 64), m2/N4 (бюджет 64 МиБ до скачивания, ошибка при > 64 файлах/суммы), N5 (`models[].name` без `@`/`/`), N6 (битый `accountByDay`), N12 (форма `localId`); тесты A1-16…A1-24 (без A1-22).
Ревью 2 (2026-10-13, `docs/review-remote-limits-a1-r2.md` APPROVE с правками; T2-r2 PASS): цикл правок 2 — видимая ошибка при отклонённом редиректе/чужом `raw_url` (без URL в тексте), узкий перехват сбоя записи `sync-remote.json` (`res.ok=False`, `lastOkAt` не двигается), суррогаты в `accountByDay`, NFKC `＠`/`／` и `\` в `models[].name`/подписях, `tz` ≤ 64, обработчик редиректа копирует только `req.headers` без `Authorization`/`Cookie`, одна константа «body too large», имя константы отказа; протокол v1.1 догоняет код (tech-writer). Ревью 3 не нужно, если правки в этом списке: зелёный набор + сверка дифа Юркой.

## A2 — политика токенов `[x]` (2026-10-13, `bcbc104`)

Зависит от: A1. Файлы: `linux/ccl/limits.py` (guard в трёх точках, `LimitData.account`, `follow_redirects=False`), `linux/ccl/common.py` (`credential_write`, `set_credential_write()`, маркер `rotation-pending-<p>`), `linux/ccl/cli.py` (`credentials --write never|guarded`).
Задачи: `never` по умолчанию, `guarded` — opt-in со строкой в `status` (П3-д); при `publisher: true` `guarded` игнорируется → `policy_forced_never` (П3-в); политика читается в начале **каждой** попытки под `file_lock("quota")` — CLI, издатель и трей одинаково (единое правило Юрки; A2-09 по нему, не «при старте процесса»); guard до POST `/oauth/token`, до replay `_PENDING`, в `_save_*`/`_rewrite_json` → `policy_violation`, результат `error/credentials` (П3-б.4); смена политики только под `file_lock("quota")`, отказ при маркере с живым pid; процесс `guarded` перед выходом делает одну попытку replay, иначе `pending_rotation_lost` (П3-б.2); идентичность снимается тем же чтением, что и токен, едет в `LimitData.account` (П2-в); в `never` `_PENDING` не создаётся, `deadRefresh` не трогается (П3-г); провайдеры и `/oauth/token` без редиректов (§5).
Готово, когда: синтетические файлы входа во всех состояниях (live/expiring/dead/absent/partial/mid-write) при `never` не меняют байты и mtime, POST token = 0, `oauth/usage` только в live; guarded-регресс зелёный.
Валидация: `test_rl_tokens.py` — Т7–Т10 (Т9 в редакции единого правила), Т33 (часть переключения), Т35; существующие `test_limits.py`, `test_manual_refresh.py` зелёные без изменений.
T1: П2-в (привязка в `LimitData`), П3-б, П3-в, П3-г, П3-д, §5.
Из T2-r2 A1 (`docs/security-remote-limits-a1-t2-r2.md`, R1, major, существующий код): `limits.py:243–245`, `:550–552` — Bearer-запросы к провайдерам через стоковый `urlopen` копируют `Authorization` на любой хост при 30x → `follow_redirects=False` + `max_body` на обоих вызовах, `update.py:215/:238` — `max_body`; тест: 302 на авторизованном GET к провайдеру → переход не выполнен, Authorization не ушёл, тело ≤ cap+1. Приёмка Юрки: `grep follow_redirects linux/ccl/limits.py`.
Ревью A2 (2026-10-13, `docs/review-remote-limits-a2.md` — 1 цикл правок; T2 `docs/security-remote-limits-a2-t2.md` — PASS с условиями). Цикл правок A2 (решение Юрки): M1/N1 — маркер ротации пишется **до** POST `/oauth/token`, не записался → `error/credentials`, POST не делается; N2 — маркер на процесс (`rotation-pending-<p>-<pid>`), удаляется только свой, проверка живости сканирует все; m1/N5 — занятый `quota` → отдельный класс `busy` (не `READ_ERROR/credentials`); m2 — ошибка открытия `quota.lock` → результат-ошибка без traceback (и в `ccl-sync credentials`); m4 — повреждённый маркер: сообщение с путём файла и способом восстановления; m5/N7 — в заголовок `chatgpt-account-id` идёт исходный `account_id` из файла, нормализованный — только в `LimitData.account`, id вне формы → `account=None`, без `LOGGED_OUT` (меняет контракт A2-11); m7 — `credentials --write guarded` при `publisher:true` печатает действующую `never`. Отложено: N3 (журнал replay), N4 (дедуп `policy_forced_never` + ротация O1), подключение `flush_pending` у издателя (П3-б.2 остаётся «частично» до A3/B1) → A3; N5-текст панели, N6/m3 (`select_snapshot` после `signed_out`), D1 → B1; N8 (`update.py:101/:118` `max_body`, тело промежуточного 302) → A4.
Ревью A2-2 (`docs/review-remote-limits-a2-r2.md`, `docs/security-remote-limits-a2-t2-r2.md`): цикл правок 2 (третий, последний по лимиту) — R2-1/MR2-1: предикат полноты входа до POST = предикат записи (`account_id`/access из пробелов, Claude без `accessToken` → `LOGGED_OUT` без POST); R2-2/mr2-3: два текста отказа — живой чужой маркер («дождитесь попытки, не останавливать и не удалять»), нечитаемый/переиспользованный pid («удалите …»); R2-3/mr2-4: невалидный `expires_in` не роняет сохранение (срок по умолчанию 28800 с), пара сохраняется; R2-4/mr2-2 (решение Юрки): ответ `/oauth/token` с одним `access_token` принимается, старый refresh сохраняется (RFC 6749 §6, так делают Claude Code и Codex CLI); R2-5/nr2-5: `remove_rotation_marker`/`Store` после успешного маркера — `suppress(OSError)`. После — точечная сверка security-analyst только по этим строкам.

## A3 — ядро издателя и координация `[x]` (2026-10-15, `2b9b8b3`; условие до A5 — N5+P1 первым фиксом A4)

Зависит от: A2. Файлы: `linux/ccl/publisher.py` (новый), `linux/ccl/coordination.py` (новый), `linux/ccl/sync.py` (`open_cycle()`/`write()`, три отпечатка, `accounts=`, `clockSkew`, пределы чтения), `linux/ccl/cli.py` (`publisher --enable|--disable|--products|--mode|--now|--status`, хук в `cmd_push`), `linux/ccl/polling.py` (нормализация интервала), журнал `~/.local/state/claude-codex-limits/publisher.jsonl`.
Задачи: проход synth v2 §C шаги 0–8 (PATCH попытки → запрос → PATCH результата; `publish_failed` → запроса нет, `last_attempt` восстановлен; gist недоступен → своё расписание, блок уходит следующим проходом); `decide` §D (правила 1–5, запасы 60 с, тай-брейк ≤ 1 тик на пару); чужой `retryUntil` отдельно от своего: `remote_retry_until` + `firstSeenAt` на диске, `effective = min(retryUntil, firstSeenAt + 24 ч)`, событие `remote_retry_capped`; чужие `asOf`/`attemptAt`/`nextAt` > `now + 60 с` или несогласованные → для B2 не свежие (П7); `identity_changed` при смене `localId` за время запроса — результат отброшен, попытка потрачена; `cache.json`/`publisher-state.json` по `localId` (П2-в); время прохода ограничено (пределы разбора — A1); `open_cycle` берёт `sync` **блокирующе с ожиданием ≤ 60 с**, не пропуском как `busy`; истекло → как недоступный gist по P6 (П8-а, A3-19); `quota` занят → `pass_skipped busy`; журнал 0600 через `O_APPEND|O_CREAT`, атомарная ротация, `run_pass` ловит всё и пишет класс события (П6-а); `clockSkew` из заголовка `Date`.
Готово, когда: `FakeGitHub` фиксирует PATCH с `attemptAt` раньше запроса к провайдеру; симулятор двух машин 24 ч при 15 мин и 4 ч — 0 пар в установившемся режиме, ≤ 1 на событие, GET/PATCH в пределах таблицы synth §C; инварианты И1–И4 (T1 П7) держатся на fuzz чужих файлов.
Валидация: `test_rl_coordination.py`, `test_rl_publisher.py`, `test_rl_sim.py` (A3-01…A3-21) — Т21, Т23–Т25, Т27, Т29, Т31–Т34; Т24/Т32 в редакции A3-20(c)/(d) (чужой ввод только откладывает; при мусорных/будущих чужих полях ≥ 1 запрос за `max(I, 24 ч)`; heartbeat меняет только `lastSeenAt`); тесты §G A3 synth v2.
T1: П2-в, П6-а, П7, П8-а.
Из ревью A2: N3 — успешный replay по старой политике журналируется (`token_refresh`, `credentialWrite=1`); N4 — `policy_forced_never` пишется при смене, не на каждый вызов, O1 с ротацией; `run_pass` в конце вызывает `limits.flush_pending()` (закрывает П3-б.2); `file_lock` — дедлайн по `monotonic`.
Цикл правок A3 №1 (2026-10-15, решение Юрки; `docs/review-remote-limits-a3.md` PASS с условиями, `docs/security-remote-limits-a3-t2.md` PASS с условиями): M1 — `schedule.nextAt = last_attempt + interval`, свой `retryUntil` только в `retryUntil` (+ вектор «чужой 429, Retry-After 2 ч»); S1 — `lastSeenAt > now + 60` → запись неживая (+ вектор); S2 — общий дедлайн чтения ≤ 60 с (остаток файлов пропускается, `partial`), одно переоткрытие сессии, после ≥ 3 тиков `publish_failed` подряд или `now − last_attempt ≥ max(I, 24 ч)` — опрос по своему расписанию, как при недоступном gist; ошибка видна в коде выхода и `lastError`; S3/m4 — ротация журнала сжимает до ≤ 512 КиБ (гистерезис), `clock_skew`/`sync-state.json` не чаще раза за проход; m3 — пропуск `token_policy` (§C шаг 5); m5/S4 — `publisher --now` без `publisher:true` отказывает, ручной `push` на машине издателя идёт через `run_pass("manual")`; m1 — свой Retry-After = max(корзина, зеркало); m2 — откат `publish_failed` одной атомарной записью или с восстановлением при обрыве; S5 — чужой `machineId` вне формы не попадает в `tie_wait`. m6 (протокол/перечень O1) — tech-writer. S6 (`TimeoutStartSec`/`RuntimeMaxSec`) → A4. Nit — по возможности.
Цикл правок A3 №2 — последний по лимиту (2026-10-15, решение Юрки; `docs/review-remote-limits-a3-r2.md` PASS, `docs/security-remote-limits-a3-t2-r2.md` PASS с условием): N1 (major) — неудача публикации и проверка «≥ max(I, 24 ч) с последней попытки» учитываются ДО переоткрытия сессии (убитый посреди переоткрытия проход не обнуляет серию), фаза `1xx` ограничена сроком; N2/R2-m1/R2-m1b — общий срок на чтение тела только параметром `deadline=` для чтений sync, прочие вызовы (OAuth refresh, `limits.fetch_*`, GitHub refresh, `update.py`) — прежняя семантика таймаута; оборванное тело с Content-Length → ошибка, не 200; N3/R2-m2 — форма маркера `_rollback` проверяется, битый снимается + событие O1; R2-n1 — предпроверка `never` считает пустой accessToken/нет expiresAt истёкшим. В долг A4: N4 (в пределах П7), R2-n2 (бюджет переоткрытия), R2-n3, S6 — лимит юнита НЕ меньше 15 мин (не 300 с). R2-m3 (протокол: срок чтения 60 с, partial, переоткрытие, ветка 24 ч, clock_skew раз за проход) — tech-writer.
Из ревью A1: `accounts.build` при переполнении не бросает — публикация без `accounts[].days` + событие O1; координация считает gist прочитанным по `lastOkAt`/`res.remote`, не по `res.ok` (частичный проход при пропуске большого файла — R1), признак `res.partial` и код выхода `ccl-sync push` без «Sync failed» на частичном проходе (m4); N8 — GET gist > 16 МиБ: собственный PATCH не зависит от чтения, raw по одному; N9 — кеш отвергнутых `raw_url`, чтобы не скачивать заново каждый цикл.

## A4 — установка и статус `[x]` (2026-10-18, `9dd3bb6`; ревью r4 PASS, T2-r2 PASS — выкатка A5 разрешена ИБ)

Зависит от: A3. Файлы: `linux/install.sh` (`--publisher`, `--no-tray`, `--name <tag>`), юнит таймера `OnUnitActiveSec=5min`/`OnBootSec=2min`, `linux/ccl/cli.py` (`status` O2).
Задачи: `settings.json` = `{publisher: true, autoPoll: true, credential_write: "never", machineName: <tag>}`; `XDG_RUNTIME_DIR` экспортируется только при существующем каталоге; `--no-tray` не создаёт `.desktop`/autostart (П6-в); при запущенном процессе трея пользователя установка **отказывает** (проверка процесса), печатает команду остановки, перезапуск не делает (П3-б.3, A4-02; решение Юрки); `status` печатает действующую политику и путь state-каталога (П3-в, П8-б), счётчики 24 ч (запросы, 429, неудачные публикации), `clockSkew`; токен/email/тексты исключений — нигде (П6).
Готово, когда: установка во временном `HOME` с подменным `systemctl` даёт ожидаемые юнит и настройки; `test_deb` зелёный.
Валидация: Т20, Т22, Т28, Т33 (часть install); `test_deb.py`.
T1: П3-б.3, П3-в (status), П6-б/в, П8-б.
**Первым в A4 (условие закрытия A3, до A5; решение Юрки 2026-10-15):** N5 (major, `docs/security-remote-limits-a3-t2-r3.md`) — счётчик серии `publish_failed` +1 сохраняется вместе с резервом попытки ДО PATCH №1 и обнуляется сразу после успеха; при счётчике ≥ 3 или по ветке 24 ч опрос идёт до блокирующей публикации; тест A3-49; P1 (`docs/review-remote-limits-a3-r3.md`, Codex — major, взято строже) — успешный heartbeat обрывает серию («3rd consecutive», `sync-protocol.md:460`), сброс серии не теряется при убийстве во время запроса провайдеру; затем короткий T2 только по этому фиксу. Юнит: `RuntimeMaxSec`/`TimeoutStartSec` не меньше 15 мин (S6; не 300 с).
Долг A3 → A4: N6 (срок заголовков включает DNS/TLS — OAuth POST, A3-50), N7 (updater: тело 3xx без предела — объединить с N8 A2), N8-тест (сторож сокета глотается `common.http` — общий охранник тестов со свежей копией `common.py`), N4 (PATCH прошёл, локальная запись нет → откат объявленной попытки), P2 (2xx PATCH с оборванным эхом → `Resp(0)` без `original_status`), n1 (пробельный/не-строковый accessToken в предпроверке `never`), n2 (= N6), n3 (`_HTTPDeadlineStream.fileno`), R2-n2 (бюджет переоткрытия), R2-n3; test-plan Т18 «подделка `urlopen`» → локальный сервер.
Цикл правок A4 №1 (2026-10-15, решение Юрки; `docs/review-remote-limits-a4.md`, Codex-проход и T2 пропущены — недельный лимит Codex): M1 — `--no-tray` удаляет ярлык меню и автозапуск прежней установки (как `uninstall.sh:26-27`), признак «без трея» хранится в `settings.json` (`tray: false`), `update` решает по нему, а не по наличию ярлыка; m — переустановка/`update` издателя сохраняет `autoPoll`/режим `publisher --mode`; m — `attemptPending` не висит (ветки «identity сменилась до запроса» и долгий `token_policy`), heartbeat обрывает серию; m — проверка трея в `install.sh` не находит вызывающий процесс обновления (GUI-update издателя с треем). Долг T2 до A5 — список в отчёте ревью A4.
Цикл правок A4 №2 — последний (2026-10-18, решение Юрки; отложенные `docs/security-remote-limits-a4-t2.md` PASS с условиями и Codex-проход r3 в `docs/review-remote-limits-a4.md`): N1 (major) — время попытки ставится и сохраняется на диск прямо перед КАЖДЫМ вызовом провайдера (`poll.begin(time.time())`), а не одно на все продукты в резерве (урок 015); C1 (Sol major, взято строже) — первым опрашивается продукт с самой старой попыткой, точка убийства «во время запроса первого продукта» в A3-49; H1 (major, до C4 — берём сейчас, тот же код) — ветка 24 ч при здоровой публикации не обходит `remote_attempt`/`fresh_remote` (сверка с `sync-protocol.md:458-462`, T1 П7); C2 — обычная установка `--no-tray` сохраняет выбор после `update`; C3/F7 — `status` без трейсбэка при отсутствующем `machine-id` и полном диске; F2 — `DEST` экранируется в обёртке/cron/`ExecStart`; гигиена тестов — тест, вызывающий настоящий `systemctl --user is-active`, перехватить. Инструкция выкатки (tech-writer): stop `ccl-sync.service` перед удалением (§8.1/8.2), сверка XDG через `show-environment | grep -E '^XDG_(CONFIG|STATE|DATA)_HOME='`, зазоры G1 по `ts`. В беклог (C-срез/B1): F3 `updateDebUrl`, F4 DNS/тело без общего срока, F5 программа трея при `--no-tray` (B1), F6 кириллица GECOS, остаток P1 (пересмотреть до C4).
**Остатки A4 → обязательны до C4 (решение Юрки 2026-10-18; на A5 не влияют — соседей v1.1 нет):** H1-a/H1-r — дневной (24 ч) запрос при здоровой публикации уходит до PATCH №1 без объявления в gist (пересмотреть и тест A3-49 `test_24h_branch_polls_before_patch1`, он строже протокола `sync-protocol.md:457`); H1-b — незавершённая попытка при серии 0 уводит ветку 24 ч на ранний путь мимо соседей (убрать `_pending(bucket)` из 24-часового условия); C1-v (Sol major, взято строже) — первый запрос ~19 мин + убийство на втором → второй продукт без данных сутки (вместе с F4: общий срок DNS/тела); N1-r — время попытки снимается до записи на диск (замок файла состояния без таймаута → зазор < I); остаток N1 (в gist объявляется время резерва); п. 8 T2 A4. В C-срез: F8 шаблон удаления строки cron стирает чужую строку с «ccl-sync push»; перевод строки в `XDG_DATA_HOME` → запись в crontab, `\%` в пути, `Exec=` desktop-ярлыка без экранирования (тот же UID, minor); модель cron в `test_rl_a4_fix2.py` `cron_command` неверно разбирает `\\%`; F3, F5 (B1), F6.
Из ревью A2: N8 — `update.py:101/:118` с `max_body`, тело промежуточного 302 у загрузок не читается без предела.
Из ревью A1: N7 — `--name` обязателен для `--publisher`; запасной тег из hostname не должен нести имя владельца (вектор `alex-ThinkPad-X1`, A1-22).

## A5 — выкатка на VPS и 24 ч журнала `[ ]`

Зависит от: A4; владелец (`ccl-sync login` на VPS, остановка старого трея на `:20`, решение П4-б). Файлы: кода нет; журнал O1 и `status` на VPS; запись результата в `status.md`.
Задачи: `sh linux/install.sh --publisher --no-tray --name vps`; через ≤ 15 мин файл VPS в gist с блоком; 24 ч журнала; проверка риска 1 (`history` ≤ 30, ответ `GET /gists/{id}` ≤ 100 КБ); ручные сверки Юрки по T1 §7: `stat -c '%y %s' ~/.claude/.credentials.json ~/.codex/auth.json` до/после суток против `credentialWrite=0` в O1, файл машины в gist глазами (нет имени/хоста/UUID кроме `machine.id`), `journalctl --user -u ccl-sync` без токена/email.
Готово, когда: G1 — все пары по аккаунту ≥ 900 с, ≤ 10 запросов/сутки при простое; G2 — 0 записей в файлы входа, 0 повторных входов; старые читатели (мак 3.2.7) продолжают суммировать расход.
Валидация: журнал O1 за 24 ч (сведение по метке), `ccl-sync status`, проверки выше.
T1: §7 ручные проверки 1–5; П4-б (решение владельца о пересоздании gist — метки сменятся у всех машин).

## B1 — трей на машине с издателем `[ ]`

Зависит от: A3. Файлы: `linux/ccl/gui/app.py` (`delegated` в `refresh_limits`, `save_poll_states` no-op, `on_activity` без записи, воркер под `file_lock("quota")`, `refresh_logs` с `allow_push=False`), `linux/ccl/quota_refresh.py` (вид допуска `delegated`).
Задачи: при `settings.publisher` трей не пишет `autoPollState`/`quotaServerRetryAt`, раз в 60 с перечитывает `cache.json`/`state.json`/`publisher-state.json`, кнопка → `publisher.run_pass(manual=True)`; второй клик → `in_flight`, воркер не стартует (П8-в); на не-делегированных машинах воркер держит `quota` на время fetch + apply, попытка сохраняется **до** `Thread.start`, ошибка записи = запроса нет; `never` по умолчанию действует и здесь (П3-д).
Готово, когда: 2 ч виртуального времени трей + таймер с кликами каждые 10 с → ≤ 1 запрос на аккаунт за любые 15 мин; `state.json` в `delegated` треем не меняется (mtime).
Валидация: Т26, Т33 (часть трея); `test_auto_ui.py`-стиль (Qt при наличии, в CI обязателен).
T1: П3-д, П8-в.
Из T2-r3 A2 (`docs/security-remote-limits-a2-t2-r3.md`, info): тест A2-22b (`refresh_token` ∈ {"", null} → как A2-22; {"   ", 5, {}} → `invalid_response`); проверку полноты Claude `limits.py:322` перенести под `guarded` (симметрия с Codex: пробельный refresh при свежем access не должен прятать значения в `never`); подсказка для живого маркера при зависшей ротации («восстановите доступ к файлу входа»); `st.set("claudeTier")` `:327` под suppress.
Из ревью A2 (D1, условие входа в B1): подключить `limits.flush_pending()` к штатному выходу трея — порядок «остановить новые попытки → дождаться воркеров → flush → quit/execv» (одного `atexit` мало: при `execv` не срабатывает), не из UI-потока (ожидание `quota` до 60 с), тест настоящего выхода трея; у издателя (A3) — то же в конце `run_pass`. Флейк: один прогон полного набора под нагрузкой дал failures=1, errors=1 (имена не сохранены) — при следующем прогоне под нагрузкой гонять с `-v`.

## B2 — Linux-трей publish-only (вторая очередь) `[ ]`

Зависит от: B1, C1 (контракт стабилен). Файлы: `linux/ccl/gui/app.py`, `gui/paint.py`/`gui/panel.py` (текст из снимка только `PlainText`/`drawText` — П5-б).
Готово, когда: трей без издателя публикует блок своих локальных аккаунтов из `cache.json` + `autoPollState`; фикстура с HTML не вызывает загрузки.
Валидация: Т17; `test_usage_sync.py` расширен.
T1: П5-б.

## C1 — macOS: merge v1.1 и резолвер `[ ]`

Зависит от: A1 (контракт и фикстуры общие). Файлы: `Sources/RemoteLimits.swift` (новый: `RemoteAccount`, валидатор C7, `mergeV11`, `ReaderSyncState`, `resolveAccounts`), `Sources/LimitsMonitor.swift` (`SyncCachedMachine.lastSeenAt`, `SyncRemoteCache.accounts/captions/unattributedDays`, `LimitData.source`; проверки — в существующем `--sync-selftest`, `now` явный).
Задачи: V3/V5/V2 чистой функцией с инжекцией `now`; состояние 7 → удалённых `AccountView` нет; пределы читателя (тело ≤ 16 МиБ, ≤ 64 файлов, ≤ 64 МиБ, `raw_url` ≤ 8 МиБ — П5-д), чистка строк `machine.*`/подписей/моделей (П5-е, П4-в), даты с годом 99999/`+99:00`/дробной частью 10⁶ знаков отбрасываются (Т36); проекция З2 — либо `accounts[].days`, либо корень, никогда оба.
Готово, когда: старый/новый файл → одинаковые `days`; hostile-фикстура не роняет приложение; один Codex на двух машинах → одна карточка, два → две; таблица V5 воспроизводится фикстурами 1–7.
Валидация: `bash build.sh && "$APP" --sync-selftest` (C1-01…C1-08); Т15 (Swift), Т19, Т30 (Swift), Т36.
T1: П4-в (читатель), П5-д, П5-е.
Из ревью A1: N10 — чужая запись с `asOf` в далёком будущем не выигрывает карточку у локального свежего чтения (то же в B2); свой файл занимает один из 64 слотов — как в Linux (п. 1 ревью); открытый вопрос N11 — общий ли `tokens.account_id` у Codex в воркспейсе ChatGPT Team (проверить до C1, для владельца — один личный аккаунт).

## C2 — macOS: настройки, деньги, история `[ ]`

Зависит от: C1. Файлы: `Sources/LimitsMonitor.swift` (`monitor_*` → «опрашивать на этом Маке», `hiddenAccounts`, `menuAccount`, `mergedUsageIndex` по `hiddenAccounts`, `subscriptionUSD(tier:)`, `UsageHistory` с ключом `acct`, селфтест ~7108 переписан).
Задачи: история по `acct` (локальный отпечаток / метка), `recordRemote` без `productEnabled`, дедуп `(acct, t)`; аудит `productEnabled` по synth §F (оставить в `fetchClaude`/`fetchCodex`/`UsageLogs.scan`/`snapshotJSON`/`record` — урок 013); событие `reader_card_state` в `~/.claude-limits-monitor/poll-log.jsonl` при каждом успешном синке — по каждому видимому аккаунту: метка, состояние V5, возраст показания, без ПДн (PRD §5, под замер G3/G4; решение Юрки; Linux-читатель — вторая очередь).
Готово, когда: выключенный локальный опрос Claude + чужие `asOf` → темп считается и карточка Claude с VPS видна; 0 чтений Keychain по Claude; `$200` у `max_20x` с VPS без «оценки»; после синка в журнале по строке `reader_card_state` на видимый аккаунт.
Валидация: `"$APP" --subscriptions-selftest` (C2-01…C2-07, переписанный 7108); строки `reader_card_state` проходят сканер ПДн/секретов (A1-10).
T1: П2-в (ключ истории по идентичности); журнал читателя без ПДн (S5).

## C3 — macOS: UI карточек и строка меню `[ ]`

Зависит от: C2; UX-спек с правкой строки 7. Файлы: `Sources/LimitsMonitor.swift` (подпись и тег `machineName` в defaults с санитизацией, строка источника, тексты V5 RU/EN, `limitCanFix(remote:)`, `snapshotHorizon`, плашка плана, `menuAccount`, настройки «Опрашивать на этом компьютере» / «Аккаунты» / ссылка V10, PNG-превью 7 состояний).
Задачи: клик по чужой карточке — только константный URL продукта, поле снимка в URL не попадает (П5-а); бейдж Advanced из таблицы V5, не `limitAuthBadge`; `machine.name` мака → тег, у владельца `macbook` (П4-а, Т13); при рендере — то же событие `reader_card_state` (состояние на экране = строка журнала); тексты V5 — по UX-спеке с правкой строки 7 (состояние 7 без значений, правит Юрка).
Готово, когда: PNG 7 состояний × RU/EN × узкая/широкая Simple × Advanced совпадают с UX-спекой по чеклисту; Юрка сверил в реальном приложении (remote-hands, скилл visual-verify); ни в одном состоянии нет `claude login`/`claudefix`/бейджа «вход истёк».
Валидация: `"$APP" --subscriptions-selftest` (C3-01…C3-11, PNG детерминированные, `now` фиксирован), Т13, Т16; состояние на PNG = `reader_card_state` в журнале; визуальная сверка Юрки.
T1: П4-а (мак), П5-а.

## C4 — macOS: издатель мака и B2 `[ ]`

Зависит от: C3; A5 (VPS публикует — иначе B2 на маке нечем проверить вживую). Файлы: `Sources/LimitsMonitor.swift` (`GitHubSync.syncNow(force:mode:completion:)`, `SyncOutcome`, `.writeOnly`, `machineFile` += блок Codex, `cacheQuotaCompletion` с `accountId`, `doRefresh` с продолжением из completion, `clockSkew`), `Sources/QuotaRefresh.swift`, `codexAccessToken()` (политика), `~/.claude-limits-monitor/poll-log.jsonl`.
Задачи: ключ defaults `credentialWrite` — `never` по умолчанию, guard до POST и в функции записи, в `legacy` запись атомарна с перечитыванием/сравнением пары, `persistClaudeQuotaUpdate` при `never` не вызывается (П3-а, П3-д); чужой дедлайн отдельно от `serverRetryAt` с потолком 24 ч от `firstSeenAt` (П7); PATCH попытки до `fetchCodex`, упавший PATCH → запроса нет; `.failed` чтения / нет completion за 60 с → своё расписание (B1).
Готово, когда: селфтест с транспорт-ловушкой фиксирует порядок PATCH(`attemptAt`) → `fetchCodex` → PATCH(результат); при свежей чужой попытке `fetchCodex` не вызывается; файл мака в gist содержит блок Codex с меткой; `auth.json` при `never` не тронут.
Валидация: `"$APP" --sync-selftest` (C4-01…, `decide-vectors.json` общие с A3-01), `"$APP" --auth-selftest`; Т11, Т23–Т25 (Swift), Т31–Т32 (Swift), Т35 (`noRedirects` уже есть — регресс).
T1: П3-а, П3-д, П7, §5 (регресс).

## C5 — подписи и список аккаунтов (Should) `[ ]`

Зависит от: C4. Файлы: `Sources/LimitsMonitor.swift` (блок «Аккаунты», правка подписи ≤ 32 с чисткой, `captions` в `machineFile`), `linux/ccl/accounts.py` (merge подписей по `setAt`).
Готово, когда: подпись, заданная на маке, видна на всех машинах после цикла; ввод с `@`, `/`, управляющими символами отклонён (П4-в).
Валидация: Т14; `"$APP" --subscriptions-selftest`.
T1: П4-в.

## C6 — релиз и проверка гипотезы `[ ]`

Зависит от: C4 (C5 по готовности). Файлы: документация (TechWriter), changelog, финал `docs/sync-protocol.md`, release notes.
Задачи: T3 ИБ-чек релиза (security-gate); решения владельца: П4-б — пересоздание gist (имя в истории ревизий старого), П6-б — `chmod 700 ~/.codex`; PR ⛔ → выкладка macOS (`bash build.sh`, `scripts/make-dmg.sh`) и Linux `linux-v…` (`sh linux/packaging/release.sh`, `--latest=false`); smoke на установленной сборке; напоминание в `HQ/now.md` на день выкладки + 14.
Готово, когда: 14-дневный замер G1–G4 по журналам обеих машин сведён PM-ом (G1/G2 — O1 издателей, G3/G4 — `reader_card_state` мака + O1); решения при недоборе из PRD §8 применены или не понадобились.
Валидация: полный Linux CI 0 ошибок / 0 пропусков; все селфтесты Swift; packaged QA; скан секретов перед коммитами.
T1: П4-б, П6-б, T3.

## Куда легли требования T1

| T1 | Веха |
|---|---|
| П1-а (`organizationUuid` снят), П1-б (метка при публикации), П2-б (один ключ, предел 8 МБ), П4-а (тег Linux), П4-в (чистка у писателя), П5 в/г/д/е (пределы и чистка у Linux-читателя — A1-13/A1-14) | A1 |
| П2-в (идентичность в `LimitData`), П3-б (порядок переключения, guard в записи; политика — в начале каждой попытки под замком), П3-в (`policy_forced_never`), П3-г, П3-д (`never` по умолчанию), §5 (редиректы) | A2 |
| П2-в (кэш/состояние по идентичности, `identity_changed`), П6-а (журнал), П7 (чужой дедлайн отдельно, потолок 24 ч), П8-а (ожидание `sync` ≤ 60 с блокирующе) | A3 |
| П3-б.3 (отказ при старом трее), П3-в (`status`), П6-б/в, П8-б (путь state-каталога) | A4 |
| §7 ручные проверки 1–5, П4-б (решение владельца) | A5, C6 |
| П3-д (трей), П8-в (повторные клики) | B1 |
| П5-б (PlainText в трее) | B2 |
| П4-в (читатель), П5-д/е, Т36 | C1 |
| П4-а (тег мака), П5-а (константный URL клика) | C3 |
| П3-а (атомарная запись `auth.json`, guard), П3-д (мак), П7 (мак) | C4 |

> LINUX-COMPACT 0.4.5 завершена и опубликована 2026-10-08. [План](linux-compact-refresh-plan.md), [проверки](linux-compact-refresh-verification.md). macOS 3.2.7 остаётся Latest.

# MANUAL-REFRESH · 2026-10-07

> 2026-10-08: [COMPACT-REFRESH](compact-refresh-plan.md) прошла независимые code/isolation/design review и packaged QA. 3.2.7 опубликована и установлена; [приёмка](compact-refresh-verification.md).

MANUAL-REFRESH завершён: macOS3.2.6 опубликована и установлена. Source d50584bcf5c7b7b63eb6df2ef50539b11fd0f045; Code/SecurityPASS, pure78/1089/0, packaged3091/0, QA36 новых PNG. Публичный DMG b8ff16fc совпал; installed strict codesign/SHA PASS, PID96073. Linux0.4.4 не меняется. [Приёмка](manual-refresh-verification.md).

# План исполнения — устойчивая GitHub-авторизация и история UI

## KEYCHAIN-QUIET · 2026-10-07

Production66587e9 и DMG153517fc приняты; v3.2.5 опубликован (Latest) и установлен на этом Mac; публичный DMG SHA совпал, запуск PID72805 подтверждён. [План](keychain-no-background-prompts.md), [итоговые проверки](keychain-quiet-verification.md).


> Текущий инкремент2026-10-05: [FRESH-4H](freshness-4h-plan.md), [KEYCHAIN-RETRY](keychain-retry-plan.md). Production/review/тесты/CI/native UI приняты. Binary target13 и пакетная приёмка PASS. Выпущено 2026-10-06: [macOS3.2.4](https://github.com/ArrivaRUS/claude-codex-limits/releases/tag/v3.2.4) на4a5c372 и [Linux0.4.4](https://github.com/ArrivaRUS/claude-codex-limits/releases/tag/linux-v0.4.4) наbd16d9c. Публичные DMG/DEB скачаны и SHA совпали; Latest=v3.2.4. На этом Mac установлен3.2.4 в /Applications, подпись и binary SHA проверены, PID29719 запущен. Резервная3.2.3: /private/tmp/ccl-install-backup-_eivvisr/Claude Codex Limits.app. [Доказательства](freshness-keychain-verification.md).

> AUTOSTART-1 (2026-10-05): Mac actual3.2.3 и disk/loaded LaunchAgent verified; исторический старый запуск не установлен. Read-only план: [diagnosis-autostart-version.md](diagnosis-autostart-version.md).

> GH-AUTH-STABLE выпущен на 40cfdf (2026-10-04); Linux284/0skip, Swift30862/0, QA374 PNG и пакеты PASS. Версии 3.2.3/0.4.3 опубликованы, публичные assets проверены.

> GH-AUTH-STABLE (2026-10-04): реальный auth lifecycle — [github-auth-stability-plan.md](github-auth-stability-plan.md). Прежний UI-only план ниже архивирован до production; задача уточнена владельцем.

> GH-AUTH-UI (2026-10-04) архивирован до кода: [github-auth-ui-fix.md](github-auth-ui-fix.md), [предварительный test-plan](test-plan-github-auth-ui.md). Storage/UI исправления входят в GH-AUTH-STABLE.

> GH-AUTH (2026-10-04): диагностика повторной авторизации — [github-auth-diagnosis.md](github-auth-diagnosis.md).

> AUTH-1 выпущен в 3.2.2/0.4.2 (2026-10-03): [auth-hints-fix.md](auth-hints-fix.md).
> План Auto ниже — завершённая история; его статусы не относятся к новому коду.

Обновлено: 2026-10-03. Источник требований: [`../PRD.md`](../PRD.md), [`../stories.md`](../stories.md). База: `main` `e6e2f2e`. Это план нового инкремента, созданный после релизов macOS 3.2.0 / Linux 0.4.0; он не описывает их как прошедшие командный конвейер.

## Допущения

Алгоритм и сохранённые per-product состояния уже работают. Цель — представление состояния на macOS и Linux. Точные размеры, цвета, расположение и поведение длинной подписи — зона UX. Прямой запрос владельца принимает направление; повторного выбора стилистических вариантов не нужно. Независимый аудит старого Auto и реальный ALSE-прогон ведутся отдельными задачами из бэклога.

## Порядок вех

| ID | Веха | Зависит от | Статус |
|---|---|---|---|
| M1 | UX-спецификация кнопки, видимой подписи и всех состояний | PRD | [x] |
| M2 | Узкий план реализации + сценарии проверки до кода | M1 | [x] |
| M3 | Developer: macOS и Linux UI по спецификации | M2 | [x] |
| M4 | Независимые Tester и CodeReviewer; исправление находок | M3 | [x] |
| M5 | QA bitmap macOS/Ubuntu CI, RU/EN, обычной/расширенной панели; live ALSE отдельно | M4 | [x] |
| M6 | Документация и выгрузка новой версии по ранее данному разрешению | M5 | [x] |

Завершено 2026-10-03 на `5b722a1`: macOS 3.2.1 / Linux 0.4.1 опубликованы,
скачанные assets сверены. Доказательства и границы — [status.md](status.md),
[qa-auto-ui.md](qa-auto-ui.md). M5 принят по доступным bitmap и actual draw
assertions, без заявления о живом экране: ALSE/hover/click/user fonts вынесены
в самостоятельный долг. Независимый аудит прежнего Auto этим не закрывается.

## M1 — UX-спецификация

Результат: один согласованный вариант стилизованной «А» с видимой рядом частотой; предусмотрены разные и одинаковые частоты, одна подписка, обе выключены, backoff, RU/EN и обе формы панели. Зафиксированы измеримые размеры/отступы. Проверка: оркестратор сопоставляет спецификацию с каждым правилом PRD и показывает реальный/проверяемый макет.

## M2 — план и проверки

Готово: `design/auto-poll-ui.md`, `docs/auto-ui-implementation.md` и `docs/test-plan.md`.
Спецификация и test-plan зафиксированы коммитом `f311c4e` до изменения кода;
Architect/challenge вернул PASS, обнаруженный repaint Linux включён в план.

Результат: разработчику переданы точные точки чтения состояния и минимальная область UI-изменений; `docs/test-plan.md` создан до кода с матрицей из PRD, проверками изоляции и командами запуска. Команды не выдумывать: Tester/Developer указывают реально доступные вызовы и безопасные фикстуры. Проверка: все четыре истории имеют наблюдаемый тест, а данные тестов не трогают реальные keyring, файлы пользователя, gist/API (урок 006).

## M3 — реализация

Результат: обе платформы читают своё per-product состояние и обновляют подпись при его изменении; фиксированные слоты не подсвечиваются при Auto. Проверка: целевые UI-тесты, сборка/Swift selftest и Linux-тесты с сырым выводом на новой ревизии. Падение валидации останавливает переход к M4.

## M4 — независимые проверки

Результат: отдельные Tester и CodeReviewer проверяют дифф и сценарии. Reviewer пишет вывод о security-поверхности; находки исправлены и повторно проверены. Аудит ранее опубликованного Auto — отдельная задача, его отсутствие нельзя записать как PASS этого этапа.

## M5 — QA

Результат: матрица macOS/Linux × RU/EN × вид панели × основные состояния, читаемость и отсутствие перекрытий на реальном экране; сырой результат и ревизия сохранены. Ошибки разбираются до M6. ALSE-проверка остаётся отдельной, пока её реально не выполнили.

## M6 — документы и релиз

Результат: TechWriter обновил пользовательские инструкции, подготовлены заметки и способ отката. После пройденных гейтов Юрка выгружает новую версию в Git по прямому разрешению владельца «после выгружай новую версию в гит»; повторного согласия для этого принятого UI-инкремента не требуется. Новый скоуп или блокирующая находка требуют отдельного решения. После публикации — smoke на установленной сборке и дата проверки гипотезы. Linux-пакет выпускается как `linux-v…` с DEB и `--latest=false`, а не одним merge в `main`.
