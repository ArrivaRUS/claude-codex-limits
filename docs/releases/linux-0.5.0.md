# Linux 0.5.0 — Publisher for servers

<!--RU-->
**Издатель `ccl-sync` для серверов и ноутбуков без рабочего стола.** Машина, где выполнен вход в Claude Code и/или Codex CLI, сама опрашивает лимиты своих аккаунтов и публикует остатки и расход в ваш секретный gist. Мак на macOS 3.4.0 показывает их в одном окне вместе со своими — даже без своей подписки на маке.

Издатель ставится из клона выпуска, а не из DEB:

```sh
git clone --branch linux-v0.5.0 https://github.com/ArrivaRUS/claude-codex-limits.git
cd claude-codex-limits
sh linux/install.sh --publisher --no-tray --name server
ccl-sync login --no-browser
```

- `--name` — короткий тег машины, который виден на маке: строчные латинские буквы, цифры и дефис, 1–16 символов. `ccl-sync login --no-browser` печатает код; откройте github.com/login/device на любом устройстве.
- Токен GitHub издатель хранит только в файле с правами `0600` в `~/.config/claude-codex-limits/`, не в хранилище секретов рабочего стола.
- Таймер systemd проверяет расписание раз в 5 минут. Сами запросы идут по Auto (от 15 минут до 4 часов) или по фиксированному интервалу. Машины согласуют опрос: один аккаунт не опрашивается дважды за 15 минут, паузу от провайдера соблюдают все. До входа в GitHub опросов нет.
- Управление: `ccl-sync publisher --status`, `--now`, `--mode auto`, `--mode fixed 3600`, `--products claude,codex`, `--disable`. `ccl-sync update` сохраняет режим издателя и тег машины.
- Издатель — для машины без значка в трее. Установщик откажет, если значок запущен: вместе они опрашивали бы дважды.

**Значок в трее (DEB).** Подписи аккаунтов, заданные на маке, видны в подсказке значка и в `ccl-sync status`. Карточек с других машин значок пока не показывает. Расход текущей модели Codex в «Истории и деньгах» больше не считается за $0: добавлена её цена по API.

**Токены CLI — только чтение.** По умолчанию ни значок, ни издатель больше не продлевают OAuth-токены и не переписывают `~/.claude/.credentials.json` и `~/.codex/auth.json`: эти файлы делит живой CLI. Если вход истёк, продлите его в самом CLI. Издатель до этого публикует, что машина ждёт обновления входа, вместе с последними значениями и их временем. Продление токенов значком можно включить явно: `ccl-sync credentials --write guarded`; на издателе эта настройка не действует.

**Ссылку на gist никому не давайте: это ключ на чтение.** `ccl-sync status` больше не печатает ссылку, только «Gist: есть (секретный)». Полную ссылку показывает `ccl-sync status --show-gist`. Секретный gist не виден в списках, но не зашифрован — его читает любой, у кого есть ссылка. Не вставляйте её в чаты и issues. На машине с другими пользователями закройте `~/.codex`: `chmod 700 ~/.codex` — там полные транскрипты сессий.

**Совместимость.** Машины на macOS 3.2.7 и Linux 0.4.5 продолжают обмениваться расходом с новыми версиями: новый формат файлов только дополняет старый. Лимитов такие машины не публикуют и карточек с других машин не показывают.

**Откат.** Значок: установите DEB 0.4.5 со страницы выпусков. Издателя в 0.4.5 нет, поэтому его удаляют: `systemctl --user disable --now ccl-sync.timer`, `systemctl --user stop ccl-sync.service`, затем `sh linux/uninstall.sh`. Файл машины остаётся в gist; удалите его на github.com, если он больше не нужен.

Скачайте DEB и откройте его установщиком пакетов либо выполните в каталоге загрузки:

```sh
sudo apt install ./claude-codex-limits_0.5.0_all.deb
```

Linux CI проверяет тесты и сборку DEB на Ubuntu 22.04. Значок 0.5.0 пока не проверен на живой Astra Linux SE. Linux-релиз не получает пометку Latest. macOS — 3.4.0.

<!--EN-->
**The `ccl-sync` publisher for servers and laptops without a desktop.** A machine signed in to the Claude Code and/or Codex CLI polls its own accounts’ limits and publishes the remaining limits and usage to your secret gist. A Mac on macOS 3.4.0 shows them in one window next to its own — even without its own subscription.

Install the publisher from a checkout of the release, not from the DEB:

```sh
git clone --branch linux-v0.5.0 https://github.com/ArrivaRUS/claude-codex-limits.git
cd claude-codex-limits
sh linux/install.sh --publisher --no-tray --name server
ccl-sync login --no-browser
```

- `--name` is the short machine tag shown on the Mac: lowercase ASCII letters, digits and hyphens, 1–16 characters. `ccl-sync login --no-browser` prints a code; open github.com/login/device on any device.
- The publisher keeps its GitHub token only in a file with permissions `0600` under `~/.config/claude-codex-limits/`, not in a desktop keyring.
- A systemd user timer checks the schedule every 5 minutes. Actual requests follow Auto (15 minutes up to 4 hours) or a fixed interval. Machines coordinate: one account is not polled twice within 15 minutes, and every machine honours a provider’s retry request. Nothing is polled before the GitHub sign-in.
- Control: `ccl-sync publisher --status`, `--now`, `--mode auto`, `--mode fixed 3600`, `--products claude,codex`, `--disable`. `ccl-sync update` keeps publisher mode and the machine tag.
- The publisher is for a machine without the tray app. The installer refuses while the tray is running: together they would poll twice.

**Tray app (DEB).** Account labels set on the Mac appear in the tray tooltip and in `ccl-sync status`. The tray does not show cards from other machines yet. Usage of the current Codex model is no longer counted as $0 in History & money: its API price has been added.

**CLI tokens are read-only.** By default neither the tray nor the publisher refreshes OAuth tokens or rewrites `~/.claude/.credentials.json` and `~/.codex/auth.json`, which the live CLI shares. If a sign-in expires, renew it in the CLI itself. Until then the publisher reports that the machine is waiting for a sign-in renewal, together with the last values and their time. Token refresh by the tray can be turned on explicitly with `ccl-sync credentials --write guarded`; it has no effect on a publisher.

**Never share the gist URL: it is a read access key.** `ccl-sync status` no longer prints the URL, only “Gist: yes (secret)”. `ccl-sync status --show-gist` shows the full URL. A secret gist is unlisted but not encrypted — anyone with the URL can read it. Do not paste it into chats or issues. On a machine shared with other users, close `~/.codex` with `chmod 700 ~/.codex`: it holds full session transcripts.

**Compatibility.** Machines on macOS 3.2.7 and Linux 0.4.5 keep exchanging usage with the new versions: the new file format only adds to the old one. Those machines publish no limits and show no cards from other machines.

**Rollback.** Tray: install the 0.4.5 DEB from the Releases page. Linux 0.4.5 has no publisher, so remove it: `systemctl --user disable --now ccl-sync.timer`, `systemctl --user stop ccl-sync.service`, then `sh linux/uninstall.sh`. The machine’s file stays in the gist; delete it on github.com if you no longer need it.

Install the attached DEB with your package manager or the apt command above.

Linux CI runs tests and builds the DEB on Ubuntu 22.04. The 0.5.0 tray has not yet been tested on a live Astra Linux SE system. The Linux release is not marked Latest. macOS is at 3.4.0.

## Verification

Source: `<commit after merge>`. Linux CI: `<run link, test count>`.

SHA-256 (`claude-codex-limits_0.5.0_all.deb`):
```text
<fill in after building the DEB>
```
