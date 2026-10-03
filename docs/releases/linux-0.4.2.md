# Linux 0.4.2

<!--RU-->
- Устаревшие показания больше не выдаются за истёкший вход. Карточка Codex с такими данными не показывает `claude login`; возраст данных и ошибка сети сами по себе не доказывают проблему входа.
- Сохранённые проценты остаются видны, расчёт темпа приостановлен. Простой вид предлагает обновить данные; если время чтения неизвестно, расширенный вид показывает «Нет свежих данных · темп не считаем» без выдуманной даты.
- Подсказки восстановления Claude остаются только в карточке Claude при состоянии «вход не выполнен» или «вход истёк». Эта правка не добавляет способ входа Codex и не меняет обновление токенов.

Linux CI использует Ubuntu 22.04 для тестов и сборки DEB. Эта правка пока не проверена на живой Astra Linux SE. Linux-релиз не получает пометку Latest.

<!--EN-->
- Stale readings are no longer presented as expired sign-in. A stale Codex card does not show `claude login`; reading age and a network error alone do not prove a sign-in problem.
- Cached percentages remain visible and pace calculation pauses. Simple view suggests refreshing data; when the reading time is unknown, Advanced view shows “No fresh data · pace paused” without inventing a date.
- Claude recovery hints remain limited to the Claude card when its sign-in state is logged out or expired. This change does not add a Codex sign-in flow or change token refresh.

Linux CI uses Ubuntu 22.04 for tests and DEB packaging. This change has not yet been tested on a live Astra Linux SE system. The Linux release is not marked Latest.
