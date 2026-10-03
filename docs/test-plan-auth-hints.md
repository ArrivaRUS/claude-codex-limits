# Регрессия: подсказка входа относится к продукту карточки

2026-10-03. План до реализации; база `main`, `5da11436898cd810a42afa88b7b12e21ea4dd099`.
Область: macOS и Linux, RU/EN, Simple/Advanced. Проверки ниже пока **не запускались**.

## Контракт и наблюдаемый дефект

В macOS `drawAdvanced` сейчас добавляет `claude login` в каждую карточку с
`expired=true`, включая Codex со stale snapshot. В production Codex сохраняет
`auth.OK`: это отсутствие классификации входа, а не подтверждение авторизации.
Основной регрессионный сценарий — Codex stale при `auth.OK`; нужна нейтральная
подсказка обновления, без login-команды и нового flow восстановления Codex.
Login hint и `claudefix` остаются только у Claude loggedOut/expired.
Keychain/readError не получают login-команду; stale auth.OK любого продукта
получает нейтральный refresh copy. Текущие targets карточек сохраняются.

Сохранённые проценты, время последнего успешного чтения и выбор подписок
остаются прежними; замороженные данные не получают живой прогноз темпа.
При отсутствии cache не показывается выдуманная дата последнего чтения.

## Матрица

Каждый H1–H5 проверить на обеих платформах в RU/EN × Simple/Advanced.
Фикстуры целиком синтетические: cached session=31%, weekly=47%, известное `asOf`;
no-cache — nil процентов и даты. Основной Codex stale auth.OK расширить вариантами
age, network error, reset в прошлом и отсутствующий `asOf`; свежий OK задавать
с reset в далёком будущем или фиксированными часами. `asOf=nil` не заменять Date().

| ID | Фикстура | Наблюдаемое ожидание |
|---|---|---|
| H1 | Только Codex; stale auth.OK: age/network/reset/no-asOf; с cache и без cache | Нейтральная подсказка обновления; нет команды/инструкции входа Claude или Codex. Текущий Codex target сохранён, никогда `claudefix`. 31%/47% видны; пустые значения не превращаются в нули, nil asOf не получает текущую дату. |
| H2 | Обе подписки; Codex stale auth.OK, Claude свежий OK | Подсказка и hit проверяются в области Codex; Claude остаётся обычной живой карточкой. Порядок/доступность подписок не меняются. |
| H3 | Обе подписки: Codex stale auth.OK и Claude loggedOut/expired; также Claude-only | Только Claude получает собственный login hint и `claudefix`; Codex — нейтральный refresh copy и прежний target. В both проверять карточки по продукту/геометрии, не искать отсутствие `claude` по всей панели. |
| H4 | Claude keychainError (на Linux READ_ERROR), с cache и без; helper guards для Codex readError | Нет login-команды и `claudefix`; ошибка доступа не выдаётся за истёкший вход. Cache, nil asOf и обычный target сохраняются. Synthetic Codex readError — только defensive coverage, не reproduction production. |
| H5 | Stale auth.OK каждого продукта, затем свежий OK | Stale получает нейтральную подсказку обновления, cache сохранён, темп приостановлен. При свежем OK подсказка исчезает, обычный target продукта остаётся. |

Для Advanced проверить карточку шириной 360 pt/px: длинные RU/EN строки,
команда и проценты читаемы, не выходят за карточку и не перекрывают controls.
Simple: оба продукта в узкой карточке и одиночный Codex на всю ширину.
Сверять реально рисуемую строку и hit rect; Swift helper assertions дополнять
actual PNG и независимым Reviewer, Linux проверяет текст непосредственно в draw.

## Безопасные seams и минимальные тесты после freeze

- Linux: новый `linux/tests/test_auth_hints.py`, первый импорт `_isolate`, до `ccl`.
  `common._settings` — временный Store; `panel.Model` — синтетические LimitData;
  `QImage`/`Canvas` через `draw_simple`/`draw_advanced`. Перехват `Canvas.text` и
  `text_c` по примеру `test_auto_ui.py` проверяет фактический текст и его координаты;
  возвращённые hits проверяют продукт и область действия. Dispatch через
  `TrayApp.action` с fake app и моками `QDesktopServices.openUrl`, страниц и hide:
  никаких настоящих переходов браузера и запуска CLI. Можно тестировать без
  создания настоящего `TrayApp`.
- macOS: существующий `--subscriptions-selftest` (ранний exit до AppDelegate),
  volatile `NSArgumentDomain`, `drawSimple`/`drawAdvanced` на bitmap CGContext и
  возвращённые Hit. Добавление тестовых фикстур внутри этой ветки после передачи
  области записи координатором; source не редактируется одновременно Developer
  и Tester. Текст проверять shared helper fixtures + actual PNG + независимым
  Reviewer, подтверждающим применение helper в обоих renderer; production
  text-observer seam для этой задачи не вводить.
  MouseDown/URL dispatch проверять статически либо с запрещающим фейком открытия;
  реальный click/browser/CLI не выполнять в selftest.
- Общие проверки: сравнить исходные значения модели до/после draw; повторный draw
  не меняет auth/cache/настройки и не вызывает I/O. Новый регрессионный case должен
  падать на старом renderer с `claude login` в Codex. Это доказательство отдельно
  от успешного прогона после исправления; mutation только во временной копии.

## Изоляция перед запуском

Уроки 006/011 обязательны. Linux `_isolate` перенаправляет XDG и CLI-пути,
запрещает `common.http`/`sync.transport`, отключает `vault._ss`. Для новых UI-тестов
дополнительно запрещающие моки `vault.read`, `vault._file_get`, `sync.sync_cycle`,
`limits.fetch_claude`, `limits.fetch_codex`, `usage.refresh` и записи settings.
Не рассчитывать на not-due или состояние expired как защиту от I/O.
`test_zz_isolation.py` сверяет лишь наличие/mtime реальных sync-файлов.

macOS: до запуска повторно просмотреть selftest-ветку на текущей ревизии.
Сохранить existing offline transport/keychain, временный fixture-root сканирования,
volatile defaults и ранний выход. Не вызывать production refresh/sync по реальным
часам; новые draw-функции не читают реальные CLI credentials/logs.
`--sync-selftest` существует, но auth UI относится к `--subscriptions-selftest`;
расширять обе ветки для этого дефекта не требуется.
Запрещены обычное приложение, unsafe previews, `/usr/bin/security`, реальные
keyring/credentials/logs, gist/API. PNG и бинарь — только `/tmp`.

## Рекомендуемые запуски и приёмка

После независимой проверки изоляции новых фикстур:

```sh
QT_QPA_PLATFORM=offscreen python3 -m unittest discover -s linux/tests -p 'test_auth_hints.py' -v
QT_QPA_PLATFORM=offscreen python3 -m unittest discover -s linux/tests -p 'test_subscriptions.py' -v
QT_QPA_PLATFORM=offscreen python3 -m unittest discover -s linux/tests -v
mkdir -p /tmp/ccl-auth-hints
/usr/bin/swiftc -O Sources/LimitsMonitor.swift -o /tmp/ccl-auth-hints/LimitsMonitor-selftest
/tmp/ccl-auth-hints/LimitsMonitor-selftest --subscriptions-selftest
```

Зафиксировать ревизию + diff, exit codes, run/skip и PNG. PyQt5/WindowServer
недоступен или GUI skipped — соответствующая проверка не выполнена.
QA независимо смотрит bitmap H1–H3 в обоих видах/языках; живой KDE/ALSE и actual
mouse click не объявлять пройденными по offscreen/статическому dispatch.
Исторические 212 Linux / 288 Swift проверок не доказывают эту правку.
