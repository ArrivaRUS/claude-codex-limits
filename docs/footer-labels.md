# Убрать служебные подписи внизу карточек Linux

2026-10-09. Запрос владельца установленной Linux 0.4.5: надписи «Проверено» и
«Данные» снизу в карточках лишние. Ветка `codex/compact-footer-labels`, исходный
HEAD `b94f95d8d6c53ed6c8beba09b7575e21252e715a`.

## План и критерии UI

- В Simple и Advanced, RU/EN, для Claude и Codex удалить из видимого footer
  строки «Проверено» / Checked и «Данные» / Data вместе со временем. Убрать время
  снимка рядом с сообщением ошибки/восстановления и лишние разделители.
- В обычном idle/success состоянии footer не рисует служебный текст. Сохранить
  композицию и размеры карточек; область подсказки остаётся доступной.
- Сохранить сообщения обновления, ошибок, ожидания сервиса и локальной защиты,
  действия повтора/восстановления и правила доступности действий.
- Подсказка сохраняет время данных, полный timestamp снимка, признак свежего
  ответа, детали ошибок и сроки повторного/автоматического запроса. Отсутствующая
  или будущая дата не превращается в текущую.

## Изменения и проверка

Реализация ограничена `linux/ccl/gui/panel.py`: общие `feedback_copy` и
`draw_feedback`. Backend, APP_VERSION и интервалы не меняются. Подготовлен локальный DEB
`0.4.5+local20261009.1` при APP_VERSION `0.4.5`; нового GitHub-релиза нет.

Автор выполнил проверку синтаксиса и AST-only матрицу с полностью искусственными
зависимостями: 56 случаев RU/EN × Claude/Codex × idle, success, отсутствующая/
будущая дата, pending/flight, failure, server/local wait и auth. Проверены видимый
текст, tooltip, сохранность состояния и hit-области действий. PASS; модули ccl/
PyQt, credentials, keyring, API и пользовательские журналы не использованы.

## Итог независимых проверок

Проверяемый файл `linux/ccl/gui/panel.py`: SHA-256
`2c8d52b8cd1c5e85c40dc378e870fc99bdccb8bb7902de16148164450dd34df2`,
поверх HEAD `b94f95d8d6c53ed6c8beba09b7575e21252e715a`.

- Code/isolation review — PASS по сообщению координатора.
- Изолированный offscreen-прогон существующих focused-тестов — **23 PASS,
  0 failures/errors/skips**, 45.429 с, 180 итоговых PNG; QA-матрица — 32 сценария.
  Первый after-прогон с 20 устаревшими auth-subcase ожиданиями не засчитан.
  Исправлены только ожидания в `test_auth_hints.py` и
  `test_linux_compact_refresh.py`; guards и production-файл сохранились.
- Независимый DesignReviewer — PASS: просмотрены 78 уникальных PNG
  (38 before/after пар и 2 прежних референса). Размеры, ошибки, ожидание и
  действия сохранены. Это сравнение изображений, не live desktop/hover smoke.
- Пакет — PASS: 39 payload-файлов совпали с принятой сборкой/исходниками;
  единственное отличие packaging — control Version `0.4.5+local20261009.1`.
  APP_VERSION остаётся `0.4.5`; maintainer scripts совпали.
  DEB SHA-256 `42d53bd977cb139b6e39829c6f4d3dbdf5b51cd955715c26ff6542452ead80f9`.

Доказательства: [suite result](verification/footer-labels/suite-result.json),
[package inspection](verification/footer-labels/package-inspection.json),
[изолированный runner](verification/footer-labels/run-isolated.sh.txt),
[suite-команды](verification/footer-labels/run-suite.py.txt),
[build isolation](verification/footer-labels/build-isolated.sh.txt),
[сборка пакета](verification/footer-labels/build-package.sh.txt),
[установочный скрипт](verification/footer-labels/install-verified.sh.txt).
Примеры: [Simple до](verification/footer-labels/before-simple-ru.png) /
[после](verification/footer-labels/after-simple-ru.png),
[Advanced до](verification/footer-labels/before-advanced-ru.png) /
[после](verification/footer-labels/after-advanced-ru.png).

## Локальный патч и границы

Локальная установка выполнена координатором командой
`sh /tmp/ccl-footer-20261009/install-verified.sh`: exit 0 после polkit;
dpkg показывает `0.4.5+local20261009.1 install ok installed`.
39 установленных файлов совпали с DEB по SHA/mode/uid/gid, 0 mismatches;
timer active. Старый GUI PID 4056 завершён SIGTERM; новый PID 96441,
entrypoint `/usr/bin/claude-codex-limits`, жив через 3 секунды, exit code null.
APP_VERSION `0.4.5` ожидаем: локальная метка находится в Debian control.
[Проверка установленных файлов](verification/footer-labels/installed-check.json),
[запуск](verification/footer-labels/app-start.json). Это доказательства установки
и старта процесса; интерактивный hover и подтверждение владельца не получены. Нового GitHub-релиза нет. CI 358 тестов релиза `linux-v0.4.5`
относится к source `19440ee112f164b411bf4715d6fa65077a272c48`, не к этому патчу.
Полный suite для нового патча не запускался. Реальные API/KWallet, успешный
обмен, live hover, пользовательские шрифты и sleep/wake не проверены.
