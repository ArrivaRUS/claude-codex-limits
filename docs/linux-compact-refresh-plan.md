# LINUX-COMPACT — Linux 0.4.5

2026-10-08. Прямой запрос владельца: нужна Linux-версия последнего исправленного интерфейса macOS3.2.7. База53bb5bf. Выпуск DEB linux-v0.4.5 разрешён; macOS3.2.7 остаётся Latest.

## Объём и критерии

Порт актуального docs/compact-refresh-ux.md на существующую PyQt панель шириной360: единый фон, refresh icon рядом с settings; никакой внешней полосы/списка. Compact feedback внутри provider cards до32pt, короткое состояние запроса и время данных; подробности вtooltip. Использовать существующие Linux состояния и existing refresh actions. Перенести также принятый пользовательский контракт docs/manual-refresh-proposal.md: ручной запрос обходит локальные15мин/Autoerrorbackoff,30сguard, per-provider singleflight/independentcompletion/failedproviderretry; реальные Retry-After соблюдаются, successunchanged отличим отfallback, timestampsчестные. Сохранить выбранныйрежим. Linux используетсуществующиеCLIcredentialfiles, безинтерактивноговхода. Не переносить macOSKeychain-specificpermit.

Четыре ручных интервала15м/30м/1ч/4ч, сохранение14400, old60/300→1800. Auto: A+actual enabled-provider intervals; different→both; fixed onlyselected; off nointerval. Удалить standalonefrequency и snapshotpace annotation с высотой, сохранить forecast и полезныеauth/missing/notavailable notices. RU/EN, Simple/Advanced, one/two/off.

## Команда и проверки

DesignEngineer Sol6.1/high реализует UI+версию; DeveloperComplex Astra/high переносит принятый manualrefreshконтракт и интеграцию после последовательной передачиapp.py; независимый Tester Sol6.1/high обновляет ограниченные тесты и synthetic PNG матрицу. CodeReviewer Astra/high — frozen production+isolation. Изменение transport retry/authclassification требует отдельного SecurityAnalyst по security-gate T2; новыеendpoints/secretstoresне вводятся. Runtime только после isolation review, без настоящих credentials,keyring,logs,API. Использовать штатный GitHub Linux CI: dedicated user, networknone,nohostmounts,offscreenBreeze/Fusion. QA проверяет exactCI/package; DesignReviewer принимает реальныеPNG независимо от geometricassertions. Не заявлять живойALSE/ThinkPad/nativekeyring проверенными без доказательства. Mac исходники/релиз не меняются.

Координатор: план/память, интеграция, CI, публикация проверенногоDEB --latest=false, публичныйSHA, синхронизация основногоcheckout. Не устанавливать Linuxпакет на Mac и не заявлять remoteinstall.

## Статус

Завершено и опубликовано 2026-10-08: Linux0.4.5 на19440ee112f164b411bf4715d6fa65077a272c48. Проверенный CI DEB выпущен какlinux-v0.4.5, macOS3.2.7 остаётсяLatest. [Приёмка](linux-compact-refresh-verification.md).

Уточнение объёма после чтения Linux: existing manualbutton сохраняла900сfloor. Поэтому порт включил принятыйMANUAL-REFRESHконтракт. Владение app.py передавалось последовательно между DesignEngineer и DeveloperComplex; независимые проверки выполнены отдельными ролями.
