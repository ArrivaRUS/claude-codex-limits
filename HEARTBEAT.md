# HEARTBEAT — claude-codex-limits

> Живой статус проекта. Читается на старте каждой сессии Юрки. Обновлён: 2026-09-30.

## Где мы
- **Версии:** macOS 3.1.2 · Linux 0.3.1 (`main` = b146339).
- **Фаза:** баг-фикс синхронизации через гист (ветка `fix/sync-401-silent-revoke`), поток B «runtime» из `error-handling.md`.
- **Риск-теги:** security-поверхность (токен GitHub, Связка ключей, Secret Service) · данные (гист) → developer-codex на Astra @high, ИБ-ревью диффа (T2).
- ⚠️ Codex-лимит с 2026-09-30 (Sol и Astra): developer → Claude `developer` (Opus @high); Codex-проход ревью пропущен; ИБ-мнение Astra недоступно → второй взгляд Opus, пометка.
- ⚠️ Fable-лимит с 2026-09-27: сессия Юрки на Opus 5.5 @high; Fable-агентов запускать с `model: "opus"`, если Fable недоступен.

## Инцидент 2026-09-29 (диагноз debugger)
- Обе машины с 28.09 не синхронизируют гист `44dade32…`: MacBook молчит с 05:59Z, ThinkPad (Astra Linux, 0.3.1) с 13:32Z.
- Причина №1: один ответ 401 от GitHub → `revoked()` удаляет токен и молча останавливает синк (Мак `LimitsMonitor.swift:1293`; Linux `sync._handle`). Предупреждение только в Настройках.
- Причина №2 (Мак): чтение гиста привязано к изменению локального индекса (`syncNow()` только из `scanAsync` при `changed`, `:677`, `:4181`).
- Почему GitHub дал 401 — не подтверждено: вероятнее лимит 10 токенов на пользователя/приложение/scope после серии перевходов на Linux 27–28.09; проверить Authorized OAuth Apps и почту. Если secret scanning — триггер T4.

## Статус фикса (2026-09-30, перед компактификацией)
- Готово: `d566b56` память проекта; `73ef1a3` macOS 3.1.3 (Claude `developer`; частичная правка Astra оборвалась на 403 и не компилировалась, довёл Claude; копия её диффа в scratchpad сессии); `3ca05f2` linux 0.3.2 (Claude `developer`, 34 теста ок, 4 пропуска: нет PyQt5 и dpkg).
- Идут: `code-reviewer` и `security-analyst` (T2, «ИБ без GPT-мнения») по macOS `73ef1a3`.
- Следующее:
  1. те же два ревью по Linux `3ca05f2`;
  2. правки по находкам ревью (не больше 3 циклов);
  3. `tester` — регресс-тесты обеих платформ по сценариям debugger: 10 циклов без изменений дают GET каждый раз и один PATCH; 401 и /user 200 — токен цел; 401 и /user 401 — отзыв; старый токен не удаляет новый; таймаут и зависание транспорта; stale больше 30 мин. Точки подмены: Мак — `GitHubSync.init(transport:keychain:defaults:remotePath:machineId:)`, `OfflineSyncKeychain`, `OFFLINE_SYNC_HTTP`; Linux — `sync.transport`, `vault._ss`, `vault.TIMEOUT`, `sync.warning()`. Урок 006 обязателен;
  4. Юрка ставит 3.1.3 на MacBook и проверяет оранжевую строку и Настройки. Режимы `--advanced-preview` и `--settings-preview` для скриншотов НЕЛЬЗЯ: пишут в настоящие defaults;
  5. заметки релиза 3.1.3: в коде «Что нового» нет, текст идёт в GitHub-релиз;
  6. «да» человека на push и merge. Linux 0.2+ сам обновляется из `main`, поэтому merge — это выкладка.
- Открытое решение: строка предупреждения на обеих платформах только в расширенном виде (Advanced), в простом виде её нет. Вынести человеку, если нужно иначе.
- Человеку: Authorized OAuth Apps на GitHub и почта за 28–29.09 (если secret scanning — T4); `ccl-sync status` с ThinkPad; перевойти на обеих машинах.

## План фикса
1. Мак: читать гист на каждом тике; 401 → проверка `GET /user`, отзыв только при повторном 401, удалять токен только если он тот же; видимость «последняя отправка/чтение» + предупреждение на основном экране при простое > 30 мин или отзыве; таймаут на `/usr/bin/security`. Версия 3.1.3.
2. Linux: те же 401 и видимость. Версия 0.3.2.
3. `docs/sync-protocol.md`: раздел Errors и чтение каждый цикл — контракт обеих сторон.
4. Регресс-тесты (Tester) без касания настоящих Связки ключей, Secret Service и гиста — урок 006.
5. CodeReviewer ∥ Codex-проход (Sol) → T2 SecurityAnalyst → Юрка ставит сборку на MacBook и проверяет → ⛔ «да» на merge/push (Linux обновляется из `main` сам).

## Человеку (ждём)
- Проверить github.com/settings/applications и почту за 28–29.09; на ThinkPad `ccl-sync status`; перевойти на обеих машинах.

## Счётчики сессии 2026-09-29
- delegations: 6 (debugger · developer-codex Astra, оборвался на 403 · developer Opus на macOS и Linux · code-reviewer · security-analyst) · yurka_direct_actions: 0
