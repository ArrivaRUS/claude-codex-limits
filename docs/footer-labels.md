# Убрать служебные подписи внизу карточек Linux

2026-10-09. Запрос владельца установленной Linux 0.4.5: надписи «Проверено» и
«Данные» снизу в карточках лишние. Ветка `codex/compact-footer-labels`, исходный
HEAD `b94f95d8d6c53ed6c8beba09b7575e21252e715a`.

## Текущий статус local2

Local2 установлен: пустой footer занимает 0 px, одна строка — 16 px,
статус с действием — 32 px. Simple выравнивает карточки по максимуму,
Advanced сжимает каждую отдельно; открытое окно меняет высоту через
`page0_changed`. При пустом footer подсказка доступна на иконке продукта.
База `db28943`, ветка `codex/compact-card-height`.

Финальный panel SHA-256
`b364434440260b833722f27ff4738a77a03fe23315dc7d465097bc76e24896f3`;
app `b00882aa621774cc8b74a4b47a18af9f20a93671ccce245f9356e30cbfa51a05`.
Code narrow review и test/runner constant delta — PASS по сообщению координатора.
Повторный изолированный suite: **45 PASS, 0 failures/errors/skips**.
Дизайн — PASS: 8 пар / 16 PNG для остальных участков и 3 финальных PNG
после добавления 3 px Simple padding при пустом feedback. P2 закрыт:
нижний отступ текста теперь 6–7 px. Обычный Simple 318→289 px (−29),
Advanced 520→456 px (−64).

[Suite](verification/footer-space/suite-result.json),
[дизайн](verification/footer-space/design-review.json),
[freeze](verification/footer-space/after-freeze.json).
Финальные 48 actual Qt-переходов — PASS:
Simple 289→302→302→289→302→318 px,
Advanced 456→488→488→456→472→488 px.
[Переходы окна](verification/footer-space/window-transitions.json).
Пакетная проверка — PASS: 39 файлов exact, panel/app совпадают с принятыми
SHA; scripts и modes сохранены. APP_VERSION `0.4.5`, Debian Version
`0.4.5+local20261009.2`.
DEB SHA-256 `f95722e993ead3b1a09d3ec7a90a22a94053e5515acc472b68c1a3d85e1ce920`.
[Пакет](verification/footer-space/package-inspection.json).
Установка координатором: installer exit 0 после polkit; dpkg
`0.4.5+local20261009.2 install ok installed`; 39 установленных файлов
SHA/mode/uid/gid exact, 0 mismatches; `ccl-sync.timer` active.
Старый GUI PID 96441 завершён SIGTERM, новый PID 156126 через
`/usr/bin/claude-codex-limits` жив спустя 3 с, exit code null.
[Установленные файлы](verification/footer-space/installed-check.json),
[старт процесса](verification/footer-space/app-start.json).
Нового GitHub-релиза и push нет. Ручное подтверждение UI, native hover,
успешный API-обмен/KWallet, пользовательские шрифты и sleep/wake не проверены.

Предыдущий критерий сохранения размеров заменён запросом убрать пустые отступы.
Проверки local1 ниже не доказывают готовность local2.

## История local1: план и критерии UI

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

## История local1: изменения и проверка

Реализация ограничена `linux/ccl/gui/panel.py`: общие `feedback_copy` и
`draw_feedback`. Backend, APP_VERSION и интервалы не меняются. Подготовлен локальный DEB
`0.4.5+local20261009.1` при APP_VERSION `0.4.5`; нового GitHub-релиза нет.

Автор выполнил проверку синтаксиса и AST-only матрицу с полностью искусственными
зависимостями: 56 случаев RU/EN × Claude/Codex × idle, success, отсутствующая/
будущая дата, pending/flight, failure, server/local wait и auth. Проверены видимый
текст, tooltip, сохранность состояния и hit-области действий. PASS; модули ccl/
PyQt, credentials, keyring, API и пользовательские журналы не использованы.

## История local1: итог независимых проверок

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

## История local1: установка и границы

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

## Убрать пустой резерв — 2026-10-09

После установки локального патча владелец сообщил: «там пустого места теперь
куча в карточках». Это меняет прежний критерий сохранения размеров; результаты
выше относятся к предыдущей версии. База исправления — HEAD `db28943237d038f1fa9e4bb311c6a1c9f9b631f1`.

Единый `feedback_height` задаёт 0 px для пустого footer, 16 px для одной строки
и 32 px для состояния с действием. Simple выравнивает карточки по необходимому
максимуму, Advanced сжимает каждую отдельно; уменьшается и высота панели.
Статусы, действия, scoped/auth/missing rows и история сохраняются. В обычном
состоянии подсказка доступна на существующей иконке продукта, а в отсутствующей
Advanced-карточке — на узкой части строки названия. Остальная область карточки
сохраняет прежний open/settings click. Первый этап не менял backend и `app.py`.

Итоговая визуальная проверка — PASS, факты приведены в текущем статусе local2
выше. Авторская AST-only матрица: 56 случаев sizing/copy/draw/hits PASS,
дополнительные missing/scoped/off/partial-completion проверки PASS;
сам автор реальный GUI и сборку не запускал.

Независимое review обнаружило, что публикация feedback только перерисовывала
панель: размер уже открытого окна оставался прежним при начале обновления и
истечении ожидания. В `publish_auto_intervals` теперь используется существующий
`page0_changed`: высота и положение обновляются только для видимой основной
страницы, затем выполняется repaint. Этот путь вызывается и при публикации
pending, и существующим секундным feedback tick; backend, запросы и таймеры
не меняются. Независимый QA проверил 48 actual Qt transitions финального состояния — PASS.
