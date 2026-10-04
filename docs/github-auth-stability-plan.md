# GH-AUTH-STABLE — авторизация без частых ручных перевходов

2026-10-04. База `297777d7b7386693fd8594a1b86532dab6b621c5`, ветка `codex/stable-github-auth`.

## Уточнённая цель владельца

«Мне не точность формулировки нужна. Пользователю необходимо часто авторизовываться, это плохо. Авторизовался и неделю, месяц или полгода больше не авторизовывался». Затем: «Я закрывал ноутбук. Продолжи».

Основная поставка — устойчивое сохранение и автоматическое продление реальной GitHub-авторизации на macOS и ALSE. Только изменение подсказок не выполняет этот запрос. Прежний UI-only план в `github-auth-ui-fix.md` и его test-plan сохраняются как промежуточный материал, отдельным косметическим релизом не идут. Исходная ревизия `40cfdf58980acef0668bdb4915c6001322ba9e11` принята по независимым review, runtime, QA и упаковке; обе версии опубликованы, публичные assets проверены.

## Рабочие инварианты

- Один пользовательский вход; при здоровом GitHub и хранилище обычные обновления access token происходят автоматически, без браузера/device code и запросов человеку.
- Если ответ GitHub содержит refresh/expiry, они сохраняются в защищённом локальном хранилище вместе с access token и используются для обновления. Старые long-lived токены поддерживаются без обязательного перевхода.
- Сон/закрытие ноутбука, отсутствие сети и временно недоступный Secret Service/Keychain не стирают авторизацию и не запускают новый вход. После восстановления продолжается работа.
- Ротация одноразового refresh токена сериализована и защищена от гонок CLI/GUI и прерываний. Новая пара публикуется только после надёжного сохранения; старые операции не удаляют новую generation.
- Credentials никогда не попадают в defaults/settings, gist, логи, аргументы процессов или пользовательские диагностические выгрузки.
- Local-only logout, выбранный владельцем, сохраняется. Настоящий отзыв GitHub или истёкший refresh требуют честного восстановления; без поддержки issuer невозможно обещать восстановление одноразового refresh после потерянного ответа ротации.

## Командный маршрут

- [x] ProductManager: `prd-github-auth-stability.md`, A1–A12 и границы обещания.
- [x] Два независимых Architect: первичные планы до взаимного чтения; сведение root, challenge и принятый `architecture-github-auth.md`.
- [x] Tester: полный `test-plan-github-auth-stability.md` до кода, SHA256 `2d72dffd325a2e26c4de909e579bb17fe39182c1ead5a0c9a292fc9fc31d4e4e`; изоляция уроков 006/011. Numeric contract: lead=min(900s,TTL/4), persisted unknown recovery budget=1.
- [x] Два DeveloperComplex GPT-6 Astra/high завершили source: Linux rev5b + cancelled sentinel, Swift C5. Области production не пересекаются; два Tester отдельно core/new integration/Swift и legacy fixtures. Foundation/schema → lifecycle → integration реализованы после pre-code `7f83dee`; static review/security принято, runtime/package acceptance ниже.
- [x] Независимые CodeReviewer + security, тесты с fake clock/transport/stores, 30/180 дней моделируемого обновления, sleep/wake и faults.
- [x] QA пакетов/безопасных fixture UI и документация: 374 PNG, DMG/DEB PASS.
- [x] Main и публикация macOS 3.2.3 / Linux 0.4.3; публичные assets скачаны и побайтно сверены.

## Финальная приёмка

Принята исходная ревизия `40cfdf58980acef0668bdb4915c6001322ba9e11` для macOS 3.2.3 / Linux 0.4.3. Независимые CodeReviewer и SecurityAnalyst приняли финальные production/isolation delta: Linux rev5b + cancelled sentinel, Swift C5 и memory-only selftests. Root не менял production.

Фактические проверки: Linux [CI 37192768494](https://github.com/ArrivaRUS/claude-codex-limits/actions/runs/37192768494) — 284 теста OK, 0 skip, DEB build PASS; Swift и executable из DMG — auth 30862/0, sync all passed, subscriptions/Auto 1218 OK. Независимый [QA](qa-github-auth-stability.md) — 374 финальных PNG (182 macOS + 192 Linux), offline DMG/DEB, strict codesign и checksum PASS. Первый sandbox bundled UI запуск exit134 не засчитан; тот же binary с разрешённой Cocoa-средой завершился exit0. Исходники после этих проверок не менялись.

DMG SHA256 `c8f796efaed0343c679d397370050ae6f5d808b5bbc3dd4c8e1eb3ca5452d4d4`; DEB SHA256 `7d1edd28339a029f50ccb2975322293a63733a589e79679e2ceab811aeb14226`. Опубликованы [macOS 3.2.3](https://github.com/ArrivaRUS/claude-codex-limits/releases/tag/v3.2.3) и [Linux/ALSE 0.4.3](https://github.com/ArrivaRUS/claude-codex-limits/releases/tag/linux-v0.4.3). Теги — exact source SHA `40cfdf58980acef0668bdb4915c6001322ba9e11`; main принят fast-forward с QA metadata `b6ca7734786c93547d4eab22bec20b9f0228e7bc`. GitHub API digests совпали с локальными SHA256; оба публичных asset скачаны и побайтно сверены. Latest=v3.2.3; Linux --latest=false. Read-only DMG mount отключён. Live ALSE, native Keychain/KWallet и реальный OAuth/установка не выполнялись. Синтетические 30/180 дней не доказывают полгода календарной работы; серверный отзыв и невозможная потеря единственной обновлённой пары остаются границами.

## История возобновления до финальной приёмки

Свежие CodeReviewer/SecurityAnalyst проверили frozen Linux rev4/Swift C3:
НЕ PASS. Исправляются expired staged candidate с действующим refresh на обоих
портах, reservation-before-writer recovery, Swift initial probe settlement.
Swift C3 auth-selftest фактически 30767/0; Linux RUN прерван из-за deadlock
SIGKILL fixture, остаток не проверен. Обычные Swift sync/subscriptions selftests
до исправления изоляции запрещены; loopback fake API в Linux разрешён.
TechWriter завершил документационный draft с pending validation/release.
Далее Tester regression/isolation fixes → readonly review exact delta → RUN/CI
с PyQt 0 skip → независимый QA пакетов/UI → публикация обеих версий.

Платформа/версия старого случая полезны для его диагноза, но не блокируют универсальную реализацию. Реальные токены, настройки OAuth App, keyring и журналы пользователя не читаются. Проверки состояния issuer выполняются только на fake transport. Живую ALSE-проверку по Ubuntu CI не заявлять.

PM выполняется последовательным поручением известному GPT-6.1 Sol/high после завершения Tester-поручения: отдельный новый agent thread недоступен из-за лимита runtime. Одна роль на активное поручение, специалисты не запускают агентов. Root ведёт память/интеграцию.

Независимый Reviewer Astra/high проверил preflight документов на `7f83dee`
плюс architecture SHA256 `d546c1ccdee9a0525fa4d8390d972e03ea6aefcaf74b07ac79604289ac32fad5`:
новых контрактных blockers не найдено. Это не production/test-isolation PASS.
После освобождения завершённых заданий новые native agent threads доступны:
DeveloperComplex и Reviewer созданы отдельно; снижения модели/gates нет.

Ownership разделён после подтверждения первого автора, что Swift ещё не писался:
Linux DeveloperComplex `github_auth_developer_complex`; Swift DeveloperComplex
`github_auth_swift_developer` (оба Astra/high). Области не пересекаются. Tester
Sol/high пишет stdlib-only fake infrastructure отдельно. Второй автор читает
общий контракт; паритет не доказывается слепым копированием первого draft.
