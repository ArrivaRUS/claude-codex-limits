# Установка Linux 0.4.5 на Astra · 2026-10-08

На текущей Astra пакет обновлён **0.4.4 → 0.4.5**. Установка завершилась с кодом 0, `dpkg` показывает `0.4.5 install ok installed`; все **39** установленных файлов payload совпали с DEB по содержимому, правам и владельцам. Штатный GUI PID **133128** жив через **3 секунды**, `ccl-sync.timer` активен. Это подтверждение установки и старта; новый ручной smoke 0.4.5, успешный обмен и работа KWallet/API не проверены.

## Пакет и Git

[linux-v0.4.5](https://github.com/ArrivaRUS/claude-codex-limits/releases/tag/linux-v0.4.5) опубликован 2026-10-08 05:08:42 UTC, source `19440ee112f164b411bf4715d6fa65077a272c48`. DEB: `claude-codex-limits_0.4.5_all.deb`, 621880 байт; SHA-256 `99acde08c13b7c66335718554ec09af087253e3e3b58113e720e3a67dfc71b10` совпал с GitHub digest. Latest остаётся macOS 3.2.7.

На старте локальный HEAD `02f824c9eace5177aaa40763c17d00c4631579ad`; `origin/main` `76378639cb531c7358d5a91e99db23ddada0c3e8` объединён без коммита в `codex/alse-045-install`. Рабочее дерево содержит незакоммиченный merge и документационные изменения. Интеграция Git и установка DEB — отдельные операции; пакет проверен по неизменяемому release source, а не по локальному HEAD.

Независимый QA пакета: **34** исходных файла exact, **39** файлов payload и **3** control exact при независимой пересборке; проверка синтаксиса **19** Python-файлов, desktop/systemd units/скрипты PASS. Приложение и suite этим QA не запускались. [CI 37730102871](https://github.com/ArrivaRUS/claude-codex-limits/actions/runs/37730102871) на release source — success; **358 тестов / 0 failures/errors/skips** по [приёмке выпуска](linux-compact-refresh-verification.md). Нового локального прогона 358 тестов нет.

## Выполненная установка

Предпосылки: SHA/package/version проверены, системные Python 3.11.2, PyQt5 5.15.9 и python3-dbus установлены. Независимый Reviewer принял финальный скрипт после исправления ожидания окончания oneshot-service; исправление внесено **до** установки. SHA-256 скрипта `633dd97f61a3a112c77765eee9d53b80735ae365e482d38c90cecb43ac68a20d`.

Координатор выполнил:

```sh
sh /tmp/ccl-alse-20261008/install-verified.sh
```

Скрипт сверил SHA и metadata, остановил активный timer, дождался завершения service и вызвал:

```sh
timeout 120s pkexec /usr/bin/dpkg --install /tmp/ccl-alse-20261008/claude-codex-limits_0.4.5_all.deb
dpkg-query -W -f='${Package} ${Version} ${Status}\n' claude-codex-limits
```

Результат — exit 0 и `claude-codex-limits 0.4.5 install ok installed`. Через exit trap выполнены user `daemon-reload` и восстановление timer, итоговый статус `active`. Сверка установленного payload дала 39 файлов, 0 несовпадений. Старый GUI PID 3701 остановлен SIGTERM; `/usr/bin/claude-codex-limits` запущен заново, PID 133128 работал при проверке через 3 секунды (`exit_code: null`). Активный timer и живой процесс не доказывают успешную синхронизацию.

## Доказательства и ограничения

Долговечные файлы: [release/CI](verification/alse-0.4.5/release-evidence.json), [QA пакета](verification/alse-0.4.5/package-content.json), [установленные файлы](verification/alse-0.4.5/installed-check.json), [старт GUI](verification/alse-0.4.5/app-start.json), [выполненный скрипт](verification/alse-0.4.5/install-verified.sh.txt). Временные оригиналы — `/tmp/ccl-alse-20261008/`; они могут быть удалены.

Ручное подтверждение пользователя «значок есть, панель открывается» относится только к [0.4.4 от 7 октября](alse-0.4.4-verification.md). На 0.4.5 не проверены live KDE/Fly clicks, шрифты/позиционирование, реальные refresh/Retry-After/4ч/Auto, звук, native KWallet, OAuth/API/gist и sleep-wake. Статический QA не использовал настоящие credentials, keyring или журналы; штатный production-запуск использует обычное окружение пользователя, содержимое входа не читалось.

После package QA менялись документы и системная установка; release source и DEB не менялись. В этой документационной подзадаче после проверки старта изменены только назначенные документы. Отчёты macOS относятся к другой машине. Оставшиеся сценарии — в [бэклоге](../backlog.md).
