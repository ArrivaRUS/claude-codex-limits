# AUTH-1: независимый QA

Результат: PASS в согласованной области AUTH-1. Новых блокирующих дефектов не найдено. Это отчёт QA координатору, не приёмка всего выпуска.

## Проверенная ревизия и состояние

PROJECT_ROOT: `/Users/arrivarus/Documents/VibeCoding2/2026_06_UsageLimits`.
Проверенная ревизия: `a1f885f1138c327121fb7baf794e000edfea5695`.
В начале осмотра production был HEAD d77e215 + совместный diff; после freeze он зафиксирован в a1f885f. Повторная независимая проверка хешей после упаковки подтвердила неизменность:

- `Sources/LimitsMonitor.swift`: `3fca4e7578c93bd6865a932ad2911d5aad745a607fd61401dae0219e0ad63f19`.
- `linux/ccl/gui/panel.py`: `0fb8a8442a6d1a42ba2eba2172ccb4aa01a4022a898a13ae7b6c7e031750acaf`.
- `linux/tests/test_auth_hints.py`: `83e8ab6aeb3a2cc1915d9c93d92d278c485b3ad8880e021b3aadec6e03793068`.

На момент окончания QA незакоммичены только `backlog.md`, `docs/auth-hints-fix.md`, `docs/status.md`: 3 файла, 11 добавлений / 3 удаления. Это результаты/метаданные координатора; исходники и тесты не менялись. QA не изменял репозиторий или Git.

## Выполненная визуальная проверка

Фактическая среда QA — macOS. Linux-изображения получены из Ubuntu 22.04 CI, Qt offscreen, PyQt5/Breeze; это не live ALSE.

Независимо просмотрены все 88 новых macOS AUTH PNG и все 92 Linux `auth-*.png` (из 156 общих PNG). Для обзорного осмотра созданы 12 macOS и 13 Linux contact sheets в `/tmp`, затем критические/подозрительные случаи открыты в исходном размере через `view_image(detail=original)`.

macOS: `/tmp/ccl-auth-hints-*.png`; обзор `/tmp/ccl-auth-hints-qa-sheet-*.jpg`.
Linux: `/tmp/ccl-auth-hints-linux-previews/auth-*.png`; обзор `/tmp/ccl-auth-hints-qa-linux-sheet-*.jpg`.
Создание обзорных артефактов: bundled Python/PIL, скрипты `/tmp/ccl-auth-hints-qa-sheets.py` и `/tmp/ccl-auth-hints-qa-linux-sheets.py`. Исходные PNG не изменены.

Каждая ячейка ниже охватывает macOS и Ubuntu CI, single/both там, где соответствующая фикстура предусмотрена тест-планом.

| Сценарий | RU Simple | RU Advanced | EN Simple | EN Advanced |
|---|---|---|---|---|
| H1 Codex stale OK: age/network/reset/no-asOf, cache/empty | PASS | PASS | PASS | PASS |
| H2 stale Codex + fresh Claude | PASS | PASS | PASS | PASS |
| H3 stale Codex + Claude expired/loggedOut; Claude-only | PASS | PASS | PASS | PASS |
| H4 Claude keychainError/READ_ERROR, cache/empty; отсутствие login | PASS* | PASS | PASS* | PASS |
| H5 stale OK Claude/Codex и fresh OK | PASS | PASS | PASS | PASS |

У Codex stale OK — нейтральная подсказка, без Claude/Codex login-команд и ложного auth expiry. Сохранённые 31%/47% остаются видны в stale OK и Advanced error/auth fixtures; пустые данные обозначены прочерками. Nil asOf не получает выдуманной даты; прогноз темпа приостановлен. Свежая карточка рядом остаётся живой. В BOTH с ошибкой Claude команда `claude → /login` принадлежит только Claude и помещена отдельной строкой в Advanced. Новые строки читаемы, без перекрытия процентов/controls. Визуальных regressions AUTH-1 не обнаружено.

* Унаследованная косметическая P3 вне изменения AUTH-1: в узкой Simple карточке обоих продуктов длинная подпись readError выходит за границы карточки. macOS RU: `проверьте доступ к «Связке ключей»`; Linux: `проверьте ~/.claude/.credentials.json` / EN counterpart. Linux пример `/tmp/ccl-auth-hints-linux-previews/auth-claude-readError-ru-False-True.png`: левая карточка x≈16..175, подпись начинается за левым краем изображения и кончается около x192. В macOS bitmap720 левая карточка x≈31..349, подпись x≈8..369. Репродукция: синтетический Claude read error, Simple, обе подписки. Read-only diff относительно d77e215 подтверждает прежний текст/геометрию problem body для Claude. Recovery/login отсутствует корректно. Координатор отделил P3 в Could backlog; текущая AUTH-1 не расширена. Simple problem body по прежнему скрывает график при readError/logout; это не новая потеря cache.

## Проверенные журналы, без повторного запуска suite

- `/tmp/ccl-auth-hints-selftest.log`: независимо прочитаны результаты безопасного selftest: 1063 строк OK, 687 auth checks, 88 AUTH PNG, итог `Subscription selection and adaptive polling selftest passed`. Выполнение/exit0 — координатор, QA не запускал бинарь.
- `/tmp/ccl-auth-hints-linux-tests.log`: независимо прочитаны 7 новых auth tests `ok`, `Ran 219 tests in 28.310s`, итог `OK`, без skip. CI run `37133915949` на exact a1f885f — по handoff координатора. QA не перезапускал suite.
- Hit targets и dispatch покрыты assertions/независимым Reviewer; QA визуально сопоставил продукт и область карточки. Реальные mouse clicks/URL/auth flows не выполнялись.

## Независимая проверка упаковки

DMG: `/Users/arrivarus/Documents/VibeCoding2/2026_06_UsageLimits/dist/ClaudeCodexLimits-3.2.2.dmg`.
SHA256: `81cb356ea762787cb08caca44e8fa1617d383a7d29ef3a606da840c5c121376c`.
Фактически выполнены QA:

- `shasum -a 256` — совпадает с handoff.
- `hdiutil verify` — exit0, VALID.
- `hdiutil attach -readonly -nobrowse -mountpoint /tmp/ccl-auth-hints-qa-dmg ...` — exit0.
- `codesign --verify --deep --strict '/tmp/ccl-auth-hints-qa-dmg/Claude Codex Limits.app'` — exit0.
- `plutil -p .../Contents/Info.plist` — short version/build 3.2.2, min macOS 13.0, LSUIElement true.
- `hdiutil detach /tmp/ccl-auth-hints-qa-dmg` — exit0; mount удалён.

Packaged executable selftest 1063 OK/exit0 выполнен координатором; QA его не повторял и приложение не запускал.

DEB: `/tmp/ccl-auth-hints-linux-deb/claude-codex-limits_0.4.2_all.deb`.
SHA256: `bbadec59e34a0797f87620f8b2cb60f395f57b3eb60748d692f082a7e7f45f19`.
Фактически выполнены QA: `shasum -a 256`, `ar -t`, `ar -p ... control.tar.xz | tar -xOf - ./control`, `ar -p ... data.tar.xz | tar -tf -` — exit0. Debian ar содержит debian-binary/control.tar.xz/data.tar.xz; Version 0.4.2, Architecture all, Python3/PyQt5/dbus dependencies. Содержимое включает 15 ccl Python modules, entry scripts, desktop/icon/assets, user service/timer. Побайтное сравнение модулей/scripts/assets с a1f885f выполнено координатором; QA независимо проверил metadata и listing, не заявляет повторное byte comparison.

## Ограничения и изменения QA

Нет live ALSE/KDE, установки DEB, проверки иных системных fonts/DPI, native window manager, реальных mouse interactions, учётных записей, CLI/login/browser, keyring, пользовательских журналов, API/network. Это осмотр безопасных bitmap fixtures, журналов CI и готовых пакетов. Никаких обычных запусков приложения или unsafe preview flags.
QA создавал только `/tmp/ccl-auth-hints-qa-report.md`, два QA montage script и 25 contact sheets. Production/tests/config/Git не изменены. Screenshot пользователя просмотрен как исходное доказательство дефекта.
