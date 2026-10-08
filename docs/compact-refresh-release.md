# macOS 3.2.7 — COMPACT-REFRESH

2026-10-08. Изменения macOS 3.2.7; Linux остаётся 0.4.4.
macOS 3.2.7 changes; Linux stays at 0.4.4.
Проверки и статус выпуска / verification and release status: [реестр / acceptance](compact-refresh-verification.md).

## Русский

Нажмите иконку обновления рядом с Настройками (подсказка: **«Обновить сейчас»**); статус и доступные действия занимают до двух строк внутри карточки сервиса.
Подсказка карточки показывает время данных, следующую автопопытку и пояснение; время — без секунд.
Только macOS 3.2.7 добавляет фиксированные **4 часа** к 15/30/60 минутам; Linux 0.4.4 сохраняет три прежних ручных интервала.
В Auto подсвечены **«А»** и фактические интервалы включённых сервисов: при разных частотах — оба сегмента; подсказка показывает соответствие сервисам, отдельной частоты справа от «А» нет.
Строка **«Темп по снимку от…»** удалена; расчёт прогнозов по времени снимка сохраняется.
Правила 3.2.6 сохраняются: независимые результаты, защита на 30 секунд, серверный срок повтора и обычное обновление без окон разрешений; **«Разрешить»** — отдельное разрешение чтения Связки ключей Claude.

## English

Click the refresh icon beside Settings (tooltip: **Refresh now**); status and available actions take at most two lines inside each service's card.
The card's tooltip shows the reading time, next automatic attempt and explanation; times omit seconds.
Only macOS 3.2.7 adds fixed **4 hours** alongside 15/30/60 minutes; Linux 0.4.4 keeps its three existing manual choices.
In Auto, **A** and the enabled services' actual interval segments are highlighted together: different intervals highlight both segments; the tooltip maps them to services, with no separate frequency label to the right of A.
The **Pace from snapshot at…** line is removed; forecasts still use the reading time.
The 3.2.6 rules remain: independent results, the 30-second guard, server retry deadlines and ordinary refresh without permission dialogs; **Allow** is the separate permission action for reading Claude's Keychain entry.

Основание / Sources: [UX](compact-refresh-ux.md), [план / plan](compact-refresh-plan.md).
