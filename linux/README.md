# Claude Codex Limits для Astra Linux

Linux-порт macOS-приложения из этого репозитория. Эталоном поведения, форматов и формул служит
[`Sources/LimitsMonitor.swift`](../Sources/LimitsMonitor.swift), а общим контрактом с Mac —
[`docs/sync-protocol.md`](../docs/sync-protocol.md).

Порт состоит из двух частей:

| | что делает | нужно |
|---|---|---|
| **`ccl-sync`** | индексирует локальные логи Claude Code и Codex и пишет расход этой машины в ваш секретный gist, откуда его видит Mac (и наоборот) | Python 3 из репозитория ОС, только стандартная библиотека |
| **`claude-codex-limits`** | значок в трее Fly/KDE с процентами лимитов; по клику открывается панель, как на Mac: простой вид или расширенный (темп, столбики за 7 дней, календарь за 35 дней, деньги) | `python3-pyqt5` из репозитория ОС |

Порт проверен на Astra Linux SE 1.8.5 (Python 3.11, PyQt5 5.15, KDE Plasma / Fly). Код совместим
с Python 3.7, который стоит в Astra 1.7. Никаких `pip install` не требуется.

## Установка

```sh
git clone https://github.com/ArrivaRUS/claude-codex-limits.git
cd claude-codex-limits
sh linux/install.sh
```

Всё ставится только в домашний каталог, `sudo` не нужен:

- программы → `~/.local/share/claude-codex-limits/`, команды `ccl-sync` и `claude-codex-limits` → `~/.local/bin/`
- таймер синхронизации раз в 10 минут → `~/.config/systemd/user/ccl-sync.{service,timer}`; если нет `systemctl --user`, используется cron
- автозапуск значка → `~/.config/autostart/claude-codex-limits.desktop`, ярлык в меню приложений
- ключи установщика: `--no-autostart`, `--no-timer`; удаление: `sh linux/uninstall.sh [--purge]`

Скрипты всегда запускаются через системный интерпретатор (`/usr/bin/python3 <скрипт>`). Это
вариант, который работает при включённом контроле интерпретаторов Astra, и бит исполнения на
самих скриптах не нужен.

## Синхронизация с Mac

```sh
ccl-sync login     # один раз: печатает код и ссылку github.com/login/device, ждёт подтверждения
ccl-sync push      # один проход: индекс логов → файл этой машины в gist → чтение остальных
ccl-sync status    # кто вошёл, gist, какие машины в нём и когда обновлялись
ccl-sync dump      # расход по дням и моделям из локальных логов (--days N, --product, --merged, --json)
ccl-sync logout    # удалить токен с этой машины (gist остаётся)
```

Войти можно и из значка: **Настройки → Синхронизация через GitHub → Войти через GitHub**.
Приложение запрашивает у GitHub только доступ к gist. Токен хранится в хранилище секретов
рабочего стола (KWallet или GNOME Keyring через `org.freedesktop.secrets`), а если оно недоступно —
в файле `~/.config/claude-codex-limits/github-token` с правами `0600`. Токен нигде не печатается.

Что уходит в gist: только суммы токенов по продукту, дню и модели за последние 45 дней. Промпты,
пути, названия проектов и id сессий туда не попадают. На Mac эти данные появляются в расширенном
виде: в «Истории и деньгах» ПК складываются, а в настройках синхронизации видна эта машина.

## Откуда берутся цифры

- **Лимиты в процентах** общие для всей учётки и приходят с серверов:
  - Claude: `GET api.anthropic.com/api/oauth/usage` с токеном из `~/.claude/.credentials.json`,
    то есть с входом **Claude Code CLI**;
  - Codex: `GET chatgpt.com/backend-api/wham/usage` с токеном из `~/.codex/auth.json`, а при
    ошибке — из последних rollout-файлов.

  Токен Claude обновляется, только когда до его истечения осталось меньше 2 минут. Новая пара
  атомарно записывается обратно, остальные поля файла сохраняются. Если сам CLI успел обновить
  токен раньше, записанное им не перезаписывается. Отказанный refresh-токен повторно не
  отправляется.
- **Расход по дням и моделям** берётся из логов этой машины: `~/.claude/projects/**.jsonl`
  (включая `subagents/agent-*.jsonl`, каждое сообщение считается один раз в день) и
  `~/.codex/sessions/**/rollout-*.jsonl` (события `token_count`). Индекс инкрементальный: при
  каждом проходе дочитываются только новые полные строки. Первый проход по ~1,8 ГБ логов занимает
  около 4 секунд, последующие — доли секунды.

> Claude Code внутри **настольного приложения Claude** использует собственный вход и не
> обновляет `~/.claude/.credentials.json`. Если CLI не установлен или вход в нём устарел,
> карточка Claude покажет «Вход устарел → Как починить?» с командами установки и входа.
> Codex и синхронизация расхода работают и без этого входа.

## Где что лежит

| путь | что |
|---|---|
| `~/.config/claude-codex-limits/settings.json` | настройки значка (язык, вид, числа в трее, подписки, звуки) |
| `~/.config/claude-codex-limits/machine-id` | id этой машины для gist (UUID v4, создаётся один раз) |
| `~/.local/state/claude-codex-limits/usage-index.json` | инкрементальный индекс логов |
| `~/.local/state/claude-codex-limits/sync-*.json` | состояние синхронизации и сумма других машин |
| `~/.local/state/claude-codex-limits/history.jsonl`, `cache.json` | замеры лимитов для темпа и последний удачный ответ |

## Разработка

```sh
python3 -m unittest discover -s linux/tests -v
python3 linux/ccl-sync dump --days 3      # запуск из репозитория без установки
python3 linux/claude-codex-limits
```

Модули: `ccl/usage.py` — индекс логов, цены и деньги; `ccl/sync.py` — протокол gist и Device Flow;
`ccl/vault.py` — хранилище секретов или файл; `ccl/limits.py` — лимиты, кэш, история, темп;
`ccl/gui/` — трей и панель (порт `drawPanel` и `drawAdvanced`).
