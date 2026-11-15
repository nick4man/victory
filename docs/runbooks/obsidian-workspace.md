# Obsidian-воркспейс управления проектом

Дата последней проверки: 08.11.26

Пульт управления проектом в Obsidian — приватный репозиторий
`nick4man/obsidian-dev-workspace` (вне victory, свой модуль с нуля).
Даёт из коробки:

- управление GitHub-репозиторием (PR, issues, actions) — через MCP-сервер
  `github` (тот же `.mcp.json`-подход, что и в victory), без отдельных плагинов;
- SSH до хостов алиасами (`victory` — прод, `vps1` — staging/bastion) —
  секреты и FQDN только локально, в коммитах модуля их нет;
- интеграцию с hermes-agent: доска `victory`, `hermes cron list`,
  `bin/claude-inbox`;
- связи с источниками правды victory (`AGENTS.md`, `docs/runbooks/`,
  `.claude/memory/`) — симлинками, без дублирования.

Подробности, плагины и порядок подключения — в README и QUICKSTART модуля,
best practices — в заметке `10-brief/Best practices` (cookbook, не скриншоты).

Изменения в модуле — PR в его репозиторий; этот runbook — только указатель,
дублировать содержимое vault сюда не нужно.
