# Статус командного внедрения

Обновлено: 2026-10-03. База для текущей задачи: `main` `e6e2f2e`.

## Факты

- По переданному оркестратором факту macOS 3.2.0 и Linux 0.4.0 уже опубликованы; перед выпуском прошло 205 Linux-тестов и Swift selftest. Это результат предыдущего одиночного исполнения, без независимого ревью Auto. Командные гейты задним числом не закрыты.
- В проекте до этого инкремента уже были `HEARTBEAT.md`, `decisions/log.md`, `.patches/INDEX.md`, README и тесты Auto. На 2026-10-03 заведены `PROJECT.md`, `PRD.md`, `stories.md`, `backlog.md` и этот план/статус как управление будущими шагами.
- Прямой запрос владельца выполнен: стилизованная «А», видимые рядом текущие частоты, без рамки фиксированного слота в Auto.

## Выпущено · 2026-10-03

Релизная ревизия `5b722a17e9683033ae269fc788708a7bcd5feeb7` принята fast-forward
в main и выгружена. Опубликованы [macOS 3.2.1](https://github.com/ArrivaRUS/claude-codex-limits/releases/tag/v3.2.1)
и [Linux 0.4.1](https://github.com/ArrivaRUS/claude-codex-limits/releases/tag/linux-v0.4.1).
Linux не Latest; releases/latest подтверждён как v3.2.1. Оба assets uploaded,
скачаны после публикации и побайтно совпадают с проверенными файлами.

- [CI 37106534056](https://github.com/ArrivaRUS/claude-codex-limits/actions/runs/37106534056): exact SHA, Ubuntu 22.04, `/usr/bin/python3 -m unittest discover -s linux/tests -v` — **212 tests, OK, 0 skip**; DEB build успешен.
- Swift compile и `--subscriptions-selftest` — exit 0, **288 OK**; те же проверки прошёл executable внутри финального read-only mounted DMG. hdiutil checksum VALID, strict codesign PASS, версия 3.2.1.
- Независимые CodeReviewer GPT-6 Astra/high и QA GPT-6.1 Sol/high: PASS после исправления тестовых находок; blocker/major=0. [Полный QA-отчёт](qa-auto-ui.md): 40 macOS + 48 Linux PNG, RU/EN × Simple/Advanced и все предусмотренные состояния.
- DEB: 0.4.1/all/xz; все 15 Python-модулей, entry scripts и assets совпадают с checkout. SHA-256 `fdd77530c796aad7f72a433cc3356ff4bec627bbba53d35b99187027c3e33801`.
- DMG SHA-256 `85d7cdcf0c20151f755f4f9608fdda9a5cba8c192f8efbf5457c67fcdc0f6c8d`.

Живые ALSE/KDE/Fly, hover/click и пользовательские шрифты не проверены.
Forced two-row имеет actual draw/text/bounds CI assertions, отдельного raster нет;
на проверенных macOS/Ubuntu шрифтах длинные подписи помещаются в один ряд.
Swift scanActivity/save/refresh wiring проверен статически; опасные callbacks
не вызывались selftest. Аудит старого Auto и долги синхронизации остаются в backlog.
План закрыт для этого UI-релиза; live ALSE — самостоятельная незакрытая задача.

## История проверок до финальной приёмки

Фаза: M4. Done: требования и бэклог; UX `design/auto-poll-ui.md`; test-plan;
узкий план `auto-ui-implementation.md`, PASS Architect/challenge. Спецификация и
test-plan зафиксированы `f311c4e` до кода. Developer GPT-6.1 Sol/high завершил
UI и версии 3.2.1 / Linux 0.4.1; Swift compile и Python compileall прошли.
Независимый CodeReviewer GPT-6 Astra/high: PASS production-диффа поверх
`f311c4e`, blocker=0, major=0; новой security-поверхности нет. Изолированно
проверены 54 Linux formatter-fixture и startup/local-activity not-due wiring.
Reviewer не запускал Swift/Qt suite и не принимал новые тесты/заметки релиза.
Tester GPT-6.1 Sol/high завершил изолированные проверки: новый Linux test_auto_ui
(7 tests, 6 skip без PyQt5); прежний test_auto_polling (10 tests, 3 skip без Qt).
Первый расширенный Swift selftest дал exit 0, **215 OK**, 16 новых PNG.
Дельта-Reviewer обнаружил major в изоляции теста: прямой doRefresh при скачке
реального времени мог перейти к persistent defaults/fetch. Этот прогон не
закрывает финальный гейт. Tester убирает doRefresh, заменяет чистым due(now),
добавляет PNG single/manual/long; production-дифф остаётся тем же.
M1 закрыт отдельным повторным ревью. После устранения нестабильного сравнения
всей панели тест сравнивает пиксели фактического drawPollFooter отдельно от
текущих отсчётов карточек. Финальный безопасный selftest: exit 0, **288 OK**,
40 PNG; Source SHA-256 `5d277016d5a3d2f590519bbef642f31d40a92bc399dbd214f5e35808f7652910`.
Финальный DMG 3.2.1: build exit 0, hdiutil verify VALID, read-only mount,
codesign --verify --deep --strict exit 0, bundled selftest **288 OK**, plist 3.2.1.
QA macOS просмотрел все 40 Auto PNG RU/EN × Simple/Advanced: PASS. Реальные
hover/click/аккаунты не запускались; ручной экран ALSE остаётся отдельным долгом.
Linux CI [37106329175](https://github.com/ArrivaRUS/claude-codex-limits/actions/runs/37106329175)
на `fe3a3c4`: 212 tests, errors=1 — новый collector ожидал Attr вместо допустимого
list[Attr] при Advanced history. Tester исправил одну строку через Canvas._runs;
production не менялся. Три AST-fixture single/list/tuple прошли, реальный Qt
ожидает повторного CI. In progress: **M5 Linux QA/CI** и упаковка.
M4–M6 ещё не закрыты. Неисполненные Swift callbacks
scanActivity/save/refresh с реальными logs/defaults проверены чтением Reviewer,
не динамическим selftest.

`docs/test-plan.md` и `docs/project-guide.md` созданы отдельными ролями. Guide
синхронизируется с найденным в новых коммитах HQ утверждённым codex-only.
Штатный установщик на Python3.14: 21 роль, 23 файла установлены; повторный
`--check`: 23 файла проверены, 0 установлено. Незакрытые долги — аудит старого
Auto и реальный ALSE-прогон; прежние хвосты синхронизации остаются в бэклоге.

## Область первоначального PM-прохода

Этот PM-проход проверяет только документы и локальный репозиторий чтением. Новые UI-тесты, сборки, QA и живой ALSE-прогон не запускались; релиз текущей правки не производился. По завершении каждой вехи сюда добавляются ревизия, сырой результат команды и следующий незакрытый шаг.
