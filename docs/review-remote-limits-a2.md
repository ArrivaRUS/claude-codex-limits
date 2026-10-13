# Ревью A2 — политика токенов (REMOTE-LIMITS), цикл 1

**Ревизия:** `8989735` (код, GPT-6 Astra) поверх `43506ca` (тесты A2). HEAD = `8989735`, дерево чистое.
**Ревьюер:** code-reviewer (Opus 5.5) + Codex-проход GPT-6.1 Sol @high (read-only).
**Источники:** `docs/plans.md` §A2 + R1; `docs/test-plan-remote-limits.md` A2-01…A2-11 и «Уточнения A2»; `arch/plan-synth.md` §E;
`docs/security-remote-limits.md` П2-в, П3-б/в/г/д, §5; `docs/security-remote-limits-a1-t2-r2.md` R1.

**Итог:** нужны правки, 1 цикл. Ядро политики верное: в `never` нет POST `/oauth/token`, нет replay, нет `_PENDING` и маркера,
`deadRefresh`/`deadCodexRefresh` не трогаются; все пути записи в файлы входа идут через guard; R1 закрыт (4 запроса к провайдерам с
`follow_redirects=False` и `max_body`, `update.py` — `MAX_DEB`/`MAX_TARBALL`). Блокирует мерж одна находка — M1.

**Прогоны:** `test_rl_tokens.py` 32 OK. Полный Linux-набор: 469 OK / 48 skip в 6 из 7 прогонов; **1 прогон (параллельно с Codex,
под нагрузкой CPU) дал `failures=1, errors=1`**, имена не захвачены; 4 параллельных прогона и 2 последовательных потом зелёные.
Это флейк, не воспроизведён. Совет Юрке: при следующем прогоне под нагрузкой сохранить вывод `-v`.

## Блокирует мерж (major)

### M1 · major · `linux/ccl/limits.py:444`, `:627` (+ `common.py:324`) — сбой маркера ротации обрывает сохранение уже ротированной пары · Opus + Sol
- **Что не так.** В `_save_*_guarded` сначала заполняется `_PENDING[p]`, потом `common.write_rotation_marker(p)`. Маркер может бросить:
  `OSError` (STATE_DIR недоступен на запись, нет места, `fsync`/`replace`) или `ValueError` (`/proc/sys/kernel/random/boot_id` не
  читается или имеет другой формат, например на усиленном ядре). Исключение проходит через `_save_*` (там ловится только
  `CredentialPolicyRefused`) и через `fetch_*`. Сервер уже ротировал refresh, а перечитывание и запись файла CLI не выполнены.
  Повтор на следующей попытке снова упадёт на маркере. При постоянной причине (нет boot_id) каждый refresh в guarded тратит
  refresh-токен CLI, а пара не записывается: CLI теряет вход. Это ровно S1. Трей ловит исключение как `network` («quota request failed»).
- **Как показать.** В guarded: `mock.patch.object(common, "_rotation_boot_id", side_effect=ValueError)` или STATE_DIR `chmod 500`.
  Даём `fetch_claude()` с истекающим access и ответом 200 от `/oauth/token`. Ожидаемо: исключение из `fetch_claude`, `_PENDING["claude"]`
  непуст, `~/.claude/.credentials.json` не изменён. Каждый следующий `fetch_claude()` ведёт себя так же.
- **Фикс (на выбор, лучше первый).** (a) Ставить маркер **до** POST `/oauth/token` в guarded-ветке. Если маркер не записался — вернуть
  `error/credentials` без POST: fail-closed, ничего не потеряно. Если POST не дал пары — снять маркер. После POST точек отказа маркера
  уже нет. (b) Минимально: в `_save_*_guarded` обернуть `write_rotation_marker` в `try/except (OSError, ValueError)` и **продолжить
  сохранение** (пара в файле — главная защита), а сбой маркера отметить перечислимым O1-событием без текста исключения. Тест:
  отказ маркера при создании, `fsync`, `replace` и boot_id → файл CLI получает новую пару или `_PENDING` переживает попытку, исключение
  из `fetch_*` не выходит.

## Долг, решённый Юркой (Sol считает major, я — не блокер A2)

### D1 · `linux/ccl/limits.py:367` — `flush_pending()` не подключён к выходу процесса · Sol: major, Opus: долг до B1
Сам helper корректен. Он берёт `quota` и работает по исходной политике `guarded`. POST не шлёт. Пару перечитывает, так что `superseded`
не перезаписывается. При неудаче пишет `pending_rotation_lost`, снимает маркер и выкидывает запись из `_PENDING`. Если `quota` занят,
пары не трогает. Production-вызовов нет: в трее «Выход» — это `qapp.quit`, перезапуск после обновления — `os.execv`. Регрессии нет.
По умолчанию работает `never`, и `_PENDING` пуст по построению. В guarded opt-in пара теряется при выходе так же, как до A2.
Поэтому решение Юрки (A3 у издателя, B1 у трея) принимаю. **Условия для B1, записать в plans:**
1. Порядок: остановить новые попытки → дождаться воркеров → `flush_pending()` → `quit`/`execv`. Одного `atexit` мало: он не срабатывает при `execv`.
2. Не вызывать из UI-потока с ожиданием `quota` до 60 с — будет заморозка на выходе. Нужен воркер или короткий таймаут.
3. A2-07 вызывает helper вручную. Нужен тест штатного выхода трея.

В A2 сейчас ничего добавлять не нужно.

## Minor / nit (по строке)

- **m1** · minor · `limits.py:71` `_quota_busy` → `READ_ERROR`/`credentials`. В трее занятый замок показывается как «Сбой доступа к входу · проверьте ~/.claude/.credentials.json» (`panel.py:332`), и прежние значения скрыты. Ошибка в классе: замок — не вход. Когда случается: ручное обновление запускает оба воркера разом, Codex ждёт Claude. Медленное тело до 16 МиБ при `timeout=15` на каждый recv может растянуть попытку дольше 60 с. Фикс: отдельный `failure_kind="busy"` с `auth=OK`, класс как у сети, значения сохраняются. · Opus
- **m2** · minor · `limits.py:47–60`, `cli.py:212` — `PermissionError`/`OSError` при открытии `quota.lock` вылетает из всех публичных `fetch_*`/`codex_access_token`. В трее это превращается в `network`. Сбой `settings().set` в `cmd_credentials` даёт traceback. Фикс: вернуть `error/credentials` и ненулевой код CLI с понятным текстом, текст исключения не печатать. · Sol (проверено)
- **m3** · minor · `gui/app.py:1317` (было до дифа; флаг из дифа не работает): `on_limits` вызывает `select_snapshot(data, previous)` раньше `apply_provider_cache`. `fallback` копирует старые значения в результат `_signed_out_no_values`, и проверка в `apply_provider_cache:834` уже ничего не решает. Панель при `loggedOut` значения прячет, но они идут в `history.record`/`check_alarms`/feedback. Фикс: учитывать signed-out до любого fallback, внутри `select_snapshot` или в `on_limits`. Обязательно до A3, иначе издатель опубликует значения прошлого аккаунта. · Sol (проба `on_limits`) + Opus (чтение `quota_refresh.py:162–186`)
- **m4** · minor · `common.py:358–382`, `cli.py:214` — повреждённый маркер (`{`, `{}`, симлинк → `ELOOP`) считается живым навсегда. Это правильный fail-closed, но сообщение неверное: «retry after CLI sign-in refresh». Повторный вход CLI маркер не снимает, путь к файлу не назван. Фикс: различать «живой pid» и «маркер не читается» в тексте. Во втором случае назвать `STATE_DIR/rotation-pending-<p>` и дать путь восстановления: «остановите трей/издатель и удалите файл». Возможна и авто-эвристика: `st_mtime` раньше времени загрузки (`btime` из `/proc/stat`) → маркер мёртвый. · Opus + Sol
- **m5** · minor · `limits.py:678–681` — `account_id`, не прошедший `[0-9a-z-]{8,64}`, теперь даёт `LOGGED_OUT` «CLI sign-in required». В `never` это ещё и `_signed_out_no_values`, то есть без rollout-fallback и без значений. До A2 такой id работал. Текст вводит в заблуждение: человек вошёл. Фикс: невалидный id → `account=None` (метки нет, как в `accounts.read_local_id` → `no_account_uuid`), а запрос usage идёт с исходным stripped-значением. Регулярку брать из `accounts`, не дублировать. · Opus
- **m6** · minor · `limits.py:282–293` — в `never` непустой `_PENDING` (остался от guarded, потом `settings.json` поправили руками) не снимается, даже если CLI уже сам обновил пару. Маркер живёт до выхода процесса, и `credentials --write` отказывает. Фикс: в `never` можно без записи сделать `pop` и снять маркер, если в файле `refreshToken != p["old"]`. Это чтение, guard не нарушается. · Opus
- **m7** · minor · `common.py:385–399`, `cli.py:216` — `credentials --write guarded` при `publisher: true` сохраняется и печатает «saved: guarded», хотя действует `never`. Фикс: в выводе добавить «(издатель: принудительно never)». · Opus
- **n1** · nit · `common.py:294` — `policy_forced_never` пишется на каждой попытке и каждом `status`, но только при сочетании `guarded + publisher:true`. Рост `publisher.jsonl` ограничит ротация O1 из A3 (П6-а, A3-17). Дедуп — на A3: писать при смене или раз на проход. · Opus + Sol
- **n2** · nit · `cli.py:239–244` — политика и пометка издателя берутся из двух разных чтений `settings.json`: `credential_write()` и `settings().reload()`. Между ними возможна гонка, но побочный эффект `reload()` безвреден: CLI — отдельный процесс, а Store на чтение ничего не теряет. Фикс: отдавать `(policy, forced)` из одного чтения. · Opus + Sol
- **n3** · nit · `limits.py:452–458` — если `remove_rotation_marker` бросит `OSError` после удачной записи, вернётся `"pending"` при уже сохранённом файле. Самоизлечится на следующей попытке через ветку `pop`. Фикс: снимать маркер вне `try` записи. · Opus
- **n4** · nit · `limits.py:663–670` — guarded Codex читает `auth.json` один раз через `common.read_json`, never и Claude читают с повтором 5×0,2 с. Асимметрия оправдана только ограничением A2-06: `test_manual_refresh.py` не менять. Эксплуатационного смысла в ней нет: в guarded половинчатый файл даёт ложный `readError`. Долг: общий читатель с повтором и правка guarded-фикстур отдельным решением. · Opus + Sol
- **n5** · nit · `limits.py:703–705` — в `never` access без разбираемого JWT `exp` всегда считается истёкшим: 0 запросов. Это fail-safe, но при смене формата токена Codex карточка навсегда покажет `cli_refresh_pending`. Зафиксировать в доке. · Opus

## Ответы 1–9

| № | Вердикт | Место · вывод · фикс |
|---|---|---|
| 1 | **ok для A2 / minor m5** | `limits.py:677–681`. Нормализация совпадает с `accounts.read_local_id`. Реальный id — UUID в нижнем регистре, так что `lower` ничего не меняет. Upstream Codex шлёт значение в заголовок как есть (Sol). Безопаснее слать в `chatgpt-account-id` исходное stripped-значение, а нормализованное держать только в `account`: A2-11 на lowercase-фикстуре от этого не сломается. Невалидный id → m5. |
| 2 | **ok** | Единственный production-вызов — `gui/app.py:1292` в daemon-потоке воркера. Из UI-потока Qt никто не вызывает. CLI и sync провайдеров не опрашивают. Дедлока нет: вложенные вызовы идут через `_ATTEMPT.policy` / `lock_held_by_thread` (thread-local), а два воркера одного процесса сериализуются flock на разных fd, как и задумано. Остаётся класс ошибки при занятом замке → m1. На будущее: `flush_pending` и A3 не должны ждать `quota` в UI-потоке (D1 п. 2). |
| 3 | **debt** | `common.py:294`. Только при `guarded + publisher:true`. Ограничение — ротация O1 в A3, дедуп туда же (n1). |
| 4 | **bug → M1** | Трей ловит исключение как `network`, и пара не записывается. CLI fetch не вызывает. |
| 5 | **debt → m4** | Fail-closed верен, но сообщение и путь восстановления нужны. |
| 6 | **debt → D1** | Логика верна. Подключение к выходу оставляем на A3/B1 с тремя условиями. В A2 ничего не нужно. |
| 7 | **debt → n4** | Обосновано только A2-06; свести к одному читателю позже. |
| 8 | **ok** | `common.py:111–115`. При первом создании `ensure_dirs()` → `makedirs(mode=0o700)`. Существующие каталоги не chmod-ились и раньше. `Store._write` по-прежнему зовёт `ensure_dirs()`. Регрессии нет. |
| 9 | **ok (nit n2)** | `reload()` обновляет синглтон процесса CLI, кеш трея не задевает. |

## Общий проход
- **Guard во всех путях записи файлов входа.** В `limits.py` в файлы входа пишет только `_rewrite_json` (`:455`, `:639`), и он под guard. `write_json`/`write_atomic` на `:847`, `:921` и `open(..., "a")` на `:944` пишут cache и history, это не файлы входа. `st.set("deadRefresh"/"deadCodexRefresh")` (`:338`, `:726`) достижимы только в guarded. **ok.**
- **Токены и email в O1/`status`.** `credential_policy_event` принимает только перечислимые поля. `status` печатает политику, без id. `LimitData.account` в `to_dict` не попадает, в `cache.json` его нет. `flush_pending` текст исключения не логирует. **ok.**
- **Регресс guarded.** `test_manual_refresh.py` и `test_limits.py` зелёные, A2-06 соблюдён. **ok.**
- **R1/§5.** `limits.py:324`, `:348`, `:721`, `:753` — `follow_redirects=False` + `max_body=16 МиБ`. `update.py:215`, `:238` — caps. **ok.**
- **Исключения.** M1, m2.

## Codex-проход
Запускался: `codex exec -m gpt-6.1-sol` @high, `service_tier=default`, read-only, exit 0. Sol нашёл и я проверил: M1 (совпало с моей
находкой), D1 (Sol — major), m2, m3 (Sol гонял `on_limits`), m4. Ответы 1–9 у Sol совпадают с моими. Расхождение одно: D1 Sol хочет
закрыть в A2, я принимаю решение Юрки с условиями для B1.

## Security
Проблема одна — M1, нарушение инварианта S1 в guarded opt-in. Остальное чисто: guard во всех путях, R1 закрыт, O1 без секретов.

**Security surface: да.** Диф трогает обработку токенов OAuth и запись в файлы входа CLI (`~/.claude/.credentials.json`,
`~/.codex/auth.json`), политику доступа к ним, межпроцессный замок и маркеры в `STATE_DIR`, а также сетевые запросы к провайдерам с
Bearer (редиректы, лимиты тела). → T2: `security-analyst` до мержа.

**Вердикт:** нужен 1 цикл правок (M1 + желательно m1, m2, m4, m5). D1 — в plans как вход в B1. m3 — до A3.
