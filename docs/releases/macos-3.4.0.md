# macOS 3.4.0 — Limits from other computers

<!--RU-->
**Лимиты с других компьютеров.** Лимиты и расход Claude Code и Codex со всех ваших машин — VPS, других ноутбуков — теперь видны в одном окне на маке. Машины, вошедшие в один и тот же GitHub, публикуют данные в ваш секретный gist, а мак их показывает. Своя подписка на маке для этого не нужна: выключите продукт в «Опрашивать на этом компьютере», и карточка с сервера всё равно появится.

- **Одна карточка на аккаунт.** Аккаунт, в который вошли на нескольких машинах, показан одной карточкой, например `Codex · laptop, server`. Значения берутся из самого свежего успешного показания любой машины; неудачный опрос на маке не прячет свежие данные с другой машины.
- **Точки свежести.** У каждой машины в карточке — точка: зелёная — данные свежие, рыжая — старше интервала опроса плюс 15 минут, красная — старше суток, серая — показаний ещё нет. Время каждого источника — в подсказке заголовка. Строка «Данные …» под карточками убрана.
- Карточка сообщает, если машина-источник не выходила на связь больше 30 минут или на ней нужно обновить вход в CLI. «Обновить сейчас» для аккаунта без входа на этом маке только перечитывает gist: у Anthropic и OpenAI мак про чужой аккаунт не спрашивает.
- **Подписи аккаунтов.** Настройки → «Аккаунты»: переименуйте карточку карандашом (до 32 символов) или скройте её на этом маке. Подписи синхронизируются между машинами. Если аккаунтов одного продукта два и больше, выберите, какой показывать в строке меню.
- **Без двойных запросов.** Если один аккаунт Codex вошёл и на маке, и на сервере, машины не опрашивают его дважды за 15 минут, а паузу, о которой попросил провайдер, соблюдают все. Мак сам публикует лимиты своего аккаунта Codex для других машин.
- **«История и деньги» по подпискам.** В расширенном виде — одна закладка и одна строка таблицы на подписку Claude и Codex; расход со всех машин складывается в одну сумму. Переключатель подписок стоит в строке заголовка, таблица показывает «по подписке / по API / выгода». Цена подписки — заданная вами в настройках, иначе по опубликованному плану; оценочная помечена `≈`.
- Расход текущей модели Codex в «Истории и деньгах» больше не считается за $0: добавлена её цена по API.
- **Постоянная подпись приложения.** Разрешение «Разрешать всегда» в Связке ключей переживает следующие обновления: окна Связки больше не возвращаются с каждой новой версией. Повторный доступ к Связке ждёт до 2 минут, кнопка «Повторить» видна только при ошибке.

**Токены CLI — только чтение.** По умолчанию приложение больше не продлевает токены Claude Code и Codex и не переписывает их файлы входа: эти файлы делит живой CLI. Если вход истёк, продлите его в самом CLI.

**Ссылку на gist никому не давайте: это ключ на чтение.** Секретный gist не виден в списках, но не зашифрован — его читает любой, у кого есть ссылка. Не вставляйте её в чаты и issues. На Linux `ccl-sync status` больше не печатает ссылку; полную показывает только `ccl-sync status --show-gist`. Папка данных приложения `~/.claude-limits-monitor` теперь доступна только вашему пользователю.

**Как включить.** Настройки → «Другие компьютеры · через GitHub» → «Войти через GitHub». На Linux-сервере или ноутбуке поставьте издатель `ccl-sync` из Linux 0.5.0. Подробно — в README, раздел «Лимиты с других компьютеров».

**Совместимость.** Машины на macOS 3.2.7 и Linux 0.4.5 продолжают обмениваться расходом с новыми версиями: новый формат файлов только дополняет старый. Лимитов такие машины не публикуют и карточек с других машин не показывают.

**Откат.** Установите DMG 3.2.7 со страницы выпусков. Синхронизация расхода продолжится, карточки с других машин исчезнут.

macOS 13+, Apple Silicon. Linux — 0.5.0.

DMG SHA-256: `<заполнить после сборки DMG>`.

<!--EN-->
**Limits from other computers.** Claude Code and Codex limits and usage from all your machines — a VPS, other laptops — now appear in one window on your Mac. Machines signed in to the same GitHub account publish to your secret gist, and the Mac shows them. The Mac does not need its own subscription: turn a product off under “Poll on this computer”, and the card from your server still appears.

- **One card per account.** An account signed in on several machines is one card, for example `Codex · laptop, server`. Values come from the freshest successful reading on any machine; a failed poll on the Mac does not hide newer data from another machine.
- **Freshness dots.** Each machine on a card has a dot: green — fresh, amber — older than its polling interval plus 15 minutes, red — older than 24 hours, grey — no reading yet. Each source’s time is in the header tooltip. The “Data …” line under the cards is gone.
- A card tells you when its source machine has not reported for more than 30 minutes or needs its CLI sign-in renewed. **Refresh now** on an account not signed in on this Mac only re-reads the gist: the Mac never asks Anthropic or OpenAI about another machine’s account.
- **Account labels.** Settings → **Accounts**: rename a card with the pencil (up to 32 characters) or hide it on this Mac. Labels sync between machines. With two or more accounts of one product, choose which one the menu bar shows.
- **No double polling.** When one Codex account is signed in on both the Mac and a server, the machines do not poll it twice within 15 minutes, and all of them honour a provider’s retry request. The Mac publishes its own Codex account’s limits for other machines.
- **History & money by subscription.** Advanced view has one tab and one table row per Claude and Codex subscription; usage from all machines adds up to one sum. The subscription switcher sits in the header row, and the table shows subscription / API / value. The subscription price is the one you set in Settings, otherwise the published plan price; an estimate is marked `≈`.
- Usage of the current Codex model is no longer counted as $0 in History & money: its API price has been added.
- **Stable app signature.** “Always Allow” in Keychain now survives later updates, so Keychain prompts no longer return with every new version. A Keychain retry waits up to 2 minutes, and **Retry** appears only when there is an error.

**CLI tokens are read-only.** By default the app no longer refreshes Claude Code and Codex tokens or rewrites their sign-in files, which the live CLI shares. If a sign-in expires, renew it in the CLI itself.

**Never share the gist URL: it is a read access key.** A secret gist is unlisted but not encrypted — anyone with the URL can read it. Do not paste it into chats or issues. On Linux, `ccl-sync status` no longer prints the URL; only `ccl-sync status --show-gist` shows it in full. The app’s data folder `~/.claude-limits-monitor` is now accessible only to your user.

**Turn it on.** Settings → **Other computers · via GitHub** → **Sign in with GitHub**. On a Linux server or laptop, install the `ccl-sync` publisher from Linux 0.5.0. Details: README, section “Limits from other computers”.

**Compatibility.** Machines on macOS 3.2.7 and Linux 0.4.5 keep exchanging usage with the new versions: the new file format only adds to the old one. Those machines publish no limits and show no cards from other machines.

**Rollback.** Install the 3.2.7 DMG from the Releases page. Usage sync continues; cards from other machines disappear.

macOS 13+, Apple Silicon. Linux is at 0.5.0.

DMG SHA-256: `<fill in after building the DMG>`.
