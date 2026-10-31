# C5: статическая сверка AppKit-проверок после `6597268`

2026-10-31. Работа одним агентом по прямому запросу владельца, без собственного
ревью, Git-мутаций и запуска Python. Это статическая сверка тестов, не результат
исполнения AppKit на Linux.

На Mac `6597268` модельные наборы прошли: C1 75, C4 730, C2 33, C3 A 590,
C3 B 818, C5 481 — 0 FAIL. Ожидаемый exit134 под удалёнными руками следует на
первом `NSApplication.shared`. В Терминале владельца созданы209 C3 PNG, затем
первое падение Manual refresh UI; финальный манифест и следующие наборы не завершены.

Проверен весь хвост `--subscriptions-selftest`: от первого `NSApplication.shared`
до записи манифеста/exit0, плюс вызываемый `runRemoteLimitsC3BPreviews` и
`c3VerifyPreviewManifest`. Производственная геометрия сохранена.

| Место (исходная строка → новая) | Было | Стало |
|---|---|---|
| `Sources/LimitsMonitor.swift:9196` → `:9201` | `286 + scopedRowExtra + headerExtra + 32` | actual height сравнивается с `remotePanelLayout.windowHeight` и разложением `remoteSimplePanelHeights`: baseline + header + full footer − removed source row |
| `Sources/LimitsMonitor.swift:9195` → `:9199` | body = `152 + scopedRowExtra + headerExtra` в тесте | компоненты высоты получаются из той же модели, что использует Simple layout |
| `Sources/LimitsMonitor.swift:9201` → `:9206` | карта x/y/w/h из `16/186/58/158/328`, body и `32` | slot из `remotePanelLayout`; только перевод top-left → AppKit: `y = canvasHeight − slot.maxY` |
| `Sources/LimitsMonitor.swift:9216` → `:9220` | любой `quotafeedback.height == 32` | `remoteQuotaFooterHeight(advanced: usesAdvanced)`: Simple18, Advanced32 |
| `Sources/LimitsMonitor.swift:9189` → `:9189` | Advanced baseline + literal32 | Advanced baseline + `remoteQuotaFooterHeight(advanced: true)`; результат прежний |

`RemoteSimplePanelHeights` / `remoteSimplePanelHeights` в
`Sources/RemoteLimitsC3B.swift` выделяют существующее разложение: base card152,
base window286, scoped15, reserved header13, текущий footer из общей функции и
row gap12. `remotePanelLayout` использует его напрямую. Проверка полного футера
32pt сохранена как слагаемое; удалённая строка вычитается через разность высот
футеров Advanced/Simple, без нового литерала14 в тесте.

Сверка старых/новых формул для0…4 карточек × scoped/no-scoped: совпадают
empty286; card183/198; window317/332 (1–2),512/542 (3–4).

| Остальные проверенные наборы | Почему правки не нужны |
|---|---|
| C3-10 render/209 сцен | Высоты canvas берутся из `mainPanelHeight`/`settingsTotalHeight`; hit bounds проверяются по canvas. Старых197/212/331/346/540/570 нет. Narrow widths/6pt dots относятся к горизонтальному fit, не к удалённой строке. |
| C3-10 manifest | 209 обязательных сцен — подмножество общего registry; имена, уникальность, SHA256, PNG signature и непустые размеры проверяются без фиксированной высоты. Поздние legacy-наборы также входят в registry. |
| Остальные Manual refresh UI | Header refresh 24×24 и его отступы относятся к неизменной шапке; hit bounds используют actual height. Кнопки24pt могут заходить выше футера18pt, но должны оставаться внутри своей карточки — проверка сохранена. |
| Settings/subscriptions | `settingsTotalHeight`, `mainPanelHeight`, реальные hits и границы; нет фиксированной высоты Simple. |
| Auto/startup/footer/menu | Состояния и tooltip берутся из модели; геометрия отдельно рисуемого poll-footer360×40 не зависит от quota-footer. Полные панели используют `mainPanelHeight`. |
| Auth hints | Полные панели динамические. Advanced-only38/19, y58 и gap5 не зависят от Simple footer; Simple проверяет раздельные полупанели и actual bounds. |
| GitHub Settings/main | Динамические `mainPanelHeight`/`settingsTotalHeight`, login/logout, bounds и отсутствие побочных эффектов. |
| Тексты/AX после AppKit | Нет старых принимаемых caption с @/slash, EN date-only `at`, либо ожиданий видимой строки источника Simple. Проверки `quotaTooltip` с временем данных корректны: сведения остаются в tooltip/AX. В C3-10 metadata `sourceLine` проверяется отдельно от её видимости. |

Баланс изменённых Swift, регистрация модели/тестов до AppKit, `bash -n build.sh`
и `git diff --check` пройдены. Swift/AppKit здесь не исполнялись. Нужен новый
полный `--subscriptions-selftest` в Терминале владельца, включая финальный manifest.

## Живой фокус редактора, `739974f`

После прежнего полного прогона обнаружено, что bitmap и модельные тесты не
проверяли получение клавиатуры. `beginCaptionEdit` создавал NSTextField и делал
только makeFirstResponder; PanelController использовал NSPanel без key override,
orderFrontRegardless, без activate/makeKey. Фактический canBecomeKey старого
NSPanel на Mac здесь не измерялся: в C5-12 добавлен diagnostic print без ложного
assertion о системном значении.

LimitsPanelWindow разрешает canBecomeKey только на время ввода и никогда main.
Вход: activate (14+/fallback13) → makeKey → makeFirstResponder. Выход:
clear responder → gate=false → orderOut → orderFrontRegardless, если popup
должен остаться видимым. При hide повторного показа нет. Это сохраняет
nonactivating style, popUpMenu level и hidesOnDeactivate=false.

Apple запрещает напрямую вызывать [resignKey](https://developer.apple.com/documentation/appkit/nswindow/resignkey()).
Оба [event monitor](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/MonitoringEvents/MonitoringEvents.html)
нужны потому, что global не видит события собственного приложения. Local
закрывает editor вне поля (Reset защищён), hide вызывается для другого своего
окна; окно status-item оставлено toggle, чтобы не получить hide→reopen.
Hide удаляет оба token, закрывает editor и его key eligibility.

| Старые проверки по уроку019 | Результат сверки |
|---|---|
| AppDelegate/PanelController startup, adaptive polling | Единственный прежний fixture с настоящим PanelController; он не показывается/не активируется. Добавлен assertion canBecomeKey=false/isKeyWindow=false. |
| C3-10 209 bitmap сцен, Settings/hits/AX | Нет key/firstResponder утверждений; не начинают редактирование. Счётчики/ошибки NSTextField — не editable labels. Старые ожидания сохраняются. |
| Manual refresh UI52, subscriptions Settings/panels | CGContext и реальные draw/hit bounds, без получения key; без изменений. |
| Auto88 и Auth120, GitHub42 | Геометрия/tooltip/модель; не активируют ввод. Новый C5-12 запускается после них и не меняет их данные/число PNG. |
| Manifest | Новый focus-тест не создаёт PNG, registry209/общий523 не меняется. C5-12 стоит до записи manifest, поэтому его FAIL остаётся гейтом. |

Новый `runCaptionEditorAppKitSelfTests` (C5-12) работает с RAM defaults и fake
account/frame: actual key, firstResponder editor/field editor, insertText без
ручного delegate notification меняет Team→TeamX и 5/32; Esc не сохраняет,
Enter сохраняет, Reset пишет tombstone, выходы снимают key/editor. Проверены
также local click вне поля/окна, status anchor и очистка monitor tokens.
Отдельного чистого предиката до AppKit нет: gate — AppKit-состояние панели.
Тест требует нового полного прогона владельца с WindowServer (RED).
