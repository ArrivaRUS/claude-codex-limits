# macOS 3.4.1 — Keychain fix and a clearer Auto mode

<!--RU-->
**Статистика не пропадает после перезагрузки.** В 3.4.0 после перезагрузки мака карточки могли не показываться с ошибкой «Связка ключей не ответила»: macOS открывала окно доступа к Связке, а оно пряталось под панелью. Теперь пункт входа в GitHub сохраняется так, что системная утилита читает его без запроса — окно больше не появляется.

- Пункты, сохранённые версией 3.4.0, переносятся в новый вид тихо, при первой возможности. Если перенос не удался, синхронизация продолжает работать на старом пункте.
- «Выйти» из GitHub удаляет сохранённые токены из Связки ключей, в том числе оставшиеся от 3.4.0, без окон и без кнопки «Повторить».

**«Авто» показывает, что и откуда опрашивается.** Справа от кнопки «А» — легенда в две строки: какой продукт с каким интервалом опрашивается и с какой машины. Для данных с другой машины видны её имя и точка свежести того же цвета, что в шапке карточки; если данные устарели, вместо интервала показано время последних данных. Подсказка на «А» перечисляет и продукты с других машин, например:

```
Авто: Codex → 15 минут (этот Mac)
Claude Code → 15 минут (vps)
```

Подсказки панели теперь всплывают при наведении, без клика.

- **Интервал «Авто» больше не залипает на 4 часах.** Новое окно лимита, в котором уже есть расход, считается активностью — опрос раз в 15 минут. При любом росте расхода опрос идёт не реже раза в час.
- После ручного обновления на карточке больше нет отсчётов «Повтор через N с» и «Опрос можно с ЧЧ:ММ». Сами ограничения остались, объяснение — в подсказке.
- У Codex больше нет пустой строки «Сессия · 5 ч», если сервер её не присылает.

**Известное ограничение.** После «Выйти» токены удаляются из Связки ключей не сразу, а в течение примерно 10 минут или при следующем запуске приложения. «Выйти» не отзывает доступ на GitHub — это делается в github.com/settings/applications.

**Откат.** Установите DMG 3.4.0 со страницы выпусков. macOS может один раз спросить доступ к Связке ключей — нажмите «Разрешать всегда» или войдите в GitHub заново.

macOS 13+, Apple Silicon.

DMG SHA-256: `c346ed6bbb4b422e710070efa42887d32eae54aa42f5ddde27e1db5487719c7e`

<!--EN-->
**Stats no longer disappear after a restart.** In 3.4.0, cards could fail to load after restarting the Mac with “Keychain did not respond”: macOS opened a Keychain access prompt that stayed hidden under the panel. The GitHub sign-in item is now saved so that the system tool reads it without asking, and the prompt no longer appears.

- Items saved by 3.4.0 are moved to the new form quietly, at the first chance. If the move fails, sync keeps working on the old item.
- **Sign out** of GitHub removes the saved tokens from Keychain, including ones left by 3.4.0, with no prompts and no **Retry** button.

**Auto shows what is polled and from where.** A two-line legend to the right of the **A** button shows which product is polled at which interval and from which machine. Data from another machine shows its name and a freshness dot in the same colour as on the card header; when the data is stale, the time of the last data replaces the interval. The **A** tooltip lists products from other machines too, for example:

```
Auto: Codex → 15 minutes (this Mac)
Claude Code → 15 minutes (vps)
```

Panel tooltips now appear on hover, without a click.

- **The Auto interval no longer gets stuck at 4 hours.** A new limit window that already has usage counts as activity — polling every 15 minutes. With any usage growth, polling runs at least once an hour.
- After a manual refresh, the card no longer shows the “Retry in N s” and “Poll allowed at HH:MM” countdowns. The limits themselves stay; the explanation is in the tooltip.
- Codex no longer shows an empty “Session · 5 h” row when the server does not send one.

**Known limitation.** After **Sign out**, tokens are removed from Keychain not immediately but within about 10 minutes or at the next app launch. **Sign out** does not revoke access on GitHub — do that at github.com/settings/applications.

**Rollback.** Install the 3.4.0 DMG from the Releases page. macOS may ask for Keychain access once — click **Always Allow** or sign in to GitHub again.

macOS 13+, Apple Silicon.

DMG SHA-256: `c346ed6bbb4b422e710070efa42887d32eae54aa42f5ddde27e1db5487719c7e`
