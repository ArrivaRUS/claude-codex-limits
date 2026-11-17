# Linux 0.5.2 — Longer publisher log history

<!--RU-->
**Журнал издателя хранится дольше.** Файл `~/.local/state/claude-codex-limits/publisher.jsonl` теперь хранит около 45 дней записей вместо недели, до 3 МБ. При смене версии приложения в журнал добавляется строка с версией.

**Обновление.** Выполните `ccl-sync update` или скачайте DEB со [страницы выпуска Linux 0.5.2](https://github.com/ArrivaRUS/claude-codex-limits/releases/tag/linux-v0.5.2). Установите его через установщик пакетов либо из каталога загрузки:

```sh
sudo apt install ./claude-codex-limits_0.5.2_all.deb
```

**Откат.** Установите DEB 0.5.1 со [страницы выпуска Linux 0.5.1](https://github.com/ArrivaRUS/claude-codex-limits/releases/tag/linux-v0.5.1).

Linux-релиз не получает пометку Latest. Latest остаётся macOS 3.4.2.

DEB SHA-256: `<SHA>`

<!--EN-->
**The publisher log keeps more history.** The file `~/.local/state/claude-codex-limits/publisher.jsonl` now keeps about 45 days of records instead of one week, up to 3 MB. When the app version changes, a line with the version is added to the log.

**Update.** Run `ccl-sync update` or download the DEB from the [Linux 0.5.2 release page](https://github.com/ArrivaRUS/claude-codex-limits/releases/tag/linux-v0.5.2). Install it with your package manager or run this in the download directory:

```sh
sudo apt install ./claude-codex-limits_0.5.2_all.deb
```

**Rollback.** Install the 0.5.1 DEB from the [Linux 0.5.1 release page](https://github.com/ArrivaRUS/claude-codex-limits/releases/tag/linux-v0.5.1).

The Linux release is not marked Latest. Latest remains macOS 3.4.2.

DEB SHA-256: `<SHA>`
