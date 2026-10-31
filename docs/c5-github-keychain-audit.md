# C5 / D4 — GitHub после пересборки, 2026-10-31

Владелец: установлен `16f7aab` / 3.3.1; отправка остановилась, в Settings видна
ошибка разрешения Связки, кнопки повтора нет. Это отдельная задача поверх fix8;
его редактор/C5-12 в этом проходе не менялись. Доказательства Mac до патча
не доказывают работоспособность нового пути.

| Пункт | Создание и ACL по коду |
|---|---|
| V2, service `Claude Codex Limits GitHub Credential V2`, account UUID поколения | `githubAuthNativeStoreHelper`: SecTrustedApplication для `/usr/bin/security` и текущего helper; SecAccessCreate с обоими; SecItemAdd с kSecAttrAccess. Только add, duplicate не меняет существующий ACL. Этот путь уже был в исходном коде 3.3.0/3.3.1 и в установленном владельцем 16f7aab; текущий патч его не меняет. |
| Legacy, service `Claude Codex Limits GitHub`, account NSUserName при создании | `githubAuthNativeKeychainHelper`, legacy-write: SecItemUpdate либо SecItemAdd без явного kSecAttrAccess. Доверие системной утилите по этому пути не гарантируется. Read исторически выбирает один service-match. |

Идентичность ad-hoc helper меняется при пересборке; прежний ACL может потребовать
разрешения для нового бинаря. Явный доверенный system tool позволяет V2-чтению
не зависеть от этой идентичности. Фактический ACL пункта на Mac владельца и старых
пунктов не считывался: подтверждён конструктор, а не содержимое живой Связки.

V2 background/manual read теперь запускает **один** `/usr/bin/security` с argv
`find-generic-password -s <фиксированный service> -a <UUID> -w`. Stdout — приватная
труба; stdin/null, stderr/null; диагностик с output нет. Access/refresh/envelope
не проходят через argv или файлы. Валидация V2 envelope использует прежний pure
validator writer (schema/generation/epoch, размер и формат токенов).

Нативного fallback для V2 нет: он снова зависел бы от меняющейся подписи и
создавал второй срок ожидания/второе потребление разрешения. Exit0 — decode,
44 — missing,51/128/36/29 — locked, прочее — unreachable, timeout — timeout.
Нет тихого успеха/обнуления токена. Общий deadline15с фон/120с explicit retry,
fence и TERM→KILL сохраняются. Legacy оставлен на прежнем native quiet/interactive
пути; ACL существующих пунктов не расширяется. Прямая system-tool команда сама
не имеет native quiet-флага: если Связка заблокирована или конкретный V2 ACL не
доверяет tool, системное разрешение/отказ всё ещё возможны в пределах deadline.

Коды сверены с [Apple SecurityTool](https://github.com/apple-oss-distributions/Security/blob/main/SecurityTool/macOS/keychain_find.c) и [SecBase.h](https://github.com/apple-oss-distributions/Security/blob/main/base/SecBase.h): CLI возвращает OSStatus, родитель получает младшие8бит.

Кнопка пропадала независимо от ACL: `projectAuth(.ready)` очищает authReason,
но `lastError` живёт до успешного sync-cycle. Settings рисовал lastError, а кнопка
смотрела только authReason. Теперь `SyncUIState.keychainIssue` — общий источник
для текста, syncWarning, canRetryKeychain и высоты. Точные старые сообщения RU/EN
из defaults распознаются, а не ищутся по произвольной подстроке; текущий язык
применяется заново. Один scheduler-flag и HTTP500 кнопки не создают.

- C5-13, до AppKit: injected runner, V2/legacy route, exit codes/timeout,
  единственный процесс, exact argv, private output, отсутствие секретов в diagnostics,
  invalid ref и повреждённый envelope. Никаких реальных процессов/Связки.
- C5-14: pure восстановление старого сообщения после очистки reason; после AppKit
  32 bitmap Settings draw (RU/EN × Simple/Advanced ×3 issue+HTTP500 × current/restored).
  Проверяются текст/AX error hit, retry hit, границы/перекрытия; PNG не добавляются.

Новые проверки RED до сборки и запуска на Mac. Статические проверки Linux —
баланс Swift, wiring, build syntax и diff whitespace. Python не запускался.
Следующий живой гейт: без logout/login после пересборки свежие upload/read;
при отказе Связки — видимая кнопка, ручной повтор с120с; фактическая ACL-проверка
остаётся у владельца. Стабильная подпись сборок остаётся C6; D4 read continuity — C5.
