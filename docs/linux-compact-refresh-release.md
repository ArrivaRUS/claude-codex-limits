# Linux 0.4.5 — compact refresh candidate / кандидат

2026-10-08. **Кандидат до CI, QA и выпуска координатором / Candidate pending CI, QA and coordinator release.** Linux 0.4.5 объединяет компактный интерфейс с ручным обновлением без ожидания локального расписания или паузы после ошибки. Инструкции сверены чтением исходников freeze3; проверка исполнения, приёмка пакета и публикация ещё не подтверждены.

Linux 0.4.5 combines the compact layout with manual refresh that bypasses the local schedule and error backoff. These candidate instructions were checked against freeze3 source; runtime verification, package acceptance and publication remain pending.

## Русский

Целевой интерфейс Linux 0.4.5: в простом и расширенном видах небольшая иконка обновления находится рядом с Настройками в существующей шапке. Краткий статус запроса и время данных находятся внутри карточки каждого сервиса; подробности доступны в подсказке.

При действующем входе нужного CLI включите подписки в Настройках, откройте панель и нажмите иконку «Обновить сейчас»: само открытие панели не запрашивает новые лимиты. Выберите **15 мин / 30 мин / 1 ч / 4 ч** для фиксированного режима либо **«А»** для Auto. Фиксированные 4ч сохраняются как 14400 секунд; прежние 1/5 минут переходят в 30 минут. В Auto одновременно подсвечены «А» и фактические интервалы включённых сервисов. Разные интервалы подсвечивают оба сегмента; выключенный сервис не участвует. При обеих выключенных подписках ни один интервал не подсвечен, «А» может оставаться выбранной в Auto.

Отдельная частота справа от «А» и строка «Темп по снимку от…» с её высотой убираются; прогнозы и необходимые сообщения о проблемах доступа/данных сохраняются.

По принятому контракту ручное обновление обходит локальные 15 минут, расписание Auto/фиксированного опроса и паузу после сетевой ошибки. Выбранный режим сохраняется. У каждого сервиса действует защита 30 секунд от начала попытки и не более одного одновременного запроса. Результаты показываются независимо: ответ одного сервиса не ждёт другого. При частичной ошибке используйте повтор только проблемного сервиса, когда ожидание закончится.

Реальный серверный Retry-After соблюдается: известный срок показывается отдельно от локальной защиты и учитывается для следующей автоматической попытки. Неизвестный серверный срок не выдумывается. Неизменившийся живой ответ считается успешным обновлением. При fallback сохраняется исходный `asOf` старых данных; неизвестное время остаётся `—`. Время данных и следующая автоматическая попытка различаются; таймер учитывает ручной запрос, чтобы не отправить немедленный дубликат.

При проблеме входа откройте «Восстановить доступ»: запустите `claude` и выполните `/login` либо выполните `codex login`. При ошибке чтения/сохранения проверьте пользователя CLI, доступность его файла входа и место на диске; затем нажмите «Повторить». Linux использует существующие файлы учётных данных CLI. Обычное обновление не запускает интерактивный вход или запрос разрешений; механизм macOS Keychain permit на Linux не используется.

**После выпуска координатором**, на Linux с apt и доступными зависимостями ОС скачайте `claude-codex-limits_0.4.5_all.deb` из релиза `linux-v0.4.5` в [списке релизов](https://github.com/ArrivaRUS/claude-codex-limits/releases). В каталоге загрузки выполните:

```sh
sudo apt install ./claude-codex-limits_0.4.5_all.deb
```

Затем запустите **Claude Codex Limits** из меню приложений. Ожидается версия 0.4.5 и описанный интерфейс; установка этой версии на ThinkPad или другую живую Linux-машину здесь не подтверждена. Это Linux DEB, не пакет для установки на Mac.

## English

The target Linux 0.4.5 layout places a small refresh icon beside Settings in the existing header, in both Simple and Advanced views. Compact request status and data time appear inside each provider card, with details in its tooltip.

With the required CLI signed in, enable subscriptions in Settings, open the panel and click **Refresh now**; opening the panel alone does not request fresh limits. Select **15 min / 30 min / 1 h / 4 h** for fixed polling or **A** for Auto. Fixed 4 h is saved as 14400 seconds; old 1/5-minute settings migrate to 30 minutes. Auto highlights A and the actual intervals of enabled providers together. Different intervals highlight both segments; disabled providers do not contribute. With both subscriptions off, no interval is highlighted; A may remain selected in Auto.

The target UI removes the standalone frequency beside A and the “Pace from snapshot at…” annotation, including its reserved height. Forecasts and necessary access/data warnings remain.

Under the accepted contract, manual refresh bypasses the local 15-minute floor, Auto/fixed schedule and network-error backoff while preserving the selected mode. Each provider has a 30-second guard from the start of an attempt and at most one request in flight. Results appear independently, without waiting for the other provider. After a partial failure, retry just the affected provider once its wait ends.

Actual server Retry-After deadlines remain binding: a known deadline is shown separately from the local guard and used for the next automatic attempt. An unknown server deadline is not invented. An unchanged live response counts as a successful refresh. Fallback retains the old data's original `asOf`; an unknown time remains `—`. Data time and the next automatic attempt are distinct; the timer accounts for a manual request to avoid an immediate duplicate.

For sign-in problems, open **Restore access**: start `claude` and run `/login`, or run `codex login`. For read/save errors, check that the CLI runs as your user, its sign-in file is accessible and disk space is available; then click **Retry**. Linux uses the existing CLI credential files. Ordinary refresh does not start interactive login or permission prompts; macOS Keychain permits are not part of the Linux flow.

**After coordinator release**, on Linux with apt and OS dependencies available, download `claude-codex-limits_0.4.5_all.deb` from `linux-v0.4.5` in the [release list](https://github.com/ArrivaRUS/claude-codex-limits/releases). Run the apt command above in the download directory, then launch **Claude Codex Limits** from the applications menu. Expect version 0.4.5 and the described UI; installation on a live Linux/ThinkPad system is not confirmed here. The DEB is for Linux.

## Release boundary / границы выпуска

- Coordinator publishes **linux-v0.4.5**, with DEB and **`--latest=false`**. **macOS 3.2.7 remains Latest**. Publication is pending in this document.
- No runtime, package, CI, live desktop, keyring or installation checks were performed by the documentation author. Independent acceptance and package QA remain required before release.
- Instructions were checked by reading freeze3 (`ccl-linux-freeze-c08fgctf`): [`panel.py`](../linux/ccl/gui/panel.py), [`app.py`](../linux/ccl/gui/app.py), [`quota_refresh.py`](../linux/ccl/quota_refresh.py), [`limits.py`](../linux/ccl/limits.py) and [`__init__.py`](../linux/ccl/__init__.py). Requirements: [Linux plan](linux-compact-refresh-plan.md), [manual-refresh scenario](manual-refresh-proposal.md), [UX](compact-refresh-ux.md). Git revision was not queried. Later source changes require a new documentation check; the coordinator updates candidate status after acceptance and release.
