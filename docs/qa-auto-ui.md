# QA Auto UI — независимый отчёт

> Итог доступных артефактов: PASS на `5b722a1`. Это последовательный отчёт;
> промежуточные ожидания ниже закрыты в финальных разделах. Живой ALSE и
> hover/click/user fonts остаются непроверенными; актуальная сводка — status.md.

Дата 2026-10-03. Роль qa, GPT-6.1 Sol/high; фактическая машина macOS 26.6.2 (25G83), arm64. Исходники, тесты, настройки и Git QA не редактировал. Обычное приложение и unsafe preview QA не запускал.

## Ревизия и артефакты

На начале проверки HEAD f311c4e33d6a840cd8d8a00b3961e6dd2958d81e + рабочий дифф реализации/тестов/документации. Финальный Swift source SHA256 5d277016d5a3d2f590519bbef642f31d40a92bc399dbd214f5e35808f7652910. Первая партия PNG просмотрена до финальной правки только selftest; production renderer не менялся. После freeze просмотрены дополнительные 24 PNG и сверён финальный hash. Финальная компиляция и selftest запуск выполнены координатором; QA читал /tmp/ccl-auto-ui-selftest-final.log (passed, без FAIL).

Осмотрены 40 PNG /tmp/ccl-auto-ui-{different,equal,backoff,paused,single-codex-15,single-codex-30,single-codex-60,single-codex-240,manual-60,long}-{ru,en}-advanced-{false,true}.png. Дополнительно осмотрены 4 singleCodex=30m PNG /tmp/ccl-subscriptions-panel-{ru,en}-{false,true}-paused-false.png.

## Визуальная матрица macOS

| Сценарий | RU Simple | RU Advanced | EN Simple | EN Advanced |
|---|---|---|---|---|
| Одна Codex, 15m | PASS | PASS | PASS | PASS |
| Одна Codex, 30m | PASS | PASS | PASS | PASS |
| Одна Codex, 1h | PASS | PASS | PASS | PASS |
| Одна Codex, 4h | PASS | PASS | PASS | PASS |
| Две, equal=30m | PASS | PASS | PASS | PASS |
| Две, different=Claude15m/Codex4h | PASS | PASS | PASS | PASS |
| Backoff=Claude1h/Codex15m | PASS | PASS | PASS | PASS |
| Long=Claude30m/Codex15m | PASS, одна строка | PASS, одна строка | PASS, одна строка | PASS, одна строка |
| Alloff | PASS | PASS, Simple fallback | PASS | PASS, Simple fallback |
| Manual=1h | PASS | PASS | PASS | PASS |

Во всех Auto-on PNG капсула отдельная, расположена между manual и подписью. Ни один manual сегмент не выделен. Значения подписаны справа; при different/backoff/long имена полные, Claude первым. Power и credits не пересекаются с подписью. Auto-footer не содержит timestamp. Manual PNG показывают ровно выделенный 1h/1ч, неактивную контрастную Auto-капсулу, отсутствие динамической подписи и старый timestamp справа. Продуктовых визуальных дефектов не найдено.

Из final selftest log подтверждены наблюдаемые bitmap/hit/tooltip assertions: bounds iv900/1800/3600/0 и quit, no overlap, Auto timestamp отсутствует в bitmap, manual timestamp присутствует, tooltip Auto содержит timestamp и product-specific error, nil timestamp пропущен. QA не выдаёт эти assertions за живое наведение или клики.

## Независимая метрика

QA создал только чистый /tmp/ccl-auto-ui-qa-metrics.swift (AppKit/CoreText, без defaults, I/O аккаунта, таймеров, сети), скомпилировал `/usr/bin/swiftc -module-cache-path /tmp/ccl-auto-ui-qa-modulecache /tmp/ccl-auto-ui-qa-metrics.swift -o /tmp/ccl-auto-ui-qa-metrics` и выполнил `/tmp/ccl-auto-ui-qa-metrics`: exit0. Font — NSFont.systemFont(10,medium), тот же CoreText descriptor, что renderer.

- RU Claude30м/Codex15м и обратная пара: 120.4685533 pt.
- EN Claude30m/Codex15m и обратная пара: 122.8596699 pt.
- Все ≤128; штатный двухстрочный branch на текущем Mac не нужен. Проверка фактического Linux overflow остаётся отдельной.

Реально выполненные QA read-only команды: cat/rg/sed по роли, спецификации, test-plan и offline branch; git status --short, git rev-parse HEAD, git diff --stat; shasum -a256 исходников/бинарника; file бинарника; sw_vers; view_image всех перечисленных PNG. Selftest QA не перезапускал.

## Пока не проверено

Linux CI/DEB и финальная macOS DMG ожидаются от координатора. Реальная Astra Linux SE/KDE/Fly, реальные аккаунты, keyring, пользовательские журналы, сеть, live clicks и tooltip hover не проверены. Claude-only отдельные PNG отсутствуют; одинаковый shared formatter имеет assertions для каждого singleClaude и singleCodex во всех четырёх интервалах, но это не отдельный визуальный проход Claude-only.

## Финальная macOS упаковка — независимая проверка

К 2-й части проверки HEAD fe3a3c48fd7e014fb610fea7e1748071d65d1dc8, git status --short пустой. Swift source hash 5d277016... неизменён; Linux production hashes panel.py=2f0087acb7cbb7f120ef4cb26d13a9e630fd09bb640b5dfc6af7578250f7be59, app.py=3e9787342d7263c56a57b12ce7b28cf9818ebf63a0fe5cbaec4884211f796dea.

Пакет /Users/arrivarus/Documents/VibeCoding2/2026_06_UsageLimits/dist/ClaudeCodexLimits-3.2.1.dmg SHA256 85d7cdcf0c20151f755f4f9608fdda9a5cba8c192f8efbf5457c67fcdc0f6c8d.

QA реально выполнил:

- `hdiutil verify dist/ClaudeCodexLimits-3.2.1.dmg`: exit0, checksum VALID.
- `hdiutil attach -readonly -nobrowse -mountpoint /tmp/ccl-auto-ui-qa-dmg ...`: sandbox attempt exit1 «Устройство не сконфигурировано»; approved escalation attempt exit0.
- `codesign --verify --deep --strict '/tmp/ccl-auto-ui-qa-dmg/Claude Codex Limits.app'`: exit0.
- `plutil -p` mounted app Info.plist: version/bundle version3.2.1; minimum macOS13.0, CFBundleExecutableClaudeCodexLimits, LSUIElement=true.
- `file` mounted executable: Mach-O64bit arm64.
- `hdiutil detach /tmp/ccl-auto-ui-qa-dmg`: exit0, disk ejected.

Обычный запуск, учётные данные, сеть и реальные logs не использовались. QA читал packaged selftest log /tmp/ccl-auto-ui-packaged-selftest.log: passed; запуск был координатором. Packaged selftest overwrite 40 PNG тем же renderer; QA повторно просмотрел packaged longEN Simple и manualRU Advanced: реальные assets видны, footer остаётся PASS.

Отдельное ограничение: `codesign --verify --deep --strict 'dist/Claude Codex Limits.app'` на локальной cloud-staged копии exit1 «resource fork, Finder information, or similar detritus not allowed». Это не дефект финального DMG: его readonly mounted app выше независимо прошёл strict verify. Пользователю предназначается проверенный DMG.

CI run37106329175 имеет 1 тестовую collector error при 212 tests; production не засчитан в Linux PASS до нового прогона. Финальные Linux PNG/DEB ещё ожидаются.

## Финальный Linux CI/артефакт — независимый осмотр

CI run37106534056, source SHA5b722a17e9683033ae269fc788708a7bcd5feeb7. QA сверил HEAD на эту SHA и пустой git status --short. Последний commit после fe3a3c4 менял тестовый collector/status; production hashes прежние. Фактическая среда рендера — Ubuntu22.04 CI, Qt offscreen, PyQt5 и kde-style-breeze установлены; это не live Astra Linux SE.

QA читал /tmp/ccl-auto-ui-linux-tests-final.log: полный unittest `Ran212 tests in27.456s`, итог `OK`, без skip/xfail. Все7 test_auto_ui — ok, включая state→view wiring, tooltip timestamp/error и width128/129 branch. Запуск CI выполнен workflow, QA не запускал приложение.

Через view_image QA независимо просмотрел все48 `auto-ui-*.png` в /tmp/ccl-auto-ui-linux-previews. Группа16 lang×advanced×enabled покрывает different, singleClaude15m, singleCodex4h, alloff/fallback; группы32 покрывают equal, backoff, long, manual60 и singleCodex4значения.

| Сценарий Linux | RU Simple | RU Advanced | EN Simple | EN Advanced |
|---|---|---|---|---|
| Claude-only15m | PASS | PASS | PASS | PASS |
| Codex-only15m/30m/1h/4h | PASS | PASS | PASS | PASS |
| Equal30m | PASS | PASS | PASS | PASS |
| DifferentClaude15m/Codex4h | PASS | PASS | PASS | PASS |
| BackoffClaude1h/Codex15m | PASS | PASS | PASS | PASS |
| LongClaude30m/Codex15m | PASS, одна строка | PASS, одна строка | PASS, одна строка | PASS, одна строка |
| Alloff | PASS | PASS, fallback | PASS | PASS, fallback |
| Manual1h | PASS | PASS | PASS | PASS |

Footer подписи читаемы, Auto контрастна и отделена, Autoon не выделяет manual, fullClaude/Codex сохраняются, в разных интервалах Claude первый. На longPNG текущий Linux CI font также помещает текст в одну строку, без пересечения сpower. Manual1h имеет одно выделение иinactiveAuto, старыйtimestamp справа; Autoon timestamp в футере отсутствует. Дефектов в затронутом Autofooter не найдено.

Отдельное ограничение доказательств: двухстрочный overflow при mocked joinedwidth129 проверен CI assertions на реальные draw calls/межстрочныйшаг12 иlabelbounds128×24; bitmap двухстрочного branch не сохранён, визуально его QA не проверял. Фактический UbuntuCI font ни в одном longPNG не вызывает overflow. LiveAL SE/Breeze с пользовательским шрифтом остаётся открытой проверкой.

### DEB

QA read-only выполнил `ar -t`, `ar -p ... control.tar.xz | tar -xOf - ./control`, `ar -p ... data.tar.xz | tar -tvf -`, `shasum -a256` — всеexit0. Ничего не установлено, maintainer scripts не выполнялись.

DEB /tmp/ccl-auto-ui-linux-deb/claude-codex-limits_0.4.1_all.deb; SHA256fdd77530c796aad7f72a433cc3356ff4bec627bbba53d35b99187027c3e33801. Debian archive membersdebian-binary/control.tar.xz/data.tar.xz; xz соответствует совместимому формату. Control version0.4.1, architectureall, dependenciespython3>=3.7/python3-pyqt5/python3-dbus. Entries root:root, directories755, wrappers755; Python modules/resources644. Имеются cclapp/panel, resources, desktopentry, icon иsystemduserunits; __pycache__ в пакете нет. Installed runtime/package smoke на Linux/ALSE QA не выполнял. Побайтное сравнение всех packagedccl modules сcheckout выполняет координатор отдельно.

## Итог области QA

Независимый visual/package QA доступныхmacOS иUbuntuCI артефактов PASS, продуктовых дефектов не найдено. Это не принятие всей задачи и не liveALSE approval. Остаточные ограничения: реальные hover/click, пользовательскиеfonts/liveALSE, rastertwo-row branch. Исходники/тесты/конфигурация/Git QA не менялись; результаты только/tmp/ccl-auto-ui-qa*.

Дополнение координатора: все 15 Python-модулей ccl, оба entry scripts и все PNG/WAV assets DEB побайтно сверены с checkout 5b722a1; совпадают. Эта сверка выполнена координатором, QA отдельно проверил metadata и contents. Координатор принял документированное ограничение двухстрочного raster: draw/text/bounds assertions проходят, фактический long в используемом CI font остаётся одной строкой.
