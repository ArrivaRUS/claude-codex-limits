# Ревью C3 часть B (`e647e33..5106830`, Sol вслепую; на маке `5106830` собрался, C3-B 484/484 модельных)

**Дата:** 2026-10-28. **Кто:** DeepSeek-v4.1-Flash-1017 с хаба Астры (reviewer-hub) — по дифу модели `RemoteLimitsC3B.swift` + `RemoteLimitsC3BSelfTests.swift` + `build.sh` (часть 1); GPT-6 Astra @high (`codex exec` read-only) — по полному дифу с доступом к исходникам. ⚠️ DeepSeek на полном дифе (181 КБ) и на части 2 (интеграция `LimitsMonitor.swift` + PNG-генератор, 139 КБ) дважды исчерпал 96k токенов рассуждения без единой строки ответа (`finish=length`) — интеграцию покрывает только Astra. Урок: DeepSeek-ревью — дифы ≤ ~50 КБ, крупнее — резать или Astra.

**Вердикт обоих: FAIL.** Security surface: да (подписи из gist и поля ввода → UI/AX/tooltip/defaults). По режиму «прототипы» — один цикл правок по всем находкам, без второго круга.

## DeepSeek (часть 1: модель и тесты)

FAIL

- **major** · `RemoteLimitsC3B.swift:136,141,162,180` · В меню/настройках/дефолтной подписи/tooltip используются сырые `view.caption`, `view.machines`, `view.data.plan`, `sourceLine`; `remoteCaptionInput` применён только к вводу. · Если ingestion не санитизирует, управляющие/bidi/длинные строки из gist попадут в UI/AX и сломают строку/тултип. · Санитизировать и лимитировать все snapshot-строки на границе модели либо доказать, что ingestion это делает, и добавить тесты.
- **major** · `RemoteLimitsC3B.swift:47-54` · В advanced-раскладке `selector`, `selectorExtra`, `historyH` и `moneyRows` считаются по `views.count`/`views.indices`, а `cards` — по `visible`. · `u:`-аккаунты («не указан») дают лишние строки/селектор и неверную высоту окна. · Использовать `visible.count`/`visible.indices` везде.
- **major** · `RemoteLimitsC3B.swift:47-48`; `RemoteLimitsC3BSelfTests.swift:120-122` · `selector`/`selectorExtra` не зависят от `expanded`: при 3+ аккаунтах и свёрнутой истории (`historyHeight=35`) рисуется 22pt селектор и окно выше. Тест проверяет только `moneyRows.isEmpty`. · Регрессия advanced-панели для 3+ локальных аккаунтов. · Гейтить `selector` и `selectorExtra` через `expanded`; добавить проверку `selector == nil` в collapsed.
- **major** · `RemoteLimitsC3B.swift:77` · `remoteAdvancedRowKind` учитывает только `.signedOut`; для `.stale`/`.signInRequired`/`.offline`/`.syncStalled` при свежих timestamp'ах строки остаются full, хотя меню их тускнит. · Карточка и меню расходятся; состояния 2/3/5/6/7 не отражены в карточке. · Учитывать `view.state` для remote non-fresh (кроме `serviceWait`), возвращать stale/inactive; добавить тесты.
- **minor** · `RemoteLimitsC3BSelfTests.swift:108-114` · Тест «local and remote loggedOut card heights equal» ставит `.loggedOut` только remote, local остаётся с дефолтным auth. · Ветка `local auth != .ok` не проверяется, тест даёт ложную уверенность. · Выставить `auth=.loggedOut` обоим или переименовать тест и добавить отдельный кейс.
- **minor** · `RemoteLimitsC3B.swift:189-192` · `remoteCaptionInput` фильтрует Cc/Cf/surrogate, но не Zl/Zp (`U+2028`/`U+2029`). · Разделитель строки может выжить и сломать однострочную подпись/меню. · Фильтровать `.lineSeparator`/`.paragraphSeparator` или добавить тест.
- **minor** · `RemoteLimitsC3B.swift:165` · `visible`/`menuProducts` используют `hidden.contains(view.label ?? view.historyKey)`; тесты `c3bC309` используют `label == historyKey`. · Если defaults хранят `historyKey` для labelled-аккаунта, скрытие/меню сломается. · Зафиксировать ключ и добавить тест с `label != historyKey`.
- **minor** · `RemoteLimitsC3B.swift:100` · Для local `auth=.ok` и `asOf=nil` добавляется notice; self-tests local всегда задают `asOf`. · Если локальные данные бывают без `asOf`, высота локальной карточки изменится. · Подтвердить инвариант или обработать `nil asOf` без notice; добавить тест.

Security surface: да — snapshot-строки из gist (`caption`, `machines`, `plan`, `sourceLine`) идут в UI/AX/tooltip без модельной санитизации/лимита; защищён только пользовательский ввод.

## Astra @high (полный диф)

FAIL

- **major · [Sources/RemoteLimitsC3B.swift:89](/home/yurka/VibeCoding2/2026_06_UsageLimits/Sources/RemoteLimitsC3B.swift:89)** · `metricIsStale` теперь переводит локальный снимок старше 4 часов в `.stale`, даже когда окно ещё действует. Исчезают прежний прогноз на снимке и строка метрик, высота уменьшается с 62 до 50 pt. Существующий тест `historical` (`LimitsMonitor.swift:8844`) требует `.full` и по коду должен упасть. **Исправить:** сохранить прежнюю классификацию локальных строк, отделив затемнение от пригодности снимка для прогноза.

- **major · [Sources/LimitsMonitor.swift:5027](/home/yurka/VibeCoding2/2026_06_UsageLimits/Sources/LimitsMonitor.swift:5027)** · `historyKey` используется как глобально уникальный идентификатор, но без установленной локальной идентичности оба продукта получают `l:legacy` — например, при показе дискового кэша до успешного опроса. Выбор Codex возвращает первый аккаунт Claude; оба сегмента подсвечиваются. Та же коллизия в `accountSubscriptionUSD` связывает цены двух продуктов. **Исправить:** использовать составной ключ `(product, historyKey)` для выбора, действий и переопределений цены; добавить сценарий двух локальных `l:legacy`.

- **major · [Sources/LimitsMonitor.swift:7593](/home/yurka/VibeCoding2/2026_06_UsageLimits/Sources/LimitsMonitor.swift:7593)** · Новая строка меню читает gist только при вызове `applyTrayImage`, но `GitHubSync.onChange` обновляет лишь панель. При выключенных локальных опросах последующие чтения gist и ручное обновление чужой карточки не обновляют числа и tooltip меню; переходы состояния также не меняют альфу своевременно. **Исправить:** перерисовывать меню при изменениях синхронизации и наступлении временных границ свежести, независимо от локального опроса.

- **minor · [Sources/LimitsMonitor.swift:4621](/home/yurka/VibeCoding2/2026_06_UsageLimits/Sources/LimitsMonitor.swift:4621)** · Удалено добавление заглушки включённого, но отсутствующего локального продукта. Без синхронизации одна найденная подписка теперь занимает всю ширину вместо прежней пары «карточка + Не настроен». **Исправить:** сохранить прежнюю заглушку для локального сценария; не добавлять её для выключенных продуктов.

- **minor · [Sources/RemoteLimitsC3B.swift:23](/home/yurka/VibeCoding2/2026_06_UsageLimits/Sources/RemoteLimitsC3B.swift:23)** · Дополнительные 15 pt зависят только от наличия `scoped`, хотя локальная карточка при устаревании или проблеме входа эту строку не рисует. Такие локальные панели становятся выше прежних. **Исправить:** учитывать фактическую видимость модельной строки, сохраняя обход всех карточек.

- **minor · [Sources/RemoteLimitsC3B.swift:193](/home/yurka/VibeCoding2/2026_06_UsageLimits/Sources/RemoteLimitsC3B.swift:193)** · Санитизация сохраняет U+2028/U+2029: категории `.lineSeparator` и `.paragraphSeparator` не отфильтрованы. Подпись `A\u{2028}B` сохраняется и попадает в заголовки и tooltip с переносом. **Исправить:** удалять также Unicode-разделители строк и абзацев; добавить проверки ввода и сохранения.

Проверка статическая; PNG и нативный ввод не запускались.

Security surface: да — новые пути недоверенных подписей из gist и поля ввода в UI, tooltip/AX и локальные defaults.
