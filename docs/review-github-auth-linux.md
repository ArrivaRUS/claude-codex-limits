# GH-AUTH-STABLE: независимое Linux review

## Rev5b: source delta PASS, полный RUN НЕ PASS

Последующий full RUN с accepted legacy fixtures и разрешённым loopback:
**284 tests / 1 FAIL / 26 SKIP**, exit1, 20.117s,
`/tmp/ccl-auth-linux-final2-full.log`. Последний legacy oracle terminal rc1
обновлён на rc2+обязательный login hint; независимый delta PASS,
targeted TestNoTokenSubstring **1 PASS**, exit0. Итоговый Ubuntu CI 0 skip
и package/QA ещё pending. Final sync `63a8674557df6c1da06385c1d2e5c214a821deb5719b3b192c1a3d609a60772f`
сохраняет cancelled sentinel до auth status publication; delta Code+Security PASS.

Независимые CodeReviewer/SecurityAnalyst приняли production delta auth
`48ee84cac854b7174eebd78446cb346199ffb2ff09f76801eb537838daef9d60`,
vault `96ae997f72d384a10c51d2667930ad9f6da2ac864b174b7120584a7c822e0fcc`.
Root после отдельного full isolation PASS выполнил frozen copy full discover:
**283 tests / 19 failures / 4 errors / 26 skipped**, exit1, 38.104s,
`/tmp/ccl-auth-linux-v5b-full.log`. Две failures — подтверждённый неверный
grant-count oracle (Tester исправил); две errors — sandbox запрещает loopback
bind, следующий разрешённый RUN с эскалацией/Ubuntu CI. Остальные legacy
fixtures/контрактные assertions разбирает отдельный Tester; не объявлять
production/пакет полностью принятым до исправлений и повторного full RUN.

## Rev4: прерванный RUN и новые findings

Root после narrow isolation PASS запустил core/integration/concurrency/UI
в frozen copy `/tmp/ccl-gh-auth-final`. RUN прерван Ctrl+C (exit130) после
зависания нового SIGKILL fixture в `finally release.set()`:
multiprocessing.Condition ждал acknowledgement уже убитого child.
Traceback `/tmp/ccl-auth-final-linux.log` подтверждает fixture deadlock,
это не production FAIL и полного счётчика нет. Нужна правка Tester и повтор.
Свежий CodeReviewer также нашёл P1 candidate access expiry до identity:
auth345–352 бесконечно `/user` старым access вместо valid candidate refresh.
Security P1 reservation-before-writer описан в security-github-auth.md.

После narrow isolation approval root повторил frozen rev4 набор без
TestActualFileCrash: **60 tests / 57 PASS / 3 Qt SKIP**, exit0, log
`/tmp/ccl-auth-final-linux-nonkill.log`. Core, actual sync/CLI pipeline,
durable device attempt и isolation guards прошли; PyQt отсутствует локально.
Это не acceptance rev5 и не full-suite/ALSE PASS; новый writer/candidate
протокол ещё исправляется. SIGKILL regression повтор pending.

2026-10-04, CodeReviewer GPT-6 Astra/high, отдельный контекст от автора.
Ревизия `eef4b77ae357b4923e0427c73135beb83a37d1fd` + frozen Linux source diff.
SHA256 всех шести файлов совпали в начале и конце. Только чтение; тестов,
real stores/API и записи reviewer не выполнял. Swift/tests не проверены.

## Цикл 1 — НЕ PASS

| ID | Приоритет / исходная строка | Сценарий и требуемое исправление |
|---|---|---|
| L1 | P1 auth.py:442,465,215 | Login stage timeout не учитывает uncertain writer; logout забывает отсутствующий ref, поздний SS write остаётся. Несколько metadata writers той же generation требуют подтверждения завершения всех, не первого найденного payload. Единый durable учёт uncertainty до удаления/забывания. |
| L2 | P1 auth.py:444,267 | Cancel во время user validation всё равно публикует login. Повторная проверка attempt/cancellation непосредственно перед commit; cleanup без maintenance resurrection. |
| L3 | P1 auth.py:372 | Unknown→дополнительная попытка→503/429→prepared обходит persisted budget. Неразрешённая uncertainty и counter сохраняются независимо от фазы/последующего отказа. |
| L4 | P1 auth.py:527; app.py:1154 | A→B сохраняет remote cache A и складывает его при недоступном первом sync B. Durable привязка cache к identity/epoch либо безопасная очистка до смешивания. |
| L5 | P1 sync.py:182,249 | Legacy ref retirement живёт только в локальной переменной; crash после V2 publish теряет его. V2 logout не обрабатывает tokenDeletePending. Durable legacy retirement до active switch, общий cleanup. |
| L6 | P2 auth.py:437 | Explicit re-login наследует compatibilityChanged и остаётся signedOut. Новая явная epoch снимает fence. |
| L7 | P2 cli.py:60 | Terminal lost_result/expired/missing при сохранённом login блокирует ccl-sync login. Проверять auth snapshot, разрешать явное восстановление; healthy session не менять. |

DeveloperComplex получил исправления цикла 1; новые hashes и независимая
повторная проверка обязательны. Это не подтверждение воспроизведения или PASS.

Frozen hashes: auth 227b4707b819443de48a9263209f7c2e47d8a4e081d98260bad733ff7e86d79c;
common 1abc9aeb815cd2f9ed0f23d37409e73fd502dd975fe9bdebc6325cc752ba14da;
vault cf1c848d3c2e891df4e41a707c786634e07fe6fd10001ccc10b4f0fab471baf0;
sync cbe40a3ceae792594313bafe36baf75b45b4188adf46d86a33d536ce8b4099dc;
cli 0c01db68fa692beaaf93bceb787703772f5084de9b0ad1fd6aecaf4b9aff683d;
gui/app 1318b13ea05a90fb404235126ea86c72099a057828a8a0cf58257f23b8e96a23.

## Цикл 2 — НЕ PASS

Rev2 auth `e74572848227b13228c321e4b9fb7633653fc0fb9dda9e145135f39402d78ead`.
Reviewer подтвердил исправление шести исходных классов; отмена исправлена на
успешном пути. Остаются P1: cancel/KeyboardInterrupt при stage timeout не делает
durable abort; generic Store legacy-retirement перезаписывает corrupt manifest
до strict read. P2: writer flock не освобождается при ошибке/сигнале до запуска
worker. Автор получил цикл 2, runtime проверки автора не выполнялись.

## Узкая изоляция и фактический первый запуск

Reviewer отдельно дал core isolation PASS на rev2 + исходные пять frozen core
test files, `_isolate.py` `d6bd720a02a59ce6b7042a4f0867affc53eff90de57298979baaa93472c1c028`.
Это не full suite/production PASS. Root запустил только четыре core modules:
40 tests, 7.763 s, exit1, 39 passed/1 process-barrier failure. Pipeline Tester
подтвердил причину fixture: child clock загружался после capture now в ensure;
исправление preload clock требует нового hash/isolation review и повторного RUN.
Никакие реальные credentials, store, API или пользовательские logs не использованы.
