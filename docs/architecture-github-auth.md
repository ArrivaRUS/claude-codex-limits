# GH-AUTH-STABLE: принятый контракт

2026-10-04. База `297777d`, ветка `codex/stable-github-auth`. PRD:
`prd-github-auth-stability.md`; маршрут: `github-auth-stability-plan.md`.
Два первых архитектурных исследования выполнены независимо: Primary —
GPT-6 Astra/high, Alternative — GPT-6.1 Sol/high. После сверки с PRD оба
проверили общий контракт; замечания challenge включены ниже. Код ещё не начат.

## Совместимость и полномочия

Здоровый legacy access token читается прежним readonly adapter без перевхода,
выдуманного срока или массовой миграции. Только новый явный device login
запрашивает `gist offline_access`. Глобальные настройки OAuth App не меняются;
ошибка issuer не запускает повторный device flow. Logout остаётся локальным.
Реальные credentials/keyring/API не используются при разработке и тестах.

GitHub допускает optional expiring OAuth tokens: access 8 часов, refresh
6 месяцев без использования; device flow refresh не требует client secret.
Успешная ротация инвалидирует старую пару. Источник:
[GitHub OAuth Apps](https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps).
Сроки в коде берутся из ответа, а не из этих справочных значений.

## Защищённая запись и источник истины

CredentialV2 хранится одним защищённым payload: schema=2, epoch явного входа,
generation, accessToken, refreshToken?, obtainedAt, accessExpiresAt?,
refreshExpiresAt?, tokenType, стабильный userID и login. Generation immutable;
access и refresh разных выдач не смешиваются. Envelope ASCII/base64url JSON
для безопасной передачи через stdin; base64 не является шифрованием.

Несекретный manifest: formatVersion=2, epoch, active={generation,backend}|null,
transition={from,to,phase,recoveryAttempts}|null, cleanupRefs, retryAt,
failureReason (enum). Фазы prepared/requestStarted/ready/validationPending.
Публикация одним atomic update переключает active и удаляет transition.
Linux: `authV2` внутри существующего SYNC_STATE_PATH, один active pointer;
все связанные записи reload под существующим межпроцессным sync flock,
atomic replace и fsync каталога. macOS: DATA_DIR/github-auth-state.json,
sync queue плюс file auth lock; defaults только проекция для UI.

V2 отделён от legacy namespace: Linux SS service=github-credential-v2,
file CONFIG_DIR/github-credentials/<generation>; macOS отдельный Keychain
service с generation. Не писать envelope в прежний raw-token service/file.
Linux compatibility backend marker=`credential-v2`; старый logout/сброс
legacy generation/login конфликтует с V2 и прекращает session, без resurrection.
Полный downgrade/одновременная работа старого и нового binary не поддержаны.

Incomplete candidate — отдельный envelope kind с optional пригодными новыми
values, никогда active. Не дополняется старой парой; unknown→bad_refresh после
неопределённой предыдущей ротации классифицируется lost_result.

Refresh backend закреплён: SS/Keychain не переходит в plaintext даже после
получения новой пары. Ранее выбранный file backend остаётся разрешённым с 0600.
Обычный explicit login сохраняет согласованную прежнюю backend-selection policy.

## API и транзакция

`readCredential` возвращает typed ready/missing/locked/unreachable/timeout/
corrupt/changed/signedOut и не запускает сеть. Missing означает завершённое
чтение доступного backend без записи; `_ss() is None` — unreachable без второго
DBus вызова. `ensureAccess(reason,now)` — единственный потребитель refresh;
возвращает access с captured epoch/generation, temporary или actionRequired.
Presentation snapshot несекретный; GUI rendering не делает DBus/HTTP.
Clock, manifest, store, transport, lock и checkpoints injectable для тестов.

Production owners: Linux новый `linux/ccl/auth.py` AuthOwner и Swift новый
`Sources/GitHubAuth.swift` GitHubAuthOwner. Explicit dependencies не имеют I/O
defaults: production factory живёт в integration. Linux ensure_access принимает
lock_held для existing sync flock, исключая nested lock. Swift build.sh создаёт
temporary main.swift из LimitsMonitor.swift и компилирует explicit core/selftests.
Tester владеет отдельным Sources/GitHubAuthSelfTests.swift и linux/tests.
Ранний --auth-selftest dispatch до mkdir/обычного startup/AppDelegate.

Checkpoint API: before_intent, after_intent, after_request_started, after_response,
after_parse, after_stage, after_readback, before_identity, after_identity,
before_publish, after_publish, before_retire, after_retire, after_logout_tombstone.
Hook получает только имя и nonsecret ref/epoch; после response/parse/stage находится
в bounded SIGINT deferral. Return types ready/temporary/actionRequired/signedOut;
typed read и snapshot по контракту выше. Exact сигнатуры freeze после foundation.

Под lock: reload → recovery → отдельный probe generation → durable intent с
заранее известным toRef → requestStarted → один OAuth POST → parse → FIRST
durable stage всей полученной пары → verify readback → `/user` → atomic publish
→ адресное retirement предшественника. UserID стабилен; login может меняться.
Временная ошибка identity сохраняет candidate и повторяет validation.
До всех gist/API операций используется ensureAccess и captured reference.

В vault нужен отдельный `stageRefresh`: pinned backend, candidate recovery ref,
timeout=uncertain, без abandoned cleanup и file fallback. Late write не может
затереть другую generation. Probe использует другой ref; неопределённый probe
блокирует issuer call до разрешения. Отсутствие item при возможном late writer
не разрешает забыть cleanup ref. Epoch logout делает ref адресной очисткой.

Recovery проверяет существование валидного durable toRef даже в prepared/
requestStarted: crash между stage и ready не разрешает повторить одноразовый
refresh. При storage failure полученный candidate остаётся в памяти, повторяется
только сохранение. Бюджет восстановления requestStarted без candidate сохраняется
в manifest и не обнуляется перезапуском. Перед terminal ошибкой повторно проверить
candidate/active под lock. Linux bounded SIGINT deferral охватывает issuer request,
parse и первую bounded stage-попытку; не бесконечные persistence retries.

## Ошибки, сроки и фоновые попытки

0/timeout/403/429/5xx/storage/malformed response не являются server revoke.
Только корректный issuer bad_refresh_token текущей транзакции после recovery
подтверждает непригодность refresh. Если access работает, сохранить его и показать
невозможность продления. После unknown rotation — причина «результат обновления
не удалось восстановить», а не выдуманный отзыв. Triple401 сохраняется для
access-only; refreshable access401 сначала проходит recovery/refresh.

Парсер принимает long-lived ответ без refresh/expiry. Refresh без access expiry
обновляется по 401. Не смешивать частичный ответ с прошлой парой: пригодные новые
credential values сохраняются непубликуемым candidate. Невалидный lifetime
(bool/NaN/infinity/negative/чрезмерный) означает unknown, не немедленное expiry.
Часы и число сетевых сбоев сами не удаляют token. Lead=min(900 секунд, TTL/4).
RequestStarted без candidate разрешает максимум одну дополнительную issuer
попытку после recovery; счётчик сохраняется до попытки и переживает restart.
Повторный bad_refresh_token проверяет toRef/epoch перед action-required; бюджет
не применяется к заведомо неотправленным запросам и не оправдывает быстрый цикл.

Maintenance startup/wake/не реже 10 минут независимо от Advanced, свежести
локального индекса и Auto лимитов; он восстанавливает и реально авторизованный
sync, а не только метку login. Обычный backoff 1/5/10 минут с bounded jitter;
более долгий — только по issuer Retry-After/rate policy. Без UI login storm.
OAuth POST с секретами в body — exact HTTPS origin/path и запрет redirects.
Bearer только на разрешённом API origin; raw gist без credentials.

Logout под lock сначала durable tombstone/new epoch, затем cleanup active,
pending и retired refs. Незавершённый logout запрещает использование всех refs;
late workers не публикуют session. Server revoke не выполняется.

## Граница гарантии и проверка

30/180 моделируемых дней проверяются реальными операциями fake authorized sync,
счётчиками refresh/device flow/browser, включая legacy и две независимые машины.
Sleep 2/6 недель, storage/network recovery, два изолированных процесса, crash
checkpoints, SIGINT/late writes и logout обязательны. UI/CLI RU/EN проверяются
на реальных fixture controls, не одним formatter. Isolation review до запусков.

A9: issuer расходовал refresh, ответ потерян и durable candidate не существует.
GitHub не обещает idempotency/grace для этого случая. Журнал не восстановит
неизвестный secret; bounded honest recovery может потребовать один явный login.
Реальный server revoke и refresh expiry также требуют входа. Это не выдаётся за
здоровые A1/A2 сценарии. Live ALSE и месяцы реального времени не заявляются по CI.
