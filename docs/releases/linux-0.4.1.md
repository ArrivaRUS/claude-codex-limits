# Linux 0.4.1

<!--RU-->
- При включённом Auto кнопка «А» выделена сине-фиолетовым градиентом, а текущая частота опроса видна рядом в простом и расширенном видах.
- Для одной подписки или одинаковых интервалов показано одно время. При разных интервалах указаны продукты: например, `Claude 15м · Codex 4ч`. Если обе подписки выключены — «нет подписок».
- Время последнего обновления в Auto доступно в подсказке на «А». При ручном режиме остаётся прежний вид интервалов; значение по умолчанию — 30 минут.
- Алгоритм адаптивного опроса и расписания не меняются.

Linux CI проверяет тесты и сборку DEB на Ubuntu 22.04. Эта правка пока не проверена в живой Astra Linux SE; CI не заменяет такую проверку.

<!--EN-->
- When Auto is on, the A button has a blue-to-violet gradient and shows the current polling interval beside it in both Simple and Advanced views.
- One enabled subscription or equal intervals shows one value. Different intervals name each product, for example `Claude 15m · Codex 4h`. With both subscriptions off, the label reads `no subscriptions`.
- In Auto, the last-update time is available in the A tooltip. Manual mode keeps its interval display and the 30-minute default.
- Adaptive polling rules and schedules are unchanged.

Linux CI runs tests and builds the DEB on Ubuntu 22.04. This change has not yet been tested on a live Astra Linux SE system; CI does not replace that check.
