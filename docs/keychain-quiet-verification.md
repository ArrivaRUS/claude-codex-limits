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

Опубликован [macOS 3.2.5](https://github.com/ArrivaRUS/claude-codex-limits/releases/tag/v3.2.5), Latest=v3.2.5; release tag на782087fa8d5eb753e04cf2c541c15a31ccee5c30 (production66587e9). Публичный DMG повторно скачан в /private/tmp/ccl-public-3.2.5; SHA256153517fccdcbcedf10d4c48a072bfaf588ed416a4ef3ef33ca67aae0e824e11c совпал с принятым пакетом.

Установлен /Applications/Claude Codex Limits.app; версия3.2.5, strict codesign PASS, binary SHA0543c357eaf6190aacfab1625486e99094b6728d288b2984f92f90558b1a3bb7 совпал. После обычного запуска подтверждён процесс PID72805. Receipt:/private/tmp/ccl-install-3.2.5-receipt.json; предыдущая копия для отката:/private/tmp/ccl-install-backup-wvz71myo/Claude Codex Limits.app. Проверка запуска не доказывает отсутствие native окон на всех фоновых путях и не меняет указанные выше границы тестирования.

 Артефакты QA:/private/tmp/ccl-quiet-qa-vd6lmbnc. Тестовые артефакты:/private/tmp/ccl-independent-quiet-v46ha3no/snapshot3 и /private/tmp/ccl-quiet-tests/auth-final.log.

## Повторное сообщение после выпуска · 2026-10-07

Пользователь прислал ещё один скриншот запроса `security` к GitHub Credential V2. Файл `codex-clipboard-bc22010f-e230-40b9-8bb4-2c3cc3f5c2a6.png` имеет birthtime/mtime 22:04:33 +03:00, а receipt установки 3.2.5 и начало процесса PID72805 — 22:35:18 +03:00. Файл существовал до установки: этот скриншот сам по себе не доказывает повтор на 3.2.5. Пользователю задан вопрос о самостоятельном появлении окна или ручном повторе; ответ пока не получен.

При диагностике около 22:40 проверены только метаданные файла/установки, имена и PID/PPID процессов и hash установленного executable. Работает canonical3.2.5 с принятым SHA0543c357; процесса `security` в снимке списка процессов нет. Отсутствие процесса в одном снимке не доказывает отсутствие кратковременных запросов. Реальные ключи, ACL и пароли не читались; системные разрешения не изменялись. Нужна временная привязка следующего события к версии и ручному действию; новый дефект не объявлен подтверждённым по старому скриншоту.

Независимые Debugger (Sol/high) и SecurityAnalyst (Astra/high) прочитали production66587e9/HEAD5493076: GitHub CLI fallback не найден; в3.2.4 GitHub использовал security, в3.2.5 — собственный helper. Оставшиеся вызовы security относятся к Claude Code-credentials. Quiet helper прекращает RPC при ошибке запрета UI; ручной допуск идёт через тот же executable. Старый orphan остаётся гипотезой, не подтверждён. Нового дефекта в проверенной области не найдено. Нативное имя инициатора и реальные ACL не проверены; proposed isolated VM сценарий не выполнялся. Код приложения не изменён.
