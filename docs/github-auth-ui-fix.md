# GH-AUTH-UI — честные состояния входа GitHub

> Промежуточный UI-only план, production не начат. Владелец уточнил: цель — реальная авторизация неделями/месяцами без ручного перевхода. Главный план: [github-auth-stability-plan.md](github-auth-stability-plan.md); самостоятельного косметического выпуска не будет.

2026-10-04. Продолжение вопроса о повторном входе после «Ты продолжаешь работать?». База `297777d7b7386693fd8594a1b86532dab6b621c5`; доказательства в [github-auth-diagnosis.md](github-auth-diagnosis.md). Причина конкретного случая пользователя ещё не установлена; подтверждённые ошибки интерфейса исправляем независимо от этого уточнения.

## Требования

- Linux: при известном Secret Service backend и отсутствии сервиса по `_ss() is None` показывать временную недоступность хранилища, не предлагать ненужный device flow. Реально отсутствующая запись остаётся самостоятельным состоянием; восстановление сервиса возвращает обычный интерфейс.
- macOS: missing Keychain без серверной проверки не называть подтверждённым отзывом GitHub. Подтверждённый отказ после трёх 401 объяснять честно; RU/EN, настройки и основной статус согласованы.
- Сохраняются тройное подтверждение 401, адресное удаление старой копии, local-only logout, generations, таймеры и формат данных. Никаких новых миграций/fallback, автоматического входа или чтения токенов тестами.
- Refresh истекающих OAuth tokens в эту правку не включён: режим реального OAuth App неизвестен. Исправление не обещает восстановить реально отозванный токен.

## План и области ролей

- [x] ArchitectPrimary: точный vault read-result и нейтральный Swift заголовок; новых I/O нет. Tester: test-plan до кода готовится.
- [ ] DeveloperComplex: согласованная минимальная реализация, macOS 3.2.3 / Linux 0.4.3.
- [ ] Независимые tests/isolation review + CodeReviewer/security на exact freeze.
- [ ] Безопасные RU/EN fixtures, полный Ubuntu CI и пакеты, независимый QA.
- [ ] Технические инструкции и заметки выпуска; main и релизы по сохраняющемуся разрешению, Linux не Latest.

Координатор ведёт эту память и интеграцию; source/test writers работают последовательно. Специалисты не запускают агентов и не меняют Git. Реальные credentials/keyring/defaults/журналы и auth API не используются. Уроки 006/011 обязательны. Живой ALSE, настройки OAuth App и причина реального выхода остаются отдельными непроверенными обстоятельствами.

## Принятый минимальный контракт

ArchitectPrimary GPT-6 Astra/high, readonly: в Linux `_ss_read` при `_ss() is None` бросает существующий `_SecretServiceAbsent`; `_read` ловит его перед общим Exception и для explicit secret-service возвращает `(None, "unreachable")`. Legacy discovery продолжает прежний file discovery; существующий SS без записи остаётся genuine missing. Locked/timeout, file backend, tombstone, pending cleanup, поколения не меняются. Публичная форма read сохраняется. GUI/CLI уже поддерживают unreachable; дополнительный reachable/keyring вызов в GUI не добавлять, прежний guard в sync не удалять.

Swift: общий заголовок `.revoked` — «Требуется вход в GitHub» / «GitHub sign-in required». Внутренний enum и переходы сохраняются, подробный lastError продолжает различать Keychain missing и подтверждённые 401. Не добавлять новые auth поля/defaults или наблюдатели текста ради тестов.

Запись DeveloperComplex: production-часть `Sources/LimitsMonitor.swift`, `linux/ccl/vault.py`, `linux/ccl/__init__.py`, `build.sh`, `scripts/make-dmg.sh`; source selftest-блоки пока не трогать. Tester после freeze получает только два существующих Swift selftest-блока и новый Linux test-файл. Legacy absent с файлом/без него, восстановление сервиса и отсутствие записи/удаления обязательно проверяются отдельно.
