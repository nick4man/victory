#!/usr/bin/env bash
# PostToolUse hook для Edit/Write — зеркалит plan-файлы из глобального буфера
# harness'а в per-session каталог репозитория.
#
# Проблема: Claude Code пишет план сессии в ~/.claude/plans/ — один плоский
# каталог на все сессии и все проекты хоста. Четыре сессии victory62 писали
# туда одновременно и затирали друг друга; там же лежали мастер-документы.
#
# Путь глобального буфера мы не контролируем, поэтому не боремся с ним, а
# зеркалим: ~/.claude/plans/<name>.md → .claude/plans/<session>/<name>.md.
# Копия попадает в git — появляется история, review в PR и переживаемость.
#
# Мастер-документы живут в .claude/plans/_shared/ и меняются только через PR;
# этот хук туда никогда не пишет.
#
# Всегда exit 0: сбой синхронизации плана не должен ломать сессию.

set +e

ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
cd "$ROOT" 2>/dev/null || exit 0

# shellcheck source=lib/locks.sh
. "$ROOT/.claude/hooks/lib/locks.sh" 2>/dev/null || exit 0

INPUT=$(cat)

FILE=""
if command -v jq >/dev/null 2>&1; then
  FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
else
  FILE=$(echo "$INPUT" | grep -oE '"file_path"[[:space:]]*:[[:space:]]*"[^"]+"' | sed -E 's/.*"file_path"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' | head -1)
fi

[ -z "$FILE" ] && exit 0

PLANS_BUF="${HOME}/.claude/plans"

# Интересуют только .md прямо в глобальном буфере.
case "$FILE" in
  "$PLANS_BUF"/*.md) ;;
  *) exit 0 ;;
esac

[ -f "$FILE" ] || exit 0

SESSION=$(lock_session "$ROOT")
DEST_DIR="$ROOT/.claude/plans/$SESSION"

mkdir -p "$DEST_DIR" 2>/dev/null || exit 0
cp -f "$FILE" "$DEST_DIR/$(basename "$FILE")" 2>/dev/null

exit 0
