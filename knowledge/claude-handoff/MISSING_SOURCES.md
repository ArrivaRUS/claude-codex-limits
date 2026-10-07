# Недоступная память Claude Code

При предыдущей инвентаризации в этом чате были обнаружены:

- `~/.claude/projects/-home-astra-----------ClaudeCodexLimits/memory/MEMORY.md`;
- `~/.claude/projects/-home-astra-----------ClaudeCodexLimits/memory/project-astra-linux-port.md`;
- `~/.claude/projects/-home-astra-----------ClaudeCodexLimits/memory/astra-machine-quirks.md`;
- `~/.claude/projects/-home-astra-----------ClaudeCodexLimits/baf6e3bd-5d15-4dba-bef4-3a371f958289.jsonl` — сессия за 27–30 сентября 2026 года по ранее прочитанным метаданным.

При сборке пакета Claude Codex Limits 5 октября каталог `/home/astra/.claude` уже отсутствовал. Поиск этих имён файлов в домашнем каталоге и `/tmp`, а также архивов Claude в основных папках документов, загрузок и корзине не нашёл копию. Причина отсутствия не установлена.

Содержимое этих трёх файлов памяти и переписка не восстановлены и не подменены сгенерированными записями. `history/COMMITS.md` — отдельная история Git, не чат. Сохранившаяся проектная память передана в `project/HEARTBEAT.md`, `project/decisions/log.md` и `project/.patches/`.

Если будет найден архив Claude, из него можно дополнить эту базу файлами памяти и очищенной перепиской. Для этого достаточно указать путь к архиву или восстановленному каталогу.
