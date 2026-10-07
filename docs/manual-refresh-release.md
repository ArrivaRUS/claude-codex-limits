# MANUAL-REFRESH — macOS 3.2.6 · release candidate / кандидат

2026-10-07. Статус: кандидат frozen3, финальная QA точного пакета идёт.
Выпуск и установка 3.2.6 ещё не выполнены. Установленная macOS остаётся 3.2.5;
Linux остаётся 0.4.4. Итоговый статус меняет координатор по доказательствам
пакетной QA, публикации и установки в [реестре приёмки](manual-refresh-verification.md).

## Русский

В простом и расширенном видах панели есть видимая кнопка **«Обновить сейчас»**.
При включённых подписках и действующем входе в соответствующий CLI она запрашивает
новые лимиты Claude Code и Codex независимо от выбранного интервала Auto или
фиксированного опроса и локальной паузы после ошибки сети. Режим опроса сохраняется.
Открытие панели в Auto по-прежнему соблюдает расписание.

Каждый сервис показывает **«Обновляем…»** и собственный результат. Ответ одного
не ждёт второго. Успешный ответ с неизменившимися процентами — нормальное
обновление. **«Данные»** показывает время снимка, **«Следующая автопопытка»** —
время следующей попытки по расписанию. При сбое предыдущие значения сохраняются
с прежним временем; неизвестное время обозначается `—`.

После частичной ошибки можно нажать **«Повторить»** только у проблемного сервиса.
Повторные нажатия не дублируют уже идущий запрос. Локальная защита от частых
нажатий длится **30 секунд от начала попытки** и показывает оставшееся ожидание;
это не ограничение сервера. Если сервис передал `Retry-After`, строка
**«Сервис разрешит повтор через…»** показывает отдельный серверный срок.
Ручной запрос его не обходит, автоматическая попытка допускается по истечении
срока. Неизвестный срок не выдумывается; допуск попытки не гарантирует её успех.

Обычное **«Обновить сейчас»** и фоновые попытки выполняются без системных окон
разрешений. Только если чтению записи Claude нужно разрешение, после указанного
ожидания появляется **«Разрешить доступ к Связке ключей»**. Это отдельная попытка
чтения до 15 секунд, в которой возможно системное окно. **«Отменить»** прекращает
попытку; новый запрос требует нового нажатия. Разрешение чтения не разрешает
запись обновлённых данных входа и не меняет права доступа автоматически.

При **«Не удалось сохранить обновлённый вход»** откройте **«Восстановить доступ»**,
разблокируйте Связку ключей и нажмите «Обновить сейчас» для повтора сохранения. Разрешение чтения
не означает успешного сохранения. Ошибка чтения или записи сама по себе не требует
повторного входа. Если сохранение всё ещё не удаётся, новый `claude login` —
дополнительный способ восстановления. При фактической проблеме входа выполните инструкцию CLI:
`claude login` для Claude или `codex login` для Codex, затем обновите данные.

Действие **«Повторить доступ к Связке ключей»** в Настройках → Синхронизация через
GitHub остаётся отдельным явным действием версии 3.2.5. Его ограниченная попытка
может запросить разрешение. Фоновые GitHub-операции сохраняют запрет системных
окон. Обновление лимитов не разрешает эти окна и не меняет вход GitHub.

## English

A visible **Refresh now** button appears in the header in both Simple and
Advanced views. With subscriptions enabled and the corresponding CLI signed in,
it requests new Claude Code and Codex limits without waiting for the Auto or
fixed interval or a local pause after a network error. The selected polling mode
stays selected. Opening the panel in Auto still follows the schedule.

Each service shows **Refreshing…**, followed by its own result. One reply does
not wait for the other. A successful reply with unchanged percentages is a normal
refresh. **Data** shows the reading time; **Next automatic attempt** shows the
schedule. A failed attempt keeps the previous figures and their original time.
An unknown time is shown as `—`.

After a partial failure, use **Retry** beside the affected service. Repeated clicks
do not duplicate a request already in progress. A **30-second local guard from
the start of an attempt** shows the remaining wait; it is not a server limit.
If the service supplied `Retry-After`, **Service allows retry in…** shows that
separate deadline. Manual requests respect it, and the automatic attempt becomes
eligible when it expires. No deadline is invented when it is unknown; eligibility
does not guarantee success.

Ordinary **Refresh now** and background attempts keep permission dialogs disabled.
Only when reading the Claude entry requires permission does **Allow Keychain
access** appear after the displayed wait. Click it for one read attempt limited
to 15 seconds; a system dialog may appear for that separate action. **Cancel**
ends the attempt; a new attempt needs a new explicit request. Read permission
does not authorize saving renewed sign-in data or automatically change access permissions.

For **Could not save renewed sign-in**, open **Restore access**, unlock Keychain,
then click **Refresh now** to retry saving. Read permission does not mean
saving succeeded. A read or save failure alone does not require signing in again.
If saving still fails, a new `claude login` is an optional recovery step.
For an actual sign-in problem, follow the affected CLI's instructions:
`claude login` for Claude or `codex login` for Codex, then return and refresh.

**Retry Keychain access** in Settings → GitHub sync remains a separate explicit
3.2.5 action. That bounded attempt may ask for permission. Background GitHub
operations keep system dialogs disabled. Quota refresh does not authorize those
dialogs or change GitHub sign-in.

## Источники и границы проверки

- Контракт: [manual-refresh-proposal.md](manual-refresh-proposal.md),
  [plans.md](plans.md). Пользовательские шаги выше сверены чтением frozen3
  `/private/tmp/ccl-manual-review3-yjtg_b29`.
- [LimitsMonitor.swift](../Sources/LimitsMonitor.swift): `drawQuotaPanel`,
  `doRefresh`, `restoreQuotaAccess`, `claudeQuotaKeychainHelper` и чтение/сохранение
  Claude. SHA256 `6bfdb2b5aa0eb5c567f353f79452587d183dd3595c93839d4e0a32c17bd8a42e`.
- [QuotaRefresh.swift](../Sources/QuotaRefresh.swift): `QuotaRefreshState`,
  `quotaRefreshFeedback`, `quotaRetryAfter`, `quotaSelectSnapshot`,
  `quotaReconcilePendingCredential`, `quotaClaudeRebaseUpdate`.
  SHA256 `b118084f80c26a4c86fe24417b3c5dd229ff14f686906b974feeea8af717e41b`.
- По сообщению координатора: production Code+Security review narrow delta — PASS,
  прежнее P2 закрыто; результаты pure-проверок — 78/1089/0. Автор документа эти
  проверки не запускал. Финальная QA точного пакета идёт; её результат, выпуск
  и установку подтверждает [реестр приёмки](manual-refresh-verification.md).
- Чтением сверены RU/EN подписи обновления, результатов, времени, адресного повтора,
  разрешения чтения, отмены и восстановления после ошибки сохранения. Нативные
  диалоги, клики, ACL и реальные CLI/API этим чтением не проверены.
- Сохранён контракт GitHub 3.2.5: [keychain-quiet-release.md](keychain-quiet-release.md).
  Статус установленной версии взят из поручения координатора;
  автор документа не запускал приложение, тесты, CLI-вход, Keychain или API.

## Инженерные ограничения frozen3

- `allowquota:claude` доступно только для `readInteractionRequired`; это один
  READ permit до 15 секунд. `cancelquota:claude` отзывает его. Обычные
  `refresh`/`retryquota` и запись остаются quiet. Разрешение чтения не переносится
  на UPDATE; автоматического изменения ACL, добавления или удаления записи нет.
- При несохранённом продлении кандидат хранится только в RAM. Перед повторной
  записью заново читается текущая запись. Ошибки чтения, записи и отмена сохраняют
  кандидата; сохранение либо подтверждённая актуальная пара позволяют убрать его.
  Завершение процесса теряет несохранённого кандидата: устойчивого к перезапуску
  журнала этой пары нет, восстановление после такой потери не гарантируется.
- Сравниваются значения access/refresh, а не формат JSON или сторонние метаданные.
  Уже сохранённая обновлённая пара принимается без повторной записи. Другая пара
  с непустым access принимается как сменившийся вход CLI без перезаписи старым
  кандидатом. Это сравнение локальных данных, не серверная проверка аккаунта.
- Если пара прежняя, новые `accessToken`, `refreshToken`, `expiresAt` переносятся
  в текущую запись с сохранением остальных полей. Helper сверяет текущие байты
  с ожидаемыми и обновляет найденную запись по persistent reference. Это проверка
  перед записью, а не атомарный CAS: между `SecItemCopyMatching` и `SecItemUpdate`
  остаётся окно конкурирующей внешней записи. Полная защита от одновременного
  изменения записи другим процессом не обещается.
- `writeUnavailable` теперь имеет адресную подсказку: разблокировать Связку ключей
  и повторить сохранение через «Обновить сейчас». Новый `claude login` указан
  только как дополнительный ручной способ, если сохранение всё ещё не удаётся.
  Ошибка хранения не объявляется истёкшим входом; автоматический вход не запускается.
