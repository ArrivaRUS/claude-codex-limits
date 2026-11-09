# Claude token_policy · 2026-11-09

Инцидент: Linux 0.4.5 пропускает Claude при истёкшем входе и `credential_write: never`;
мак видит старые значения без объяснения. Бриф: один разработчик, без Git-мутаций,
выпуска, настоящих файлов входа/keyring/сети. Swift на Linux не компилируется.

План:

1. Проследить wire → Swift `.signInRequired` и существующую обработку 401.
2. Добавить статус к ветке `token_policy`, не вызывая провайдера и не меняя расписание.
3. Проверить сохранение снимка, дедуп/heartbeat, восстановление и `guarded`.
4. Прогнать затронутые модули и полный Linux-набор, передать ограничения Юрке.

Контракт: `accounts[].status = expired`, `expiredReason = signin_required`. Последние
успешные `asOf`, `windows`, `models`, `plan` остаются в bucket.snapshot. `_entry` пишет их
рядом со статусом. `_accept` при последующем успехе ставит `ok` и очищает причину.
Swift парсит оба поля (`RemoteLimitsWire.account`), переносит статус в `RemoteSource`
и выбирает `.signInRequired` для `expired`/`signed_out` (`RemoteLimitsWire.state`).
Состояния выключенного синка, ошибки синка и отсутствия heartbeat имеют приоритет.

Дедуп: `sync._fingerprints` включает статус в metaHash, исключая `lastSeenAt`;
`sync.write_due` пропускает неизменённую запись до обычного heartbeat 600 с.
Нового `attemptAt`, резервирования опроса и обновления токенов эта ветка не делает.
Preflight сохраняет прежнее правило «истёк или осталось меньше 120 с»; срок жизни
refresh-токена она не диагностирует. `signin_required` не утверждает возможность продления.

Тесты: `linux/tests/test_rl_token_policy_status.py` — 6 тестов: истёкший/отсутствующий
access/expiry, отсутствие provider HTTP и расхода бюджета, сохранение снимка/файла входа,
дедуп после перезапуска и heartbeat, успешное восстановление, прежний путь `guarded`.
Стенд `_rl_env.PubEnv` использует временные CLI/XDG-пути, FakeGist, FakeProviders,
запрещённые реальные HTTP/keyring и контроль реальных файлов (урок 006).

Проверка по коду:

- Wire: `docs/sync-protocol.md:445` / `:446`; HTTP 401 → `EXPIRED` —
  `linux/ccl/quota_refresh.py:154`, `linux/ccl/limits.py:240`.
- `_accept` сохраняет снимок на ошибке и снимает статус при успехе —
  `linux/ccl/publisher.py:238`; wire-сериализация — `:117`; правка — `:423`.
- Swift: парсер — `Sources/RemoteLimits.swift:456`, выбор последнего статуса по
  `attemptAt ?? asOf` — `:754`, перенос статуса/машины — `:848` / `:860`,
  приоритет `.signInRequired` — `:866`, прежний текст — `:1323`.
- Существующие C3-проверки UI для `expired` — `Sources/RemoteLimitsC3SelfTests.swift:108`;
  сохранение чисел в меню — `Sources/RemoteLimitsC3BSelfTests.swift:233`.
  На Linux эти проверки не запускались.

Прогоны (Python 3.14, `-B`):

- `python3 -B -m unittest discover -s linux/tests -p test_rl_token_policy_status.py -v`:
  6 passed, 0 failed/errors, 0 skipped. До правки тесты воспроизводили отсутствие статуса.
- `python3 -B -m unittest discover -s linux/tests -p 'test_rl_publisher*.py' -v`:
  147 tests, 134 passed, 0 failed, 13 errors, 0 skipped (233.889 с).
  Все 13 errors — `PermissionError: [Errno 1] Operation not permitted` при создании
  loopback-сокетов в тестовом HTTP-сервере, до вызова издателя. Отдельно воспроизведено
  на `TestA343ContinueBounded.test_default_call_1xx_flood_bounded_by_timeout`.
- Полный набор: 833 tests, 758 passed, 0 failed, 25 errors, 50 skipped (671.372 с).
  Все errors — `PermissionError: [Errno 1] Operation not permitted` в socket-тестах;
  49 skipped из-за отсутствия PyQt5, один — PID 1 принадлежит пользователю контейнера.
  Все 6 новых тестов и завершающие `test_zz_isolation` прошли.
  Запуск через `unittest.defaultTestLoader.discover("linux/tests")`,
  с предварительным импортом `_rl_env` (изолированный HOME/CLI/XDG) и глобальным `_net_guard`.
  CI-эталон — `.github/workflows/linux.yml`, `linux/tests/_ci_offline.py`: Docker без внешней сети,
  синтетическая учётка, PyQt5/dbus/dpkg. Здесь Docker нет, сетевой namespace недоступен,
  PyQt5 отсутствует; локальный прогон не заменяет этот CI.

Полный прогон не зелёный из-за ограничений среды; требуются штатный CI и ревью Юрки.
Сырые логи сессии: `/tmp/ccl-token-policy-publisher-tests.log`,
`/tmp/ccl-token-policy-full-tests.log`; отдельная репродукция socket-ограничения:
`/tmp/ccl-token-policy-socket-check.log`.

Остаток: ревью Юрки, macOS/живой сквозной прогон и выпуск Linux. Формат v1.1 не
расширяется, Swift не меняется. Установленные старые издатели продолжают прежнее
поведение до обновления; проверка настоящих машин/обновление VPS в задачу не входят.
