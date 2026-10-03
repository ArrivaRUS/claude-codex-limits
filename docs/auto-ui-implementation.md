# Auto UI — минимальный план реализации

2026-10-03 · Architect/challenge, только Codex. PROJECT_ROOT: `/Users/arrivarus/Documents/VibeCoding2/2026_06_UsageLimits`. Проверенная база: `e6e2f2e6f7c46da69b9cf14dedf53489963ef9a4`; ветка `codex/auto-button-frequency`.

**PASS для передачи Developer. Блокеров нет.** Свежий PRD согласован с `design/auto-poll-ui.md`: одна подписка/равные интервалы → одно время; разные → Claude/Codex с их временем; обе off → `нет подписок`/`no subscriptions`; причина backoff в tooltip. Достаточны передача текущих чисел и перерисовка. Алгоритм, таймеры, сеть и формат сохранения не меняются. Контур Auto оставить статичным, существующие cursor/tooltip сохранить; новая обработка hover/focus не требуется.

## Wiring для Developer

Файлы: `Sources/LimitsMonitor.swift`, `linux/ccl/gui/panel.py`, `linux/ccl/gui/app.py`. Нового модуля не требуется. Номера строк относятся к базе.

1. Источник: Swift `AppDelegate.autoStates` (4763), Linux `TrayApp.poll_states` (797). Брать собственный `state.interval` каждого продукта; `view.interval`/`model.interval` — сохранённый manual, его не подменять. Фильтровать по `productEnabled`/`common.product_enabled`, не по `LimitData.present` или карточкам. Default отсутствующего состояния — 1800, как в существующих конструкторах.
2. Добавить `LimitsPanelView.autoIntervals: [String: TimeInterval]` и `panel.Model.auto_intervals` — копии чисел. Helper `publishAutoIntervals()` / `publish_auto_intervals()` копирует значения владельца и вызывает repaint, без I/O/refresh. Первоначально заполнить после загрузки states: Swift после создания `PanelController`, Linux до `PanelWindow` (без repaint отсутствующего окна). Публиковать также из `saveAutoStates()` / `save_poll_states()`, независимо от успеха сохранения. Это покрывает observe/backoff/local activity; startup публикуется отдельно.
3. Swift передаёт snapshot из `LimitsPanelView.draw` в `drawPanel`/`drawAdvanced`, включая fallback Advanced → Simple (3076–3078); Linux читает его из model. Чистый helper `autoPollLabelParts` / `auto_poll_label_parts` принимает Auto flag, enabled-products, интервалы и язык. Таблица 900/1800/3600/14400 → `15м/30м/1ч/4ч` либо `15m/30m/1h/4h`. Разные частоты возвращать двумя именованными частями, Claude первым; одинаковые/одна — одним временем; обе off — текстом отсутствия подписок. `poll_interval()` не использовать: он отвергает 14400.
4. Swift `scanActivity` (4926) уже выставляет `needsDisplay`, observe идёт до render (4983–4990); snapshot обновить раньше. `setInterval` (5254) должен перерисовать и при `last == nil`; subscription toggle уже вызывает update (4812). Linux `on_limits` (1117–1123) делает observe/save/page0_changed, `set_product_enabled` (944) — page0_changed. **Обязательный fix:** `on_activity` (1054–1064) сохраняет новый интервал, но не вызывает repaint; следующий `refresh_limits` может выйти без запроса. Publish должен вызвать `view.update()` сразу. Повторное открытие рисует текущий snapshot, без дополнительного запроса; UI обновляется в GUI-потоке.
5. `autoSummary()` (4913) / `auto_summary()` (1028) сохраняют per-product failed-пояснение. При Auto on и известном updated добавить в конец `clockText` / `fmt.clock` с `обновлено`/`updated`; в футере время тогда не рисовать. При Auto off прежнее место сохраняется. Draw/tooltip не вызывают state-loader/JSON, scan, save, fetch или refresh.

## Геометрия

Один footer helper на платформу для Simple/Advanced: manual X=16…136 (три 40×24), Auto hit 136…176, капсула 141…171 (30×20), label 184…312 (128×24), power hit 320…344. Цвета/радиусы — из design spec. Сохранить `pollSelected`: Auto не выделяет manual-slot.

Simple сейчас заливает все четыре сегмента (Swift 2870 / Python 282): сократить фон до трёх. Advanced использует динамическую ширину (3509 / 667) и расширенный power hit 321…351: заменить сеткой. Updated занимает нужное тексту место и должен условно исчезнуть. Сохранить divider Y: Simple foot+32, Advanced foot+30; credit и высоту окна не двигать.

Измерять `width(attr(...))` / `Attr.width()` при 10 medium: ≤128 — одна строка; >128 при двух именованных частях — две по 12 в той же области. Проверить ширину обеих частей и вертикальные bounds; не обрезать имена. Метрика AppKit не доказывает Qt/Breeze.

## Целевые фикстуры

Расширить Swift `--subscriptions-selftest` (5461) и Linux `test_subscriptions.py`/`test_auto_polling.py`, сохранив изоляцию из `docs/test-plan.md` и урока 006:

- RU/EN × Simple/Advanced/fallback, все 16 пар, Claude-only/Codex-only, обе off: текст и hit bounds.
- Manual=3600 при Auto=900/14400: snapshot не подменяется manual; выключение Auto возвращает ручное выделение.
- Startup restored=14400/900, запрос not-due; missing state=1800; переключение подписок без ответа API.
- Local activity not-due: now=100400, lastAttempt=100000, interval=14400, события 100100/100200/100300 → видимые 900 сразу, repaint вызван, fetch не вызван. Проверить реальный путь публикации.
- Observe/backoff одного продукта → новое число и его failed-tooltip, второй неизменен; updated задан/nil × Auto on/off.
- Joined width=128 и >128, части ≤128; bitmap/Qt-render. Повторный draw не меняет state и не вызывает I/O.

Выполнены чтение кода/документов и этот план. Компиляция, selftest и GUI-прогоны этой ролью не выполнялись. Реальный ALSE-прогон и независимый аудит исторического Auto остаются отдельными открытыми задачами.
