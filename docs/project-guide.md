# Рабочий гайд проекта

Текущая задача GH-AUTH-STABLE (2026-10-04): реальная длительная авторизация
GitHub на macOS/ALSE без регулярного ручного входа. Ветка `codex/stable-github-auth`,
предварительная фиксация требований `7f83dee`. Прочитать [главный план](github-auth-stability-plan.md),
[PRD](prd-github-auth-stability.md), [архитектуру](architecture-github-auth.md) и
[полный тест-план](test-plan-github-auth-stability.md). UI-only материалы архивированы.
Следующий шаг — DeveloperComplex, независимые review/security/tests/QA и
публикация 3.2.3/0.4.3 по сохранённому разрешению. Реальные credentials и API
не использовать в проверках. Новый V2 namespace не поддерживает полный downgrade:
возврат к старому binary не должен восстанавливать уже ротированную старую пару.

Текущий вопрос GH-AUTH (2026-10-04) — повторная авторизация GitHub: [диагностика](github-auth-diagnosis.md). Для различения причин нужны платформа/версия и видимая последняя ошибка в Настройках, без токенов и полного экспорта данных. Надпись «отозван» не доказывает серверный revoke. Причина конкретного случая пока не установлена; token policy не менялась. AUTH-1 ниже уже выпущен.

Текущая задача AUTH-1 — честные подсказки устаревших данных и входа в macOS 3.2.2 / Linux 0.4.2. Контракт и план: [auth-hints-fix.md](auth-hints-fix.md); сценарии и безопасные команды: [test-plan-auth-hints.md](test-plan-auth-hints.md). Готовность проверок и факт выпуска смотреть в [status.md](status.md) и [HEARTBEAT.md](../HEARTBEAT.md): этот гайд не закрывает релизные гейты. Предыдущий Auto UI выпущен в 3.2.1/0.4.1; его [план](plans.md), [спецификация](../design/auto-poll-ui.md) и [QA-отчёт](qa-auto-ui.md) сохраняются как архив.

## Вход следующей сессии

Если Юрка подключена к пространству вместе с проектом, автоматически действует codex-only. Прочитать [AGENTS HQ](../../2026.06%20Юрка/AGENTS.md), [режим](../../2026.06%20Юрка/handoff/references/codex-only.md), [AGENTS проекта](../AGENTS.md), [инструкцию команды](codex-team.md), [HQ/now](../../2026.06%20Юрка/HQ/now.md), актуальные HEARTBEAT/status, [решения](../decisions/log.md) и [уроки](../.patches/INDEX.md). Установить `PROJECT_ROOT=/Users/arrivarus/Documents/VibeCoding2/2026_06_UsageLimits`, сверить checkout, ветку и незавершённые изменения.

Координатор ведёт память и интеграцию; существенная реализация и независимые проверки выполняются отдельными специалистами по [.codex/agents](../.codex/agents/). Одному исполнителю — одна роль и узкая область записи. Специалисты не запускают подагентов и не делают Git-мутаций. Модель/effort брать из профиля; модель основной сессии выбирается в клиенте. Claude и другие движки не запускать; mixed-файлы не являются инструкциями этого режима.

## Маршрут AUTH-1

1. Сверить текущий шаг с [контрактом](auth-hints-fix.md), статусом и [backlog](../backlog.md). Stale/ошибка сети сами по себе не доказывают auth expiry. Codex fetch не классифицирует AuthState; задача не устанавливает причину реального статуса пользователя и не создаёт Codex login flow.
2. Developer → независимые Tester/CodeReviewer → визуальный QA macOS/Linux × RU/EN × Simple/Advanced. Фикс сохраняет cache, pause темпа и targets; Claude recovery — только Claude loggedOut/expired; nil `asOf` не заменять текущим временем.
3. Перед тестами прочитать [урок 006](../.patches/006-tests-touch-real-keyring.md) и тест-план. Не читать реальные credentials/logs/keyring, не обращаться к API/gist. Linux: `_isolate` до `ccl` и запрещающие моки; Swift: проверенная безопасная ветка `--subscriptions-selftest`, volatile defaults, временные фикстуры и ранний exit. Обычное приложение/unsafe previews не запускать.
4. Записать ревизию/дифф, команды, exit codes, run/skip и PNG в статус. Пропуск GUI или отсутствие окружения не означает PASS. Исторические проверки Auto не доказывают AUTH-1. [Linux CI](../.github/workflows/linux.yml) на Ubuntu 22.04 — отдельный маршрут тестов и упаковки; живые ALSE/KDE/Fly и actual click остаются непроверенными до фактического прогона.
5. После независимой приёмки сверить версии, README и [macOS notes](releases/macos-3.2.2.md)/[Linux notes](releases/linux-0.4.2.md), собрать и опубликовать по сохраняющемуся разрешению владельца. Новый скоуп или блокер требуют отдельного решения.

## Сборка, публикация и откат

macOS: `bash build.sh`, затем `./scripts/make-dmg.sh`; сверить версию `.app`, strict codesign и DMG. Linux: `sh linux/packaging/build-deb.sh` требует `dpkg-deb`. Если его нет на Mac, использовать DEB из успешного Ubuntu CI на точной принятой ревизии: проверить `headSha`, полный лог, имя, версию, архитектуру и SHA-256 скачанного `linux-deb`. Это отдельная проверка пакета, не живой ALSE smoke.

Linux-публикация требует релиза `linux-v0.4.2` с `claude-codex-limits_0.4.2_all.deb` и `--latest=false`; merge в `main` не обновляет пакетные установки. `sh linux/packaging/release.sh [notes-file]` предназначен для проверенного main и машины с `dpkg-deb`; на Mac разрешён `gh release create` с проверенным CI-пакетом и точным SHA. Latest должен оставаться macOS `v3.2.2` с `ClaudeCodexLimits-3.2.2.dmg`, поскольку Mac updater и `get.sh` используют `releases/latest`. Перед выпуском сверить отсутствие существующего тега/релиза; после — публичные assets, checksums и безопасный smoke. Невыполненные проверки не записывать как выполненные.

Откат: предыдущие выпущенные macOS `v3.2.1` (`ClaudeCodexLimits-3.2.1.dmg`) и Linux `linux-v0.4.1` (`claude-codex-limits_0.4.1_all.deb`). На Mac закрыть приложение и заменить `.app` копией из прежнего DMG; на Linux установить прежний пакет через `sudo apt install --allow-downgrades ./claude-codex-limits_0.4.1_all.deb`, проверив предложенные apt изменения. Сохранить настройки и пользовательские данные. При провале smoke остановить распространение, восстановить прежний пакет на затронутой машине и записать проверку/решение в статус и журнал. Сам этот маршрут не означает выполненной переустановки.
