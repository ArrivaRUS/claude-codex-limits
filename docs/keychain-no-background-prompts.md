# KEYCHAIN-QUIET — фоновый доступ без системных окон

2026-10-07. База afb3233, macOS3.2.4. Пользователь вновь показал запрос security к GitHub Credential V2 и подтвердил, что нажимал «Разрешать всегда». Read-only снимок машины: установлен3.2.4, один canonical process PID1095; старый бинарник не подтверждён. Секреты и Keychain не читались.

## Контракт
- Все фоновые GitHub Keychain операции, включая V2/legacy, startup/wake, refresh, stage, readback и cleanup, не должны открывать диалог разрешения.
- Запрос разрешения допустим только в явном пользовательском действии восстановления/входа; разрешение ограничено этим действием. Отмена/отказ не порождают автоматические интерактивные повторы.
- Недоступность хранилища сохраняет credentials, epoch и отложенную очистку, не трактуется как отсутствие записи или отзыв входа.
- Не расширять ACL до allow-all, не сохранять секреты в файлы/argv/logs, сохранить bounded subprocess и writer-publication fences.
- Понятная RU/EN подсказка и явное восстановление; расписание background retries само не даёт интерактивное разрешение.

## Исполнение
DeveloperComplex реализует в отдельной копии. SecurityAnalyst проверяет границы доступа и изоляцию. CodeReviewer независимо проверяет frozen diff. Pure regressions, macOS13 compile, offline UI и packaged validation; только затем выпуск3.2.5 и локальная установка по ранее выданному разрешению.

Тесты не обращаются к реальным credentials/API/Keychain/userlogs. Сама причина первого nativeprompt/конкретный ACL не установлены; факт «Always Allow не устранило повторы» принадлежит пользователю. Проверку живых ACL нельзя выдавать за выполненную по мокам.

## Статус
Production66587e9 и пакет153517fc приняты независимыми CodeReviewer/SecurityAnalyst/Tester/QA. Публикация/установка ещё не выполнены. Итоговые доказательства: [verification](keychain-quiet-verification.md).

## Read-only снимок после уточнения

Служебный manifest: signedOut=false, active присутствует, transition refresh/requestStarted, cleanupRefs=1, uncertainRefs=0, failureReason отсутствует. Это состояние на момент чтения, а не доказательство виновной записи; содержимое токенов/Keychain не читалось.

## Security design, независимый проход

Baseline T2: cooldown недостаточен после успешного Allow и перезапуска. Native no-UI должен задаваться внутри каждого helper и прекращать I/O при ошибке установки политики; parent-process настройка и один kSecUseAuthenticationUIFail недостаточны для file-based Keychain.
Новая identity helper может потребовать ручного подтверждения для существующей записи. Нельзя автоматически расширять существующий ACL; новые records требуют явного ограниченного trusted list. Legacy delete обязан выбирать один item/reference; service-only SecItemDelete может удалить все совпадения. Interaction-required — temporary/locked, не missing; сохранить requestStarted recovery и публикационные fences.
Источники: [Apple ACL](https://developer.apple.com/documentation/security/access-control-lists), [TN2206](https://developer.apple.com/library/archive/technotes/tn2206/_index.html), [Chromium file-based no-UI implementation](https://chromium.googlesource.com/chromium/src/crypto/+/refs/heads/main/apple/scoped_keychain_user_interaction_allowed.cc), SDK SecKeychain.h634.
Независимый [тест-план](test-plan-keychain-quiet.md) готов. Production diff и runtime isolation ещё не приняты.

## Review snapshot1

Frozen copy /private/tmp/ccl-quiet-review1-8f2gyw1t: core4192a387, main e2eb3bd8. CodeReviewer нашёл два P2: manual login permit переживает отмену, а kill после probe rpcStarted теряет путь к settlement. Исправления переданы DeveloperComplex; snapshot1 не принят. Требуются отменяемый permit и безопасное восстановление неопределённого probe без признания kill доказательством settlement. Изоляция/пакетная проверка финальной версии ещё впереди.

Security snapshot1 независимо подтвердил cancel-permit P2 и необходимость проверки login ID до device-code POST/очистки UI. Остальные проверенные границы: quiet helpers без CLI fallback, новые ACL security+self без allow-all, legacy one-reference delete, unavailable≠missing, requestStarted сохраняется. Baseline pure-suite и subscriptions-selftest разрешены только для snapshot1; новые tests/delta требуют отдельной проверки. Нативные Keychain/ACL/popup сценарии без disposable среды не запускались.

## Итог приёмки

Snapshot3 core58d68bea/mainc21f6d06/testsabca65a7: Code+SecurityPASS. Pure31039/0 повторён координатором; независимаяfixture30/0 с воспроизведением двухошибок наsnapshot1. Packaged QA1401/0+214PNG,6Settingsframes,signature/integrity/minos13PASS. Нетживого nativeACL/popupпрогона; ограничение сохранено в verification.
