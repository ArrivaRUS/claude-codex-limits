# Статус командного внедрения

## Linux / Astra 0.4.4 · 2026-10-07

На `d607ff9` исходники приложения без изменений: опубликованный DEB 0.4.4 проверен (SHA совпал с GitHub API, 32 файла exact, права/scripts/desktop PASS); исправленный runner прошёл независимое isolation review. Astra 1.8.5 / Python 3.11.2 / PyQt5 5.15.9: bwrap offscreen suite **306 PASS, 0 failures/errors/skips/xfail, exit 0**, 71.276 с, 192 свежих PNG; QA просмотрел 4. Первый ошибочный runner-прогон не засчитан. Установка с 0.3.2 до 0.4.4 через `pkexec dpkg -i` завершилась с кодом 0; dpkg и 38 installed files подтверждены. Штатный GUI PID 249113 жив через 3 с, timer активен; успешный обмен не проверен. Пользователь подтвердил ручной smoke KDE/X11: «Значок есть, панель открывается». Это не автоматический QA; остальные clicks/fonts/KWallet/OAuth/API/sleep-wake не проверены. Live ALSE закрыт частично. [Полный отчёт](alse-0.4.4-verification.md).

## KEYCHAIN-QUIET · 2026-10-07

Production66587e9 и DMG153517fc приняты; v3.2.5 опубликован (Latest) и установлен на этом Mac; публичный DMG SHA совпал, запуск PID72805 подтверждён. [План](keychain-no-background-prompts.md), [итоговые проверки](keychain-quiet-verification.md).


## FRESH-4H / KEYCHAIN-RETRY — приёмка 2026-10-05

Кандидат3.2.4/0.4.4: независимые production/isolation review PASS; CI306/0skip, auth30927/freshness105/revoked130/deadline28 без ошибок. Native QA1401/0,214PNG. Пакет пересобран с minos13.0: independent packaged selftest1401/0,214PNG, integrity/codesign/readonly PASS. [Доказательства](freshness-keychain-verification.md). Выпущено 2026-10-06: [macOS3.2.4](https://github.com/ArrivaRUS/claude-codex-limits/releases/tag/v3.2.4) на4a5c372 и [Linux0.4.4](https://github.com/ArrivaRUS/claude-codex-limits/releases/tag/linux-v0.4.4) наbd16d9c. Публичные DMG/DEB скачаны и SHA совпали; Latest=v3.2.4. На этом Mac установлен3.2.4 в /Applications, подпись и binary SHA проверены, PID29719 запущен. Резервная3.2.3: /private/tmp/ccl-install-backup-_eivvisr/Claude Codex Limits.app.

## AUTOSTART-1 — диагностика 2026-10-05

В текущем снимке Mac работает exact принятая3.2.3: executable SHA/mapped inode и
strictcodesign подтверждены; disk/loaded LaunchAgent canonical. Историческая
версия и причина пока неизвестны. Предыдущая публикация не выполняла установку.
Read-only диагностика, production/system config не менялись;
[план и доказательства](diagnosis-autostart-version.md).

## GH-AUTH-STABLE — выпущено 2026-10-04

Принята исходная ревизия `40cfdf58980acef0668bdb4915c6001322ba9e11` для macOS 3.2.3 / Linux 0.4.3. Независимые CodeReviewer и SecurityAnalyst приняли финальные production/isolation delta: Linux rev5b + cancelled sentinel, Swift C5 и memory-only selftests. Root не менял production.

Фактические проверки: Linux [CI 37192768494](https://github.com/ArrivaRUS/claude-codex-limits/actions/runs/37192768494) — 284 теста OK, 0 skip, DEB build PASS; Swift и executable из DMG — auth 30862/0, sync all passed, subscriptions/Auto 1218 OK. Независимый [QA](qa-github-auth-stability.md) — 374 финальных PNG (182 macOS + 192 Linux), offline DMG/DEB, strict codesign и checksum PASS. Первый sandbox bundled UI запуск exit134 не засчитан; тот же binary с разрешённой Cocoa-средой завершился exit0. Исходники после этих проверок не менялись.

DMG SHA256 `c8f796efaed0343c679d397370050ae6f5d808b5bbc3dd4c8e1eb3ca5452d4d4`; DEB SHA256 `7d1edd28339a029f50ccb2975322293a63733a589e79679e2ceab811aeb14226`. Опубликованы [macOS 3.2.3](https://github.com/ArrivaRUS/claude-codex-limits/releases/tag/v3.2.3) и [Linux/ALSE 0.4.3](https://github.com/ArrivaRUS/claude-codex-limits/releases/tag/linux-v0.4.3). Теги — exact source SHA `40cfdf58980acef0668bdb4915c6001322ba9e11`; main принят fast-forward с QA metadata `b6ca7734786c93547d4eab22bec20b9f0228e7bc`. GitHub API digests совпали с локальными SHA256; оба публичных asset скачаны и побайтно сверены. Latest=v3.2.3; Linux --latest=false. Read-only DMG mount отключён. Live ALSE, native Keychain/KWallet и реальный OAuth/установка не выполнялись. Синтетические 30/180 дней не доказывают полгода календарной работы; серверный отзыв и невозможная потеря единственной обновлённой пары остаются границами.

## История GH-AUTH-STABLE до финальной приёмки

Финальный static source/isolation freeze принят отдельными ревьюерами:
Linux auth48ee/vault96ae/sync63a867 и Swift coredfa533, main3f873ef4,
SelfTestsee6c1db4. Root auth RUN 30862/0; sync all passed. Последний Linux
legacy target 1 PASS после full 284/1FAIL/26SKIP; нужен Ubuntu CI 0 skip.
Swift UI stand-in crash подтверждён отдельным Debugger и исправлен; новый
subscriptions RUN и package/QA/release pending. Предыдущие записи ниже — история.

После возобновления Linux rev4 и Swift C3 (3.2.3/0.4.3) прошли свежие
независимые review: НЕ PASS. Авторы исправляют staged candidate expiry,
reservation-before-writer recovery и initial probe settlement.

Актуальный следующий gate: Linux rev5b production delta принят двумя ревьюерами,
но full RUN 283 tests / 19 failures / 4 errors / 26 skips (sandbox loopback +
oracle/legacy fixtures, разбор отдельного Tester). Swift C4 НЕ PASS: successor
теряет cancellation fence; автор готовит C5, другой Tester исправляет полную
изоляцию старых Swift selftests и добавляет safe auth UI fixtures.
Предыдущий Linux RUN: 52 tests, 48 PASS / 1 fixture FAIL / 3 Qt SKIP;
Swift C3 root auth-selftest: 30767 checks / 0 FAIL. Linux rev4 новый RUN прерван
на deadlock SIGKILL fixture, полный результат неизвестен. Release notes draft
готов (TechWriter), validation/build/release pending. Старые Swift selftests
требуют исправления изоляции до запуска; реальные stores/API не использованы.
Релиз пока не опубликован; прежние PASS не принимают изменённую ревизию.

Владелец исправил scope: нужны редкие ручные входы, а не точность формулировки. PM завершил PRD A1–A12; два Architect независимо исследовали lifecycle и проверили сводный контракт [architecture-github-auth.md](architecture-github-auth.md). Pre-code commit `7f83dee` содержит требования/архитектуру/полный test-plan. Ветка `codex/stable-github-auth`; [главный план](github-auth-stability-plan.md). DeveloperComplex Astra/high реализует foundation → lifecycle → integration; Tester Sol/high отдельно готовит fake infrastructure, Reviewer Astra/high выполняет readonly preflight. Запуск тестов после exact isolation review. Server revoke и потерянный ответ одноразовой ротации без durable candidate остаются честными границами.

## GH-AUTH-UI — архивирован до production 2026-10-04

Продолжение подтверждённых UI/storage ошибок на базе `297777d`. ArchitectPrimary GPT-6 Astra/high выбрал существующий `_SecretServiceAbsent` → explicit SS unreachable без новой операции хранилища, с сохранением legacy discovery; Swift общий заголовок становится нейтральным. Production ещё не менялся; предварительный test-plan Tester готовится. Маршрут: [github-auth-ui-fix.md](github-auth-ui-fix.md). Следующий шаг — зафиксировать контракт/test-plan, DeveloperComplex, независимые проверки и выпуск 3.2.3/0.4.3 по существующему разрешению. Реальная причина случая пользователя и refresh остаются отдельными вопросами.

## GH-AUTH — диагностика 2026-10-04

Read-only исследование на `af4d17d`: Debugger воспроизвёл Linux GUI login-кнопку при недоступном Secret Service; macOS missing Keychain также маркирует revoked без 401. SecurityAnalyst подтвердил возможные 8-hour OAuth tokens и отсутствие refresh в обоих портах. Режим приложения и реальная причина нового случая не проверены. Подробности/источники: [github-auth-diagnosis.md](github-auth-diagnosis.md). Production, аккаунты и token policy не менялись; release-suite не повторялась. В backlog отдельные UI/refresh задачи, реализация не начата. Следующий шаг — платформа/версия и точный видимый текст последней ошибки.

Обновлено: 2026-10-03. База текущей AUTH-1: `main` `5da1143`; старый Auto — `e6e2f2e`.

## Текущая правка AUTH-1

База `5da1143`; предварительный план/контракт зафиксирован `d77e215` до кода.
Пользовательский screenshot показывает Codex + «вход истёк / claude login».
Debugger GPT-6.1 Sol/high подтвердил смешение stale/auth в Swift Advanced;
source Codex не классифицирует AuthState, screenshot не доказывает expiry.
Developer завершил минимальный UI-дифф, Tester подготовил матрицу заранее,
TechWriter обновил инструкции/релизы. Следующий шаг: независимые тесты/ревью,
bitmap QA, пакеты macOS 3.2.2 / Linux 0.4.2. Полный маршрут:
[auth-hints-fix.md](auth-hints-fix.md), [test-plan-auth-hints.md](test-plan-auth-hints.md).
Предыдущие 212/288 проверок не принимаются за проверку этой новой ревизии.

Developer production frozen: Swift compile/Python AST/bash syntax/diff check
exit 0. CodeReviewer GPT-6 Astra/high: static production PASS, blocker/major=0,
новой security-поверхности нет. Source до новых tests
`e9f44b3bad62e3e2db0d9e4cf527916ac07c1428e1baf9161056b6875be99c26`,
panel `0fb8a8442a6d1a42ba2eba2172ccb4aa01a4022a898a13ae7b6c7e031750acaf`.
Tester frozen: только selftest-блок Swift и новый `linux/tests/test_auth_hints.py`.
Локальный Linux target — 7 tests, 3 PASS / 4 Qt SKIP (PyQt5 отсутствует).
Final Source `3fca4e7578c93bd6865a932ad2911d5aad745a607fd61401dae0219e0ad63f19`,
test `83e8ab6aeb3a2cc1915d9c93d92d278c485b3ad8880e021b3aadec6e03793068`.
Production без нового selftest-блока точно совпадает с freeze выше.
Reviewer повторно проверил конечный test-delta: isolation/core coverage PASS,
blocker/major=0, новых callbacks/I/O нет. Проверяет stale Codex + Claude auth
по областям обеих карточек и no-cache/readError. Найденный selftest-state leak
Auto исправлен до запуска. Финальный compile и `--subscriptions-selftest` exit 0: **1063 OK**
(687 новых auth assertions и 88 новых PNG). Linux CI [37133915949](https://github.com/ArrivaRUS/claude-codex-limits/actions/runs/37133915949)
на `a1f885f1138c327121fb7baf794e000edfea5695`: **219 tests OK, 0 skip**, DEB build PASS.
Root проверил финальный DMG: checksum VALID, strict codesign PASS, версия 3.2.2,
packaged selftest **1063 OK**, read-only mount отключён. DEB: 0.4.2/all/xz,
15 Python-модулей, entry scripts и PNG/WAV совпадают с checkout, права PASS.
DMG SHA-256 `81cb356ea762787cb08caca44e8fa1617d383a7d29ef3a606da840c5c121376c`;
DEB `bbadec59e34a0797f87620f8b2cb60f395f57b3eb60748d692f082a7e7f45f19`.
Независимое QA AUTH-1 PASS: 88 macOS + 92 Ubuntu CI PNG, metadata/checksums
пакетов и подпись DMG. [Отчёт](qa-auth-hints.md). Live ALSE/установка/
реальные клики не проверены. Унаследованный P3 Simple readError subtitle
вынесен в Could backlog. AUTH-1 завершён: опубликованы [macOS 3.2.2](https://github.com/ArrivaRUS/claude-codex-limits/releases/tag/v3.2.2)
и [Linux 0.4.2](https://github.com/ArrivaRUS/claude-codex-limits/releases/tag/linux-v0.4.2),
обе версии на exact CI/source SHA `a1f885f1138c327121fb7baf794e000edfea5695`.
`main` fast-forward выгружен с приёмкой `8329312`. Assets uploaded, API digests
совпадают с SHA выше; оба публичных файла скачаны и побайтно сверены.
Latest=v3.2.2; Linux `--latest=false`. Прямое разрешение публикации сохранено,
повторных вопросов не было. 11 делегирований AUTH-1, производящая работа root=0;
native duration_ms недоступен, агент-минуты не выдуманы.

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
