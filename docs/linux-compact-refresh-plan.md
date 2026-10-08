# LINUX-COMPACT — Linux 0.4.5

2026-10-08. Прямой запрос владельца: нужна Linux-версия последнего исправленного интерфейса macOS3.2.7. База53bb5bf. Выпуск DEB linux-v0.4.5 разрешён; macOS3.2.7 остаётся Latest.

## Объём и критерии

Порт актуального docs/compact-refresh-ux.md на существующую PyQt панель шириной360: единый фон, refresh icon рядом с settings; никакой внешней полосы/списка. Compact feedback внутри provider cards до32pt, короткое состояние запроса и время данных; подробности вtooltip. Использовать существующие Linux состояния и existing refresh actions. Не заявлять перенос backend-контрактов macOS3.2.6: Linux transport/auth/poll scheduling сохраняются.

Четыре ручных интервала15м/30м/1ч/4ч, сохранение14400, old60/300→1800. Auto: A+actual enabled-provider intervals; different→both; fixed onlyselected; off nointerval. Удалить standalonefrequency и snapshotpace annotation с высотой, сохранить forecast и полезныеauth/missing/notavailable notices. RU/EN, Simple/Advanced, one/two/off.

## Команда и проверки

DesignEngineer Sol6.1/high реализует только UI+версию; независимый Tester Sol6.1/high обновляет ограниченные тесты и synthetic PNG матрицу. CodeReviewer Astra/high — frozen production+isolation. Если обнаружен securitysurface — отдельный SecurityAnalyst; UI/localsettings сам по себе его не требует. Runtime только после isolation review, без настоящих credentials,keyring,logs,API. Использовать штатный GitHub Linux CI: dedicated user, networknone,nohostmounts,offscreenBreeze/Fusion. QA проверяет exactCI/package; DesignReviewer принимает реальныеPNG независимо от geometricassertions. Не заявлять живойALSE/ThinkPad/nativekeyring проверенными без доказательства. Mac исходники/релиз не меняются.

Координатор: план/память, интеграция, CI, публикация проверенногоDEB --latest=false, публичныйSHA, синхронизация основногоcheckout. Не устанавливать Linuxпакет на Mac и не заявлять remoteinstall.

## Статус

План до реализации зафиксирован. Код Linux0.4.4 прочитан; обновлениеquota уже доступно черезrefreshicon. Реализация0.4.5 и проверкиpending.
