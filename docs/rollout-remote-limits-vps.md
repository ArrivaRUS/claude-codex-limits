# REMOTE-LIMITS A5: выкатка издателя лимитов на VPS

Пошаговая инструкция вехи A5 (`docs/plans.md` §A5). Выкатку проводят Юрка и владелец вместе. Кода в A5 нет: ставим
издатель из среза A, сутки смотрим журнал и делаем ручные сверки T1 §7. Результаты записываем в
`docs/remote-limits-verification.md` (формат — `docs/test-plan-remote-limits.md` §3) и строкой в `docs/status.md`.

Источники: `docs/plans.md` §A4/§A5, `arch/plan-synth.md` §C (проход, таймер, «Установка (P2)»), §E (политика токенов),
`docs/security-remote-limits.md` §7, `docs/review-remote-limits-a4.md` (r1/r2), `docs/sync-protocol.md` (v1.1, журнал O1,
приватность), `linux/install.sh`, `linux/uninstall.sh`, `linux/ccl/cli.py`, `linux/ccl/common.py`.

Правила для всех команд ниже:

- Каждую команду запускают от пользователя, под которым работают Claude Code и Codex CLI (у него `~/.claude`,
  `~/.codex` и Linger). Через `ssh`, не через `sudo`.
- Содержимое файлов входа (`~/.claude/.credentials.json`, `~/.codex/auth.json`) и токена GitHub
  (`~/.config/claude-codex-limits/github-token*`) не печатаем. Разрешены только `stat`, `ls -l` и счётчики.
- В выводе `ccl-sync status` есть строка `Gist: https://gist.github.com/…`. Это ссылка-доступ ко всему gist (T1 П6-б),
  поэтому в чаты, отчёты и коммиты она не попадает. Везде ниже вывод фильтруется через `grep -v '^Gist: '`.
- Пути даны для XDG по умолчанию. Если на VPS заданы `XDG_CONFIG_HOME`/`XDG_STATE_HOME`, сверяйтесь со строкой
  «Каталог состояния:» в `ccl-sync status`.

---

## 0. Предусловия (СТОП, пока хоть один пункт не выполнен)

1. **Долг ИБ закрыт.** Пройдены T2 по `babf8ec` и по A4 (`242e305..d0b06b2`), восемь пунктов из
   `docs/review-remote-limits-a4.md` («Список для отложенного T2», r1 и r2), а также Codex-проход по тому же дифу.
   Исключение одно: владелец отдельно сказал «да» на выкатку с пропущенным T2 (HEARTBEAT, решение 2026-10-15).
   Тогда пропущенные пункты идут в отчёт отдельным списком-долгом.
2. **«Да» владельца на A5** получено в чате. Это СТОП-точка.
3. **Ревизия зафиксирована.** Это коммит, на котором закрыт долг T2 (если после T2 были правки, то последний из них).
   На момент написания код издателя не менялся после `d0b06b2`: `git diff d0b06b2..e28793f -- linux Resources` пуст.
   Ставим именно из этой ревизии, а не из рабочего дерева.
4. **Владелец на связи.** Он делает `ccl-sync login` (Device Flow).
5. **Решения T1 §7 п. 5:**
   - П4-б: gist не пересоздаём (решение владельца 2026-10-12, `decisions/log.md`). В истории ревизий остаются старые
     имена машин из v1.
   - П6-б: по HEARTBEAT от 2026-10-12, `~/.codex` уже переведён в 0700. Проверка — в шаге 1.

## 1. Состояние VPS перед стартом

**Факт на 2026-10-15** (проверил Юрка, только чтение): Claude Codex Limits на VPS **не установлен вовсе**:
- нет `~/.local/share/claude-codex-limits`, `~/.config/claude-codex-limits` и `~/.local/state/claude-codex-limits`;
- нет ярлыков и автозапуска;
- нет юнитов `ccl-sync.*` в `~/.config/systemd/user`;
- нет `ccl-sync` в `PATH`;
- нет процесса трея;
- нет пакета в dpkg.

Из HEARTBEAT и PRD (2026-10-12): Ubuntu 26.04, XFCE на `:20`, `Linger=yes`, нет PyQt5 и secretstorage. Файла VPS в
gist нет. Значит, A5 — **чистая установка**: останавливать трей и бэкапить прежние настройки не нужно.

Упоминания «трей 0.4.5 на `:20`» в `arch/plan-synth.md` §C (и риск 9) и в `docs/review-remote-limits-a4.md` устарели.

**Перепроверка в день выкатки.** Если между проверкой и стартом что-то поставили, ниже ожидаются строки `нет`:

```bash
for p in ~/.local/share/claude-codex-limits ~/.config/claude-codex-limits ~/.local/state/claude-codex-limits ~/.config/systemd/user/ccl-sync.timer ~/.config/autostart/claude-codex-limits.desktop ~/.local/share/applications/claude-codex-limits.desktop; do [ -e "$p" ] && echo "ЕСТЬ $p" || echo "нет  $p"; done; command -v ccl-sync || echo "нет  ccl-sync в PATH"; pgrep -u "$(id -u)" -f '(^|[/ ])claude-codex-limits( |$)' >/dev/null && echo "ЕСТЬ процесс трея" || echo "нет  процесса трея"; dpkg-query -W claude-codex-limits >/dev/null 2>&1 && echo "ЕСТЬ пакет .deb" || echo "нет  пакета .deb"
```

Если хоть одна строка начинается с `ЕСТЬ`, это уже не чистая установка: выполните шаг 2 и сообщите Юрке до шага 4.

Linger и часы. Ожидается `Linger=yes` и `NTPSynchronized=yes`: расхождение часов больше 60 с ломает гарантию пола
900 с (риск 6 в синтезе).

```bash
loginctl show-user "$(id -un)" -p Linger; timedatectl show -p NTPSynchronized
```

XDG-каталоги ssh-шелла и user manager (T2 §5 п. 2). Таймер работает в user manager, а команды этой инструкции — в
ssh-шелле. Если каталоги у них разные, издатель пишет не туда, куда смотрят проверки §6–§8. Сначала шелл:

```bash
env | grep -E '^XDG_(CONFIG|STATE|DATA)_HOME='
```

Затем user manager:

```bash
systemctl --user show-environment | grep -E '^XDG_(CONFIG|STATE|DATA)_HOME='
```

Ожидается: оба вывода пусты или строки совпадают. Если расходятся — остановитесь и сообщите Юрке до шага 4.

> **Внимание.** `systemctl --user show-environment` и `env` печатают всё окружение. В окружение менеджера могут быть
> импортированы секреты (токены, пароли). Запускайте их **только** с фильтром `grep -E` выше, ровно в этом виде.
> Без фильтра, с `| less`, с другим шаблоном или «посмотреть целиком» — нельзя: вывод может попасть в чат или отчёт.

Права на каталоги CLI. Для `~/.codex` ожидается `700` (П6-б).

```bash
stat -c '%a %U %n' ~/.claude ~/.codex
```

## 2. Только если перепроверка что-то нашла: остановить трей и сохранить прежнее

При чистой установке шаг пропускается.

- **Найден процесс трея.** `install.sh --publisher` при живом трее этого пользователя **отказывает** (код 3) и
  печатает команду остановки. Перезапуск он не делает (T1 П3-б.3, тест A4-02).
  - Лучший способ остановки — владелец на `:20` выбирает в меню значка пункт **«Выход»**: так трей не прерывается
    посреди возможной ротации токена (T1 П3-б).
  - Иначе используйте команду, которую печатает установщик:

```bash
pkill -u "$(id -u)" -f '(^|[/ ])claude-codex-limits( |$)'
```

- **Найдены каталоги, юниты или ярлыки прежней установки.** Сохраняем их до установки, чтобы было куда откатиться.
  Если в архив попадёт копия токена GitHub, его удаляет владелец, когда окно отката закрыто.

```bash
BKOLD=~/ccl-a5-prev-$(date +%Y%m%d-%H%M); mkdir -m 700 "$BKOLD"; for p in .config/claude-codex-limits .local/state/claude-codex-limits .local/share/claude-codex-limits .local/bin/ccl-sync .local/bin/claude-codex-limits .config/systemd/user/ccl-sync.service .config/systemd/user/ccl-sync.timer .config/autostart/claude-codex-limits.desktop .local/share/applications/claude-codex-limits.desktop; do [ -e "$HOME/$p" ] && printf '%s\n' "$p"; done > "$BKOLD/paths.txt"; (umask 077; tar -C "$HOME" -czf "$BKOLD/ccl-before.tgz" -T "$BKOLD/paths.txt"); ls -l "$BKOLD"
```

- **Найден пакет `.deb`.** Его глобальный `ccl-sync.timer` перекроется одноимённым юнитом пользователя. Установщик
  предупредит строкой «Внимание: уже установлен пакет…».

## 3. Снимок «до» (файлы входа)

Каталог для снимков и результатов проверок закрыт для чужих (0700). В нём же в шаге 7.4 окажется копия файла VPS
из gist.

```bash
BK=~/ccl-a5-$(date +%Y%m%d-%H%M); mkdir -m 700 "$BK" && echo "$BK"
```

Снимок файлов входа: время, размер и inode, без содержимого (T1 §7 п. 1, тест-план §3 п. 1).

```bash
stat -c '%y %s %i %n' ~/.claude/.credentials.json ~/.codex/auth.json | tee "$BK/creds-before.txt"
```

## 4. Установка издателя

Дерево берём из зафиксированной ревизии (предусловие 3), отдельной копией: на установку не должны влиять
незакоммиченные правки рабочей копии. `install.sh` копирует `linux/` и `Resources/`, поэтому нужны оба каталога.

```bash
REPO=~/VibeCoding2/2026_06_UsageLimits; REV=<ревизия из предусловия 3>
```

```bash
git -C "$REPO" cat-file -e "$REV^{commit}" && git -C "$REPO" log -1 --format='%h %s' "$REV"
```

```bash
SRC=$(mktemp -d ~/ccl-a5-src.XXXXXX) && git -C "$REPO" archive "$REV" linux Resources | tar -x -C "$SRC" && echo "$SRC"
```

```bash
sh "$SRC/linux/install.sh" --publisher --no-tray --name vps
```

**Ожидаемый вывод** (`linux/install.sh`; строки в квадратных скобках появляются не всегда):

```
[Внимание: уже установлен пакет claude-codex-limits (.deb). …]   ← только если стоит .deb
Копирую в /home/<user>/.local/share/claude-codex-limits
Издатель: включён, тег машины vps, политика токенов never
Таймер: systemd --user (ccl-sync.timer), каждые 5 минут

Готово. Дальше:
  ccl-sync login      — войти в GitHub (один раз), затем расход этой машины увидит Mac
  ccl-sync status     — кто вошёл и какие машины в gist
[Внимание: /home/<user>/.local/bin нет в PATH — …]
```

С `--no-tray` строки про PyQt5 и автозапуск не печатаются.

**Отказы до записи на диск:**
- код 2 — неверный `--name` или `--name` без `--publisher`;
- код 3 — запущен трей (печатается `pkill …`, вернитесь к шагу 2) либо нет `pgrep`/он упал.

**Отказ после копирования программы, до таймера:** код 1 с текстами «Значок или издатель сейчас заняты попыткой
(замок quota) — повторите установку позже.», «Политику токенов сейчас сменить нельзя: …» или «Не удалось сохранить
настройки; …» и строкой «Настройки издателя не записаны — таймер не устанавливаю.». Таймер в этом случае не ставится.

**Что делает установка:**
- копирует программу в `~/.local/share/claude-codex-limits/` и обёртки в `~/.local/bin/`;
- под замком `quota` пишет в `settings.json`: `publisher: true`, `credential_write: "never"`, `machineName: "vps"`,
  `tray: false`; `autoPoll: true` — только при первом включении издателя;
- удаляет `~/.config/autostart/claude-codex-limits.desktop` и `~/.local/share/applications/claude-codex-limits.desktop`;
- пишет `~/.config/systemd/user/ccl-sync.{service,timer}`:
  - в сервисе `ExecStart=/usr/bin/python3 "…/ccl-sync" push --auto --quiet` и `TimeoutStartSec=20min`;
  - в таймере `OnBootSec=2min`, `OnUnitActiveSec=5min`, `AccuracySec=1min`;
  - включает таймер: `enable --now`.


**До входа в GitHub опросов нет.** `ccl-sync push --auto` без входа выходит сразу (`cli.py:664-667`).

## 5. Вход в GitHub (делает владелец)

Запускать в `ssh`-сессии. С `--no-browser` браузер на рабочем столе VPS не открывается, ссылку владелец открывает
у себя.

```bash
ccl-sync login --no-browser
```

**Что увидит владелец** (`cli.py:63-115`):

```
Откройте в браузере:  https://github.com/login/device
и введите код:        XXXX-XXXX
(доступ к gist и автоматическое продление входа для синхронизации расхода)
Жду подтверждения…
Готово. GitHub: <логин>  (токен в файле /home/<user>/.config/claude-codex-limits/github-token)
Claude: опрос можно с HH:MM
Codex: опрос можно с HH:MM
Проход издателя завершён.
```

- Код одноразовый и короткоживущий, его не пересылают в чаты.
- После «Готово» сразу идёт ручной проход издателя (`manual`). Строки «опрос можно с» печатаются только для продуктов,
  у которых следующий срок в будущем.
- Если вход уже был, печатается «Уже выполнен вход в GitHub: <логин>. Выйти: ccl-sync logout», и прохода нет.
  Тогда первый проход запускаем вручную:

```bash
ccl-sync publisher --now
```

- «Проход издателя не завершён; подробности в журнале издателя.» с кодом 1 означает, что проход упал. Класс ошибки
  смотрим в шаге 6 (событие `pass_failed`).
- Токен должен лежать **в файле** (S4, PRD P1). Если в скобках написано «токен в хранилище секретов», вход сделан
  из сессии с Secret Service. Это вне плана, вопрос к Юрке до продолжения.

## 6. Проверки сразу после входа

Программа взята из нужной копии:

```bash
command -v ccl-sync; ccl-sync --version
```

Ожидается `/home/<user>/.local/bin/ccl-sync` и `ccl-sync (linux) 0.4.5`. Версию в срезе A не поднимали, см.
«Ограничения».

```bash
ccl-sync status | grep -v '^Gist: '
```

**Ожидаемые строки** (`cli.py:417-529`; порядок как в выводе):

```
Claude Codex Limits (linux 0.4.5)
Эта машина: vps · <ОС> · id <uuid machine-id>
Политика токенов: never (издатель: принудительно never)
Каталог состояния: /home/<user>/.local/state/claude-codex-limits
Claude · за 24 ч: запросов N, 429 — 0
Codex · за 24 ч: запросов N, 429 — 0
Публикации · за 24 ч: неудачных 0
[Расхождение часов с GitHub: S с]          ← только если в sync-state есть clockSkew
GitHub: <логин>  (токен: /home/<user>/.config/claude-codex-limits/github-token)
Автосинхронизация: systemd --user, каждые 5 мин
Последняя отправка: HH:MM · чтение: HH:MM
Последняя попытка: HH:MM
Машины в gist:
  • vps (эта) — <ОС>, linux 0.4.5, обновлён HH:MM
  • <мак> — …
  • <ThinkPad> — …
Индекс: N файлов · /home/<user>/.local/state/claude-codex-limits/usage-index.json
```

Признаки проблемы:
- строка «Последняя ошибка (…): ошибка синхронизации, подробности — ccl-sync push»;
- строка, начинающаяся с `! `;
- нет `vps (эта)` в списке машин;
- «Автосинхронизация: не установлен».

Тексты ошибок и токен `status` не печатает (П6).

```bash
ccl-sync publisher --status
```

Ожидается (`cli.py:404-414`):

```
Издатель: включён
Продукты: Claude, Codex
Режим: авто
Политика токенов: never
Автосинхронизация: systemd --user, каждые 5 мин
```

Юниты и таймер:

```bash
systemctl --user is-enabled ccl-sync.timer; systemctl --user is-active ccl-sync.timer
```

```bash
systemctl --user list-timers ccl-sync.timer --all --no-pager
```

```bash
systemctl --user cat ccl-sync.service ccl-sync.timer --no-pager | grep -E '^(ExecStart|TimeoutStartSec|OnBootSec|OnUnitActiveSec|AccuracySec)='
```

Ожидаются ответы `enabled` и `active`. В `list-timers` должна быть строка `ccl-sync.timer` → `ccl-sync.service`
со следующим срабатыванием в пределах ~5 мин. Сверить на живой системе: сработает ли первый тик сразу после
`enable --now` или только через `OnUnitActiveSec`. Значения юнитов — как в шаге 4.

Настройки издателя (ревью A4 r2: `tray: false`):

```bash
python3 -I -c 'import json,os; s=json.load(open(os.path.expanduser("~/.config/claude-codex-limits/settings.json"))); print({k: s.get(k) for k in ("publisher","autoPoll","credential_write","machineName","tray")})'
```

Ожидается `{'publisher': True, 'autoPoll': True, 'credential_write': 'never', 'machineName': 'vps', 'tray': False}`.
При переустановке поверх уже включённого издателя `autoPoll` остаётся прежним.

Автозапуска и ярлыка меню нет (ревью A4 r2). Ожидается ошибка «нет такого файла» (`No such file or directory`) для обоих путей:

```bash
ls -l ~/.config/autostart/claude-codex-limits.desktop ~/.local/share/applications/claude-codex-limits.desktop 2>&1
```

Права файлов. Ожидаются каталоги `700`; `settings.json`, `machine-id`, `github-token`, `publisher.jsonl` и
`sync-state.json` — `600`. Владелец везде — пользователь VPS.

```bash
stat -c '%a %U %n' ~/.config/claude-codex-limits ~/.config/claude-codex-limits/settings.json ~/.config/claude-codex-limits/machine-id ~/.config/claude-codex-limits/github-token* ~/.local/state/claude-codex-limits ~/.local/state/claude-codex-limits/publisher.jsonl ~/.local/state/claude-codex-limits/sync-state.json
```

Вход в gist в течение 15 минут (PRD RL-4) проверяется так: в `ccl-sync status` есть строка `• vps (эта) …` со
свежим «обновлён». Сам файл машины смотрим глазами в шаге 7.

## 7. Сутки работы: что смотреть

Примерно через 24 ч после входа делаем всё ниже. Промежуточные проверки — те же команды.

### 7.1 Журнал издателя O1 (`publisher.jsonl`)

Скрипт ниже только читает файл и печатает размер, сводку событий за 24 ч по перечислимым полям, число запросов
и пар меньше 900 с на продукт, а также самую длинную серию `publish failed` подряд. В журнале по контракту нет ни
токенов, ни идентификаторов (`sync-protocol.md`, «Publisher journal»).

**Зазоры G1 скрипт считает по `ts` события `poll_attempt`, а не по полю `attemptAt`** (T2 §5 п. 3, находка N1).
Событие `poll_attempt` пишется непосредственно перед вызовом провайдера, поэтому его `ts` — фактический старт
запроса. `attemptAt` в ревизиях до цикла правок A4 №2 — время резерва, общее для всех продуктов прохода. Если
второй запрос начался позже и проход убили, по `attemptAt` пара выглядит как ≥ 900 с, хотя фактически короче.
После цикла правок A4 №2 время попытки ставится перед каждым вызовом провайдера, и `attemptAt` совпадёт с `ts`.
Скрипт берёт `ts` в любой ревизии. `ts` пишется с точностью до секунды.

```bash
python3 -I - <<'EOF'
import calendar, collections, json, os, time
state = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"), "claude-codex-limits")
path = os.path.join(state, "publisher.jsonl")
print("размер журнала, байт:", os.stat(path).st_size, "(предел 1048576)")
now, events, attempts, run, worst = time.time(), collections.Counter(), collections.defaultdict(list), 0, 0
for line in open(path, "rb"):
    try:
        r = json.loads(line)
        t = calendar.timegm(time.strptime(r["ts"], "%Y-%m-%dT%H:%M:%SZ"))
    except Exception:
        events["(нечитаемая строка)"] += 1
        continue
    if not now - 86400 < t <= now:
        continue
    events["/".join(str(r[k]) for k in ("ev", "product", "reason", "result", "httpStatus", "class") if k in r)] += 1
    if r.get("ev") == "poll_attempt":
        attempts[r.get("product")].append(t)
    if r.get("ev") == "publish":
        run = run + 1 if r.get("result") == "failed" else 0
        worst = max(worst, run)
for k in sorted(events):
    print("%-44s %d" % (k, events[k]))
for p, xs in sorted(attempts.items()):
    xs.sort()
    gaps = [b - a for a, b in zip(xs, xs[1:])]
    print("%s: запросов %d, пар < 900 с: %d, мин. интервал, с: %s" % (p, len(xs), sum(g < 900 for g in gaps), int(min(gaps)) if gaps else "-"))
print("самая длинная серия publish/failed подряд:", worst)
EOF
```

**Норма (гейты A5, `docs/plans.md`):**

| Что | Норма | Где в выводе |
|---|---|---|
| Размер журнала | < 1 МиБ (ротация сжимает до ≤ 512 КиБ) | первая строка |
| G2: запись в файлы входа | **0** событий `token_refresh` (только у них `credentialWrite=1`) | строки `token_refresh/…` отсутствуют |
| Нарушение политики | **0** `policy_violation`, 0 `pending_rotation_lost` | строки отсутствуют |
| G1: пары по аккаунту | 0 пар < 900 с на продукт | «пар < 900 с: 0» |
| G1: запросы в простой | ≤ 10 за сутки на продукт, если команда сутки не работала | «запросов N». При активной работе Auto держит 15 мин, и запросов больше: это норма |
| 429 | 0 | нет строк `poll_result/<продукт>/failed/429` |
| Публикация | нет серий `publish/failed` (≥ 3 подряд — уже проблема: опрос уходит на своё расписание) | «самая длинная серия» ≤ 2; `poll_skipped/…/publish_failed` — единицы |
| Падения прохода | 0 `pass_failed/<класс>` | строки отсутствуют |
| Часы | `clock_skew` отсутствует (иначе расхождение > 60 с) | строки `clock_skew` |

Нормальные причины пропуска — `poll_skipped/<продукт>/not_due`, `…/fresh_remote`, `…/remote_attempt`,
`…/tie_break` и `…/retry_after`. `…/token_policy` означает, что токен CLI истёк, а издатель ждёт, пока CLI обновит его
сам (политика `never`). Это ожидаемо, если CLI простаивал.

G1 считается по аккаунту. На VPS один аккаунт на продукт, поэтому пары по продукту равны парам по аккаунту, пока в
журнале нет `identity_changed`.

Счётчики 24 ч дублирует `ccl-sync status`: строки «Claude · за 24 ч», «Codex · за 24 ч» и «Публикации · за 24 ч:
неудачных».

### 7.2 Файлы входа: `stat` до и после (T1 §7 п. 1)

```bash
stat -c '%y %s %i %n' ~/.claude/.credentials.json ~/.codex/auth.json | tee "$BK/creds-after.txt"; diff "$BK/creds-before.txt" "$BK/creds-after.txt" && echo "без изменений"
```

Если `BK` в новой сессии не задан, задайте его заново: `BK=~/ccl-a5-<дата-время>` (каталог из шага 3).

Изменения допустимы только там, где их объясняет сам CLI: Claude Code и Codex обновляют свои токены сами. Сверяйте
с активностью команды и с тем, что в 7.1 ноль `token_refresh` и ноль `policy_violation`. Журнал пишет тот же UID,
поэтому сам по себе он не доказательство (T1 П3-в). Сверку делает Юрка руками.

Повторных входов в Claude Code и Codex за сутки быть не должно (G2). Это проверяем у владельца: не просили ли CLI
войти заново.

### 7.3 journald сервиса (T1 §7 п. 3)

Число строк и попаданий по маскам секретов. Печатаются только счётчики.

```bash
journalctl --user -u ccl-sync --since -24h --no-pager | wc -l
```

```bash
journalctl --user -u ccl-sync --since -24h --no-pager | grep -c -E 'eyJ|sk-|gh[opusr]_|access_token|refresh_token|Bearer|@'
```

```bash
journalctl --user -u ccl-sync --since -24h --no-pager | grep -c -E 'Traceback|Failed with result'
```

- Ожидается 0 во второй и третьей командах.
- Если во второй не 0, смотрим только номера строк, не печатая их: добавьте `| grep -n -E '…' | cut -d: -f1`
  вместо `grep -c`. Затем разбирается Юрка.
- Если первая команда даёт 0 строк при работающем таймере, сверьте, ведётся ли пользовательский журнал (`Storage=`
  в настройках journald).

### 7.4 Файл машины VPS в gist (T1 §7 п. 2) и размер ответа (риск 1)

ID gist и машины кладём в переменные и не печатаем. `gh` на VPS залогинен под учёткой владельца (HEARTBEAT).

```bash
GID=$(python3 -I -c 'import json,os; print(json.load(open(os.path.expanduser("~/.local/state/claude-codex-limits/sync-state.json")))["gistId"])'); MID=$(cat ~/.config/claude-codex-limits/machine-id); echo "gist и machine-id прочитаны"
```

Риск 1: в `history` не больше 30 записей, ответ `GET /gists/{id}` не больше 100 КБ (102 400 байт). По замеру
2026-10-12 при трёх файлах было 56 895 байт. Замер делаем сразу после входа и через сутки: рост сверх нескольких КБ
на новый файл — повод разбираться.

```bash
gh api "gists/$GID" --jq '.history | length'
```

```bash
gh api "gists/$GID" | wc -c
```

Файл VPS сохраняем в закрытый каталог бэкапа и смотрим структуру. Если файл больше 1 МБ, API обрезает `content`, и
тогда его надо читать через `raw_url`. Сверить, если `content` окажется пустым.

```bash
(umask 077; gh api "gists/$GID" --jq ".files[\"machine-$MID.json\"].content" > "$BK/vps-machine.json"); wc -c < "$BK/vps-machine.json"
```

```bash
python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(sorted(d)); print(d["machine"]); [print(a.get("product"), a.get("label"), a.get("status"), a.get("expiredReason"), a.get("asOf"), a.get("attemptKind"), a.get("schedule")) for a in d.get("accounts", [])]' "$BK/vps-machine.json"
```

**Ожидается:**
- `machine` = `{'id': <MID>, 'name': 'vps', 'os': …, 'app': 'linux 0.4.5'}`;
- ключи `accounts`, `captions`, `days`, `lastSeenAt`, `machine`, `schema`, `tz`, `unattributedDays`, `updated`
  (`captions`/`unattributedDays` могут отсутствовать);
- в `accounts` по записи на `claude` и `codex` с 16-hex `label` и статусом `ok`, либо `expired` +
  `cli_refresh_pending`.

Проверка приватности. Печатаются только счётчики: для масок ожидается 0, для UUID — ровно 1 (`machine.id`).
Отдельный сканер A1-10 есть только как тест (`linux/tests/test_rl_contract.py`) и готовой команды для скачанного
файла не имеет — сверить, нужен ли он сверх этих счётчиков.

```bash
for pat in '@' '/home/' '/Users/' 'eyJ' 'sk-' 'access_token' 'refresh' 'accountUuid' 'account_id' "$(hostname)" "$(id -un)"; do printf '%-18s %s\n' "$pat" "$(grep -c -F -- "$pat" "$BK/vps-machine.json")"; done
```

```bash
grep -o -E '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' "$BK/vps-machine.json" | sort -u | wc -l
```

`refresh` встречается в разрешённом значении `cli_refresh_pending`. Если счётчик не 0, проверьте, что совпадение
только там.

### 7.5 Старые читатели (мак 3.2.7, ThinkPad 0.4.5)

Мак 3.2.7 и Linux 0.4.5 читают gist по v1: блок `accounts` они игнорируют, а корневые `days` суммируют.
**Карточек лимитов VPS на них не будет**: читатель v1.1 появится в вехах C1–C3 (мак) и во второй очереди (Linux-трей).
В A5 проверяем, что старые читатели не сломались:
- **ThinkPad.** `ccl-sync status | grep -v '^Gist: '` показывает `• vps — …, linux 0.4.5, обновлён HH:MM`. Делает
  Linux-сторона или владелец.
- **Мак.** В настройках синхронизации видна машина `vps`, в «Истории и деньгах» расход ПК включает VPS. Делает
  владелец, сверка — Юрка по скриншоту.

### 7.6 Запись результата

В `docs/remote-limits-verification.md` записываем:
- состояние «до»;
- ревизию;
- вывод проверок 6 и 7, без строки `Gist:` и без ID;
- вердикт по G1, G2 и риску 1.

В `docs/status.md` — одну строку. Каталог `$BK` удаляет владелец после приёмки; токенов в нём нет.

## 8. Откат

До A5 на VPS ничего не стояло, поэтому откат — это удаление издателя. Удаление данных — разрушительное действие:
только с «да» владельца.

### 8.1 Пауза без удаления (быстро)

Настройки, вход и журнал остаются. Сначала выключаем таймер, чтобы не начался новый проход:

```bash
systemctl --user disable --now ccl-sync.timer
```

Выключение таймера **не прерывает проход, который уже идёт**: он может ещё до 20 минут (`TimeoutStartSec`)
обращаться к Anthropic, OpenAI и GitHub. Поэтому останавливаем и сам сервис (SIGTERM, проход завершается сразу):

```bash
systemctl --user stop ccl-sync.service
```

Проверка — ожидается `inactive` (не `activating` и не `active`):

```bash
systemctl --user is-active ccl-sync.service
```

Только после этого запросов к Anthropic, OpenAI и GitHub нет. Вернуть:

```bash
systemctl --user enable --now ccl-sync.timer
```

### 8.2 Удалить издатель

`linux/uninstall.sh` без ключей делает следующее:
- выключает и удаляет `ccl-sync.timer`/`.service` из `~/.config/systemd/user`, затем `daemon-reload`;
- убирает строку cron, если она есть;
- останавливает значок;
- удаляет ярлыки, обёртки в `~/.local/bin` и программу `~/.local/share/claude-codex-limits`.

Настройки (`~/.config/claude-codex-limits`) и состояние (`~/.local/state/claude-codex-limits`) он оставляет.

**Перед удалением остановите идущий проход.** `uninstall.sh` выключает таймер, но не ждёт проход, который уже идёт,
и удаляет программу прямо под ним. Выполните три команды из 8.1 по порядку: выключить таймер, остановить
`ccl-sync.service`, убедиться, что он `inactive`:

```bash
systemctl --user disable --now ccl-sync.timer
```

```bash
systemctl --user stop ccl-sync.service
```

```bash
systemctl --user is-active ccl-sync.service
```

Ожидается `inactive`. Затем удаление:

```bash
sh "$SRC/linux/uninstall.sh"
```

Ожидается строка «Удалено. Настройки и индекс остались в …/claude-codex-limits и ~/.local/state/claude-codex-limits
(--purge — удалить)».

Затем удаляем каталог состояния: журнал O1, индекс, состояние синка и издателя.

```bash
rm -rf ~/.local/state/claude-codex-limits
```

Если `$SRC` из шага 4 уже удалён, распакуйте ту же ревизию заново командой из шага 4.

**Каталог настроек.** В `~/.config/claude-codex-limits` лежат `machine-id`, токен GitHub и `settings.json`.

- **Рекомендуется его оставить**, если издатель, скорее всего, вернётся. Тогда повторная установка возьмёт тот же
  `machine-id` и продолжит тот же файл `machine-<id>.json` в gist.
- **Удалить всё** можно ключом `uninstall.sh --purge` вместо команды выше (остановка таймера и сервиса — та же,
  перед ним). Он дополнительно делает `ccl-sync logout`
  (вход в GitHub удаляется с этой машины) и удаляет оба каталога: настройки и состояние.
  - Новый `machine-id` при будущей установке даст второй файл VPS в gist. Старые читатели будут считать VPS дважды,
    пока старый файл живёт (до 45 дней; `common.py`, `machine_id()`).

```bash
sh "$SRC/linux/uninstall.sh" --purge
```

**Файл VPS в gist** после любого отката остаётся с последними данными: `uninstall.sh` gist не трогает. Убрать его
можно только правкой gist — это решение и руки владельца.

**Если шаг 2 что-то нашёл и сохранил,** после 8.2 верните прежнее из архива. Таймер включайте, только если он был до
A5.

```bash
tar -C "$HOME" -xzf "$BKOLD/ccl-before.tgz" && systemctl --user daemon-reload
```

## 9. Известные ограничения

1. **Значок на VPS при включённом издателе запускать нельзя.** Режим `delegated` (B1) не сделан: любой значок,
   0.4.5 или из этой ревизии, опрашивает сам, и запросы удвоятся. Установщик проверяет значок только в момент
   установки. Ручной запуск `claude-codex-limits` потом ничем не заблокирован.
2. **Карточек лимитов на маке и ThinkPad пока нет.** Это вехи C1–C3 и Linux-читатель второй очереди. До них A5
   видна только как машина `vps` и её расход в суммах.
3. **Codex — общий аккаунт мака и VPS.**
   - Мак 3.2.7 опрашивает Codex сам и не координируется с VPS: координация придёт в C4.
   - Пары запросов меньше 900 с между маком и VPS возможны, а G1 в A5 меряется только по журналу VPS.
   - Если нужно, издатель можно ограничить одним Claude: `ccl-sync publisher --products claude`. Это решение
     владельца.
4. **`credential_write: never` замораживает показания.** Пока CLI не обновил свой токен, публикуются `expired` +
   `cli_refresh_pending` и последние значения с честным `asOf`. Владелец это принял (PRD S1).
5. **Версия не поднята.** `APP_VERSION` = `0.4.5`, поэтому `ccl-sync --version`, `status` и `machine.app` в gist
   показывают `linux 0.4.5`, как у релиза. Отличить издатель можно только по ревизии из шага 4.
6. **`ccl-sync update` на VPS не запускать.** Копия из `install.sh` обновляется из `main` на GitHub, а там кода
   издателя нет: локальный `main` не запушен, `origin/main` = `7637863`. Сейчас версии равны, и `update` ответит
   «Установлена последняя версия». Но опираться на это не надо.
7. **Граница UID** (T1 П3-в). Агенты того же пользователя могут менять `settings.json`, юниты и код в
   `~/.local/share`. Журнал O1 того же UID не доказывает G2, поэтому нужна ручная сверка `stat`.
8. **В `status` есть ссылка на gist** (П6-б). Это ссылка-доступ, вывод фильтруем.
9. **Старые имена машин** v1 остаются в истории ревизий gist (П4-б, gist не пересоздаём).
10. **Счётчики `status` читают только первые 2 МиБ журнала** (nit ревью A4). При исправной ротации журнал не больше
    1 МиБ.
11. **Зависший проход** systemd останавливает через 20 мин (`TimeoutStartSec`). Следующий тик идёт по таймеру.
12. **Необработанное исключение** даёт traceback в journald. Это локальный журнал владельца, допустимо по T1 П6-а;
    в 7.3 считаем их число.
13. Если A5 идёт с «да» владельца до T2, пункты долга T2 (`docs/review-remote-limits-a4.md`) остаются открытыми
    рисками этой выкатки.
