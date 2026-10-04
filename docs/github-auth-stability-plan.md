# GH-AUTH-STABLE — авторизация без частых ручных перевходов

2026-10-04. База `297777d7b7386693fd8594a1b86532dab6b621c5`, ветка `codex/stable-github-auth`.

## Уточнённая цель владельца

«Мне не точность формулировки нужна. Пользователю необходимо часто авторизовываться, это плохо. Авторизовался и неделю, месяц или полгода больше не авторизовывался». Затем: «Я закрывал ноутбук. Продолжи».

Основная поставка — устойчивое сохранение и автоматическое продление реальной GitHub-авторизации на macOS и ALSE. Только изменение подсказок не выполняет этот запрос. Прежний UI-only план в `github-auth-ui-fix.md` и его test-plan сохраняются как промежуточный материал, отдельным косметическим релизом не идут. Production ещё не изменялся.

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
- [ ] DeveloperComplex GPT-6 Astra/high получил GO после pre-code commit `7f83dee`: foundation/schema → lifecycle → integration. Owner linux/ccl auth/common/vault/sync/cli/gui, Swift GitHubAuth.swift и GitHub части LimitsMonitor.swift, build.sh. Tester отдельные linux/tests и GitHubAuthSelfTests.swift. API freeze после foundation; review конкретного диффа.
- [ ] Независимые CodeReviewer + security, тесты с fake clock/transport/stores, 30/180 дней моделируемого обновления, sleep/wake и faults.
- [ ] QA пакетов/безопасных fixture UI, документация; main и macOS 3.2.3 / Linux 0.4.3 по сохраняющемуся разрешению на публикацию.

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
