# C5 / D4 — GitHub после пересборки, 2026-10-31

Текущий контракт после принятых владельцем S1–S5 независимого security-review
fix9 (`16f7aab..48ac3ad -- Sources`). Предыдущая реализация44→missing и прямой
фоновой команды без preflight признана неверной. Новые проверки RED до Mac.
Fix8 (редактор/C5-12) в этом проходе не менялся.

## ACL и чтение

V2 writer по-прежнему создаёт service `Claude Codex Limits GitHub Credential V2`,
account UUID поколения, SecAccessCreate с `/usr/bin/security` и текущим helper,
kSecAttrAccess при SecItemAdd. Add-only не расширяет ACL старого пункта.
Legacy writer явного ACL не задаёт и сохраняет прежний native read.
Фактические ACL Mac владельца из этой сессии не считывались.

S1: SecurityTool может потерять ошибку поиска и вернуть44 при существующем
пункте. Raw44 теперь .failure(44), не .missing. После него выполняется native
helper `attributes quiet`: exact service/account, kSecReturnAttributes,
kSecUseAuthenticationUIFail, без kSecReturnData. Только errSecItemNotFound
этого запроса подтверждает отсутствие. Success→locked (пункт существует,
но tool не прочитал), прочие ошибки→locked/unreachable/timeout. Owner остаётся
временно недоступным, а не требует нового входа из-за одного tool44.

S2: background перед tool выполняет `preflight quiet`. Helper запрещает UI
через SecKeychainSetUserInteractionAllowed(false), получает attributes+ref
без secret data, затем SecKeychainItemCopyKeychain и SecKeychainGetStatus.
Только найденный пункт в unlocked-связке допускает tool; locked/unavailable
preflight не запускает его. Операции attributes/preflight строго quiet-only
и не возвращают ни атрибутов, ни секрета в stdout. Проверка статуса — снимок:
Apple отмечает, что lock-состояние может меняться; живой sleep/lock smoke нужен.

S3: owner.retryKeychainAccess → keychain_manual сразу передаёт action в
interactive readStore/legacy, без начального15с quiet-read. Если есть recovery
transition, сначала читается active source с этим разрешением; результат
переиспользуется только внутри текущего owner lock. Candidate/GC не забирают
это разрешение. Login stage/delete сохраняют прежнюю quiet-first политику.
Сам процесс использует githubKeychainProcessTimeout(action:):120с против15с
в фоне. Quiet metadata probes action не потребляют; wrapper делит общий
монотонный deadline между preflight/tool/confirmation, не добавляет новый срок.

S4: stdout читается chunks≤8192 с буфером≤128KiB. Первый лишний байт вызывает
TERM→KILL и .failure(65)→.corrupt; partial output не возвращается. Труба private,
stdin/stderr null, секретов нет в argv/diagnostics/файлах. Native secret-read
fallback для V2 не добавлен, только metadata confirmation/preflight.

S5: lastError мог жить дольше authReason. keychainIssue связывает текст/action/
height, но в awaitingCode возвращает nil: там ошибка не рисуется и retry handler
не работает. startLogin очищает старые Keychain error/time/reason/scheduling
flag из UI и известную старую ошибку из defaults. Прочие сетевые ошибки не
превращаются в Keychain action.

## Проверки и прежние ожидания

- C5-13 обновлён: raw44 неоднозначен; отдельный injected probe обязателен.
- C5-15 (до AppKit):44 с native success/missing/denied/unreachable, blocked
  background без tool, exact-ref quiet-only metadata commands.
- C5-16 (до AppKit): retry через owner до фактической функции срока процесса,
  пароль16с проходит при120с; preliminary quiet-read отсутствует, background
  остаётся15с; ambiguous44 не переводит owner в actionRequired(missing).
- C5-17 (до AppKit):128KiB−1/= /+1, большой stream, ограничение запроса/chunk,
  немедленный stop, overflow доходит до auth как corrupt.
- C5-18 и C5-04:awaitingCode без retry/его высоты, чистка начала login.
- C5-14 после AppKit:64 actual Settings draws RU/EN × Simple/Advanced ×
  three Keychain issues+HTTP500 × current/restored × on/awaitingCode.
  Проверяются error tooltip/retry hit/bounds/nonoverlap; новых PNG нет.
- Старый GHAuthFixture теперь отвечает на direct interactive read тем же
  fault/items oracle, если явного interactive override нет; legacy quiet count
  3→2. Проверки запрета утечки permit, transitions/GC/login не ослаблялись.

Баланс Swift, статические wiring/build/diff checks выполняются на Linux;
Swift/AppKit и живая Связка требуют Mac. Python/агенты/своё ревью не запускались.
PNG209/523 и manifest expectations прежние. Живой гейт — пересборка без
logout/login, background lock/unlock, ручной пароль дольше15с, видимость retry.

Источники API: [Apple SecurityTool](https://github.com/apple-oss-distributions/Security/blob/main/SecurityTool/macOS/keychain_find.c),
[SecKeychainGetStatus](https://developer.apple.com/documentation/security/seckeychaingetstatus(_:_:)),
[SecKeychainItemCopyKeychain](https://developer.apple.com/documentation/security/seckeychainitemcopykeychain(_:_:)).
