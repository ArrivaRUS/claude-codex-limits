# Linux 0.5.1 — Sign-in status and Auto polling

<!--RU-->
**Вход Claude Code истёк — теперь видно.** Если вход Claude Code CLI на машине истёк и приложение не может его использовать, издатель `ccl-sync` публикует статус «вход истёк». По умолчанию приложение не продлевает токены CLI. На маке с macOS 3.4.1 вместо серой карточки «Данные устарели» появляется «Вход Claude Code истёк на машине `<имя>` — войдите там заново».

Выполните `claude auth login` на указанной машине. После нового входа надпись снимается на ближайшем проходе издателя, без лишних запросов к сервису.

**Интервал «Авто» больше не залипает на 4 часах.** Теперь действует то же правило, что в macOS 3.4.1: если старое окно лимита закончилось, а в новом уже есть расход, это считается активностью и возвращает интервал 15 минут. Любой рост расхода в том же окне сохраняет опрос не реже раза в час.

**Обновление.** Выполните `ccl-sync update` или скачайте DEB со [страницы выпуска Linux 0.5.1](https://github.com/ArrivaRUS/claude-codex-limits/releases/tag/linux-v0.5.1). Установите его через установщик пакетов либо из каталога загрузки:

```sh
sudo apt install ./claude-codex-limits_0.5.1_all.deb
```

**Откат.** Установите DEB 0.5.0 со [страницы выпуска Linux 0.5.0](https://github.com/ArrivaRUS/claude-codex-limits/releases/tag/linux-v0.5.0).

Linux-релиз не получает пометку Latest. Latest остаётся macOS 3.4.1.

DEB SHA-256: `<SHA>`

<!--EN-->
**An expired Claude Code sign-in is now visible.** If the Claude Code CLI sign-in on a machine has expired and the app cannot use it, the `ccl-sync` publisher reports “sign-in expired”. By default the app does not refresh CLI tokens. On a Mac running macOS 3.4.1, the card says “Claude Code sign-in expired on `<name>` — sign in again there” instead of the grey “Data is stale” message.

Run `claude auth login` on that machine. After signing in again, the message clears on the publisher’s next pass, without extra requests to the service.

**Auto polling no longer gets stuck at 4 hours.** It now follows the same rule as macOS 3.4.1: when the old limit window has ended and the new one already has usage, this counts as activity and restores the 15-minute interval. Any increase in usage within the same window keeps polling at least once an hour.

**Update.** Run `ccl-sync update` or download the DEB from the [Linux 0.5.1 release page](https://github.com/ArrivaRUS/claude-codex-limits/releases/tag/linux-v0.5.1). Install it with your package manager or run this in the download directory:

```sh
sudo apt install ./claude-codex-limits_0.5.1_all.deb
```

**Rollback.** Install the 0.5.0 DEB from the [Linux 0.5.0 release page](https://github.com/ArrivaRUS/claude-codex-limits/releases/tag/linux-v0.5.0).

The Linux release is not marked Latest. Latest remains macOS 3.4.1.

DEB SHA-256: `<SHA>`
