# macOS 3.4.2 — Clearer sync status and smaller logs

<!--RU-->
**Карточка точнее объясняет, где остановилась синхронизация.** После сна, пробуждения или потери сети карточка аккаунта с другой машины больше не обвиняет её в том, что сам Mac не получил свежие данные. Если Mac больше 12 минут не получал данные из GitHub, карточка сообщает, что не синхронизируется этот Mac. «Не на связи» для другой машины появляется только тогда, когда Mac недавно получил данные и в них видно, что та машина молчит больше 30 минут.

**Локальный журнал больше не растёт без предела.** Файл `~/.claude-limits-monitor/poll-log.jsonl` хранит около 45 дней записей, до 30 МБ. Пока панель открыта, состояние карточек записывается раз в минуту или при изменении, а не каждую секунду. Запись не задерживает меню. При запуске в журнал добавляется версия приложения.

**Обновление.** Скачайте DMG со [страницы выпуска macOS 3.4.2](https://github.com/ArrivaRUS/claude-codex-limits/releases/tag/v3.4.2) или воспользуйтесь встроенным уведомлением об обновлении. Откройте `ClaudeCodexLimits-3.4.2.dmg` и перетащите приложение в **Applications**.

**Откат.** Установите DMG 3.4.1 со [страницы выпуска macOS 3.4.1](https://github.com/ArrivaRUS/claude-codex-limits/releases/tag/v3.4.1).

macOS 13+, Apple Silicon. Этот выпуск получает пометку Latest.

DMG SHA-256: `<SHA>`

<!--EN-->
**The card explains where sync has stopped more accurately.** After sleep, wake or a network outage, an account card from another machine no longer blames that machine when the Mac itself has not received fresh data. If the Mac has not received data from GitHub for more than 12 minutes, the card says that this Mac is not syncing. The other machine is shown as offline only when the Mac has recently received data showing that the other machine has been silent for more than 30 minutes.

**The local log no longer grows without limit.** The file `~/.claude-limits-monitor/poll-log.jsonl` keeps about 45 days of records, up to 30 MB. While the panel is open, card state is logged once a minute or when it changes, rather than every second. Writing the log does not hold up the menu. The app version is recorded at startup.

**Update.** Download the DMG from the [macOS 3.4.2 release page](https://github.com/ArrivaRUS/claude-codex-limits/releases/tag/v3.4.2) or use the built-in update notification. Open `ClaudeCodexLimits-3.4.2.dmg` and drag the app into **Applications**.

**Rollback.** Install the 3.4.1 DMG from the [macOS 3.4.1 release page](https://github.com/ArrivaRUS/claude-codex-limits/releases/tag/v3.4.1).

macOS 13+, Apple Silicon. This release is marked Latest.

DMG SHA-256: `<SHA>`
