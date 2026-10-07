# KEYCHAIN-QUIET — проверка macOS3.2.5

2026-10-07. Baselineafb32339226f20c73dbecb0e48a03383a071eb93.
Production commit66587e91ac96790044f537c0be8601e7bf7dec5b; независимая fixture добавленаf3175af. Linux не менялся, версия0.4.4.

## Принятый source

- GitHubAuth.swift:58d68bea163228099e858d894bff00387a41f0770d61b9b68f7230835e407097
- LimitsMonitor.swift:c21f6d0673a8812c8f65c4b6f076e717cdcde49b78201bcd0ebfd86a285cf7cd
- GitHubAuthSelfTests.swift:abca65a758d6fabe3e454f9adf2da29eb4820b49d0deb353017e9b10be1e8bd6
- fixtures/keychain-quiet/main.swift:f6c0dfc963a03613abc87326bbe364656e7a7ed5bafb13649af2115b6c4087dd

Frozen snapshot3:/private/tmp/ccl-quiet-review3-gyjtha2b. CodeReviewer и SecurityAnalyst независимо приняли production/isolation. Интерактивный permit связан с неизменяемым login ID/action; отмена синхронизирована с допуском helper. Неопределённый prepared probe заменяется без повторной публикации токена; old ref остаётся uncertain/cleanup. Snapshot1/2 были отклонены из-за cancel/action binding и stuckprobe; их пакеты не выпускались.

## Выполненные проверки

- Авторский standalone auth-suite повторён координатором наfinal source:31039 checks/0fail, только synthetic dependencies. Без KEYCHAIN_SYNC_REGRESSION и без native adapters.
- Независимая Tester fixture: snapshot1 21PASS/2FAIL; snapshot2/3 30PASS/0FAIL. Cancel и unknown-probe:FAIL→PASS. Fixture сохранена без изменений в fixtures/keychain-quiet-independent/main.swift, SHAedf7a23f9efe02d3c334ca522776443a00b1e5ce443a46bd0a5f5a73ca3bd812. Её изоляция и содержательность отдельно приняты CodeReviewer.
- Проверены pure fail-closed configuration/noRPC, background/manual budget, GC, timeout/fence, restart600s, epoch/publication и synthetic metadata secret checks. Q1–Q9 partialpure; actual runLogin binding принят статически, не выдаётся за runtime race test.
- Полная release-сборка: arm64, explicit macOS13 target, ad-hoc codesign PASS. Staged secrets-check чисто.
- Финальный DMG SHA153517fccdcbcedf10d4c48a072bfaf588ed416a4ef3ef33ca67aae0e824e11c. QA packaged selftest завершён:1401 checks/0fail,214PNG; независимый QA PASS: integrity/read-only/strictcodesign, версия3.2.5/minos13.0,17/17 mounted files matchdist;6SettingsRUEN PNG просмотрены, retry виден полностью. PackagedbinarySHA0543c357eaf6190aacfab1625486e99094b6728d288b2984f92f90558b1a3bb7.

## Границы

Новые Keychain ACL ограничены security+selfhelper, старые ACL не переписываются. Перед nativeRPC helper задаёт запрет UI и прекращает операцию при ошибке настройки. Один explicituseraction может допустить ограниченную интерактивную операцию.
Реальные Keychain/ACL, nativepopup, живые backendAPI, пользовательские credentials/logs и macOS13 runtime в тестах не использовались. DisposableVM нет; sourcepolicy/fakes/compile не выдаются за такую проверку. Подпись ad-hoc, нотаризация не добавлена. Ручное разрешение старой записи может понадобиться из-за смены helper identity.

## Выпуск

Публикация и локальная установка пока не выполнены. Артефакты QA:/private/tmp/ccl-quiet-qa-vd6lmbnc. Тестовые артефакты:/private/tmp/ccl-independent-quiet-v46ha3no/snapshot3 и /private/tmp/ccl-quiet-tests/auth-final.log.
