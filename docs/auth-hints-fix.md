# Исправление подсказок входа · 2026-10-03

База: `5da1143`, ветка `codex/fix-auth-hints`. Прямое сообщение пользователя:
карточка Codex говорит «вход истёк» и показывает `claude login`.

Debugger подтвердил: Swift Advanced использует общий paused/stale флаг как
признак истечения входа и безусловно рисует Claude-команду. Codex fetch не
классифицирует ошибки в AuthState; screenshot не доказывает expiry. Linux уже
ограничивает команду Claude, но его no-data и Simple stale copy тоже требуют
нейтрального текста. Реальные токены/серверы для диагноза не использованы.

## Принятый контракт

1. Stale при auth.ok: «данные устарели» / «stale data», без утверждения об
   истечении входа и без login-команды в любом продукте.
2. Подсказка Claude и claudefix остаются только для Claude с его подтверждённым
   auth-проблемным состоянием; исправление не создаёт Codex login flow.
3. При nil asOf — «Нет свежих данных · темп не считаем» / «No fresh data · pace
   paused». Текущее время не подставляется как время данных. Simple stale
   предлагает нейтрально обновить данные, без требования обновить вход.
4. Cached проценты, dimming, pace pause, product selection, URL/hit targets,
   автоопрос, авторизация и сеть сохраняются. Никаких новых CLI-вызовов.
5. Нельзя проверять реальные credentials/logs/keyring/API. Swift — существующая
   безопасная selftest-ветка, pure helper assertions и bitmap; Linux — actual
   draw text/hits с изоляцией. Новую production-инфраструктуру наблюдения текста
   только ради теста не вводить; связь helper→draw проверяет отдельный Reviewer.

## План

- [x] Debugger: причины и границы; Tester: test-plan до кода.
- [x] Developer: минимальный UI-дифф macOS/Linux, версии 3.2.2 / 0.4.2.
- [x] Независимые Tester/Reviewer: fixtures и изоляция, новых I/O нет; фактический прогон остаётся отдельным гейтом.
- [x] Фактический Swift selftest: 1063 OK; Linux CI `a1f885f`: 219 tests OK, 0 skip.
- [x] QA: 88 macOS + 92 Ubuntu CI stale/auth PNG и пакеты, RU/EN; [отчёт](qa-auth-hints.md).
- [ ] Интеграция и выпуск по сохраняющемуся разрешению владельца; Linux не Latest.

Критерии проверки: [test-plan-auth-hints.md](test-plan-auth-hints.md).
Живая ALSE остаётся отдельным долгом; причина реального статуса пользователя
не установлена этим UI-исправлением. Предыдущий Auto-инкремент завершён.
