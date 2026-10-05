# AUTOSTART-1 — версия после перезапуска Mac

2026-10-05. Source HEAD `5b947f52076a236d9f1feacf2beb8052544b985e`.

## Запрос и критерий

Владелец сообщил о старой версии после перезапуска, подтвердил платформу Mac.
Номер старой версии и последующее действие установки пока неизвестны.
Проверить actual binary и disk/loaded LaunchAgent; ремонтировать обнаруженное
несоответствие. Различать публикацию релиза и локальную установку.

## Системный снимок координатора

- Один обнаруженный процесс утилиты, PID5728: `/Applications/Claude Codex Limits.app/Contents/MacOS/ClaudeCodexLimits`.
- Bundle short/build 3.2.3; executable SHA256 `2b6728da03a284995b86ceec4dc5bd4822a04ee559a21dd6dc9f6fd8b7039ecd` совпадает с принятым DMG3.2.3. Strict codesign PASS.
- Mapped executable inode35229085 совпадает с текущим файлом: проверена загруженная копия, а не только Info.plist.
- Файл `~/Library/LaunchAgents/com.arrivarus.claudecodexlimits.plist` и загруженный launchd job оба направлены на этот canonical executable. RunAtLoad=true; runs1/last exit0, job not running. Текущий процесс отдельный; причина его запуска не установлена.
- Bundle создан сегодня; процесс стартовал в ту же секунду. Это не доказывает self-update или действие человека.
- Spotlight зарегистрировал canonical и project dist копии. Обе версии3.2.3 и executable SHA одинаковы; это не исчерпывающий поиск всех неиндексируемых копий.
- Предыдущий шаг 2026-10-04 публиковал v3.2.3, но не выполнял установку на Mac. Публикация и перезагрузка не заменяют локальную установленную копию.

Команды: scoped ps/lsof/stat/shasum/codesign/launchctl print/mdfind и Python plist
parsing. Первая sandbox ps попытка PermissionError не выполнена; разрешённая
read-only повторная проверка прошла. Credentials/logs/keyring/auth API не читались.
Receipt: `/tmp/ccl-autostart-diagnosis-2026-10-05.json`. Ни restart, ни установка,
ни изменение LaunchAgent этой диагностикой не выполнялись.

## Независимая source-диагностика Debugger

Debugger GPT-6.1 Sol/high: `setLoginEnabled` сохраняет текущий executablePath,
`loginEnabled` проверяет только наличие plist. `get.sh` заменяет canonical bundle,
не мигрирует прежнюю цель. Updater меняет текущий bundlePath. Общий flock даёт
раньше запущенной копии вытеснить позднюю. Фоновая проверка только сообщает об
обновлении, установка — отдельное действие.

Изолированное воспроизведение: actual copy-блок get.sh с временными SRC/DEST
обновил canonical fixture, сохранив прежний LaunchAgent target; два отдельных
процесса подтвердили Darwin flock/exit0 второго. PASS. Первые три попытки harness
с ошибками не засчитаны; четвёртая exit0. Реальные приложения/автозапуск не менялись.
Это возможный механизм для разных путей, не причина исторического случая.

## План и границы

- [x] Подтвердить платформу и версии/путь процесса.
- [x] Сверить mapped executable, подпись и accepted release SHA.
- [x] Сверить disk и loaded LaunchAgent target.
- [x] Исследовать source отдельным Debugger и воспроизвести механизм безопасно.
- [ ] Уточнить историческую версию/действие установки, если владелец располагает этим фактом. Это не условие ремонта текущего здорового снимка.
- [ ] Отдельный backlog: миграция autostart при смене пути; сначала определить portable/canonical контракт.

Текущий снимок: работает принятая3.2.3, автозапуск направлен на неё. Подтверждённого
локального несоответствия для ремонта нет; production не менялся. Историческая
причина старого запуска не установлена. Реальный reboot и будущая работа не проверены.

Первая попытка записи памяти через inline Python завершилась SyntaxError encoding
до выполнения и ничего не записала; документ и память сохранены apply_patch.
