# Проверка Linux 0.4.4 на Astra — 2026-10-07

Статус: пакет, изолированные тесты, установка и запуск процесса приняты. Это Linux-проверка после обновления checkout, не реализация MANUAL-REFRESH. Исходники приложения не менялись.

## Область и исходное состояние

- Checkout обновлён fast-forward с `998cf0e` до `d607ff9fb8820164d9cdf9e880f859ed89547da6`; рабочая ветка `codex/alse-044-verification` создана на `d607ff9`. Проверки исходников относятся к этой базе; последующие изменения репозитория документационные.
- Исходно установлен `claude-codex-limits 0.3.2`; координатор обновил пакет через `pkexec dpkg -i`. Команда завершилась с кодом 0; `dpkg` подтвердил `0.4.4 / install ok installed`.
- Реальная машина: Astra Linux SE 1.8.5, системный Python 3.11.2, PyQt5 5.15.9, python3-dbus 1.3.2; сессия KDE/X11. Активность `ccl-sync.timer` сама по себе не подтверждает успешный обмен.
- `knowledge/claude-handoff/project` и `history` остаются архивом среза 5 октября; актуальные вводные обновлены отдельно.

## Опубликованный пакет — PASS

[linux-v0.4.4](https://github.com/ArrivaRUS/claude-codex-limits/releases/tag/linux-v0.4.4) опубликован 6 октября. Скачан `claude-codex-limits_0.4.4_all.deb`; SHA-256 совпал с digest GitHub API:

`5dc4a6b95e1780e36ee16fa7f4bc4eda21d4a4eaaf83a0f212527a00fc9c1ca5`.

Метаданные: версия 0.4.4, Architecture all, зависимости Python >= 3.7, PyQt5, python3-dbus. Все 32 исходных файла пакета совпали побайтно с checkout, несовпадений 0. Владельцы root/root, ожидаемые права 0644/0755; неожиданных путей, pyc/cache и conffiles нет. Wrappers вызывают `/usr/bin/python3`; `desktop-file-validate` завершился с кодом 0. Скрипты установки/удаления проверены чтением; QA их не запускал. Таймер рассчитан на 10 минут, service вызывает `ccl-sync push --auto --quiet`.

QA выполнил `dpkg-deb -f/-c/-x/-e`, `ar t`, `desktop-file-validate`, побайтное сравнение Python и `sha256sum`. Распаковка — только в QA-каталог. Детали: `/tmp/ccl-alse-20261007/qa/package-content.json`.

## Изоляция и принятый прогон — PASS

Исправленный runner независимо проверен CodeReviewer Astra/high до принятого запуска:

- `run-isolated.sh`: SHA-256 `e4f1be0161521e8397c39a4b55acaa7240a9ddbc9a76453b7e56f0155bf0fccc`.
- `run-suite.py`: SHA-256 `97dd989c3db47932b6f2fcc359ac187003c44015cdfe1e3bbb57601bd4a86286`.

Команда QA:

```sh
sh /tmp/ccl-alse-20261007/qa/run-isolated.sh > /tmp/ccl-alse-20261007/qa/suite.log 2>&1
```

Запуск выполнен через bwrap с разрешением на создание namespace, без fallback к хосту. `HOME` отсутствует в окружении; passwd fallback `/home/astra` ведёт в пустой tmpfs home. `/run` пустой, внешняя сеть отсутствует: доступен только loopback TCP для фикстур. Нет host credentials, пользовательских журналов, D-Bus и display. Системные библиотеки и исходники подключены read-only; writable только QA artifacts и временные каталоги. Qt работает offscreen с системными PyQt5/dbus и стилями Breeze/Fusion.

**306 тестов PASS; failures/errors/skips/expected failures — 0; exit 0; 71.276 секунды.** Получены 192 свежих PNG. QA просмотрел 4 из 192 PNG: скрытых значений или элементов управления в них не обнаружено. Existing layout tests покрывают Breeze/Fusion × RU/EN × три sync-state. Это не просмотр всех 192 изображений и не проверка реального рабочего стола.

Первый прогон не засчитан: временный runner без `main` guard рекурсивно запускал suite в multiprocessing children, а preview path вне `/tmp` нарушал fixture guard. Его результат 306 / 5 failures / 2 errors — ошибка runner, а не принятая проверка продукта. Артефакты сохранены отдельно в `invalid-run/`; исправленный runner устранил причины. Принятые результаты — только финальные `suite.log`, `suite-result.json` и `previews/`.

## Установка и оставшиеся границы

Установка через `pkexec dpkg -i` завершилась с кодом 0; `dpkg` показывает `claude-codex-limits 0.4.4 / install ok installed`. Координатор сравнил 38 установленных файлов с распакованным DEB: несовпадений 0. Выполнен user timer `daemon-reload`, `ccl-sync.timer` активен. Системный `ccl-sync` уже запущен; это не доказательство успешного обмена.

Штатный `/usr/bin/claude-codex-limits` запущен из установленного пакета; PID 249113 жив через 3 секунды, `exit_code: null`. Это проверка старта процесса; ручной smoke пользователя описан ниже. Проверка всех действий трея и работы KWallet/API не заявляется. Отчёты координатора: `/tmp/ccl-alse-20261007/installed-check.json` и `/tmp/ccl-alse-20261007/app-start.json`.

Пользователь лично подтвердил ручной smoke установленной 0.4.4 в KDE/X11: «Значок есть, панель открывается». Наличие значка и click-to-open подтверждены пользователем, а не автоматическим QA. Остальные действия, focus/позиционирование, пользовательские шрифты, native KWallet, live OAuth/API/gist и sleep/wake не проверены. Прямой запуск GUI из опубликованного пакета QA не выполнял: тестировался checkout, а эквивалентность пакета установлена отдельно. Offscreen Breeze не закрывает весь долг live ALSE. [Бэклог](../backlog.md).

Доказательства QA находятся в `/tmp/ccl-alse-20261007/qa/`: `REPORT.md`, `package-content.json`, `suite-result.json`, `suite.log`, runners и `previews/`. Долговечные копии доказательств: [suite-result.json](verification/alse-0.4.4/suite-result.json), [package-content.json](verification/alse-0.4.4/package-content.json), [run-isolated.sh.txt](verification/alse-0.4.4/run-isolated.sh.txt), [run-suite.py.txt](verification/alse-0.4.4/run-suite.py.txt). Временный каталог не является долговечным архивом. Исходники приложения после прогона остались на `d607ff9`; изменения репозитория в текущей задаче — документация, установленный системный пакет обновлён отдельно. Настоящие credentials, keyring, журналы и внешние API в тестах не использовались. Штатный production-запуск работает с обычным пользовательским входом; его содержимое не читалось. Успешность API/KWallet не заявляется.
