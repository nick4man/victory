#!/usr/bin/env bash
# PostToolUse hook для Edit/Write — ставит лок на только что изменённый файл.
#
# Это ядро координации: пока постановка была ручной («перед крупной правкой
# создай lock-файл»), её не делали — 0 локов за два месяца. Автоматическая
# постановка не требует от сессии ничего, поэтому работает.
#
# Повторная правка того же файла обновляет mtime — TTL считается от последнего
# касания, а не от первого. Активно правишь — лок живёт; ушёл — протухает.
#
# Всегда exit 0.

set +e

ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
cd "$ROOT" 2>/dev/null || exit 0

# shellcheck source=lib/locks.sh
. "$ROOT/.claude/hooks/lib/locks.sh" 2>/dev/null || exit 0

INPUT=$(cat)

FILE=""
if command -v jq >/dev/null 2>&1; then
  FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null)
else
  FILE=$(echo "$INPUT" | grep -oE '"file_path"[[:space:]]*:[[:space:]]*"[^"]+"' | sed -E 's/.*"file_path"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' | head -1)
fi

[ -z "$FILE" ] && exit 0

ROOT=$(lock_root)
KEY=$(lock_key "$FILE" "$ROOT") || exit 0   # вне репо не лочим
LOCK_DIR="$ROOT/tmp/claude-locks"
LOCK="$LOCK_DIR/$KEY"

mkdir -p "$LOCK_DIR" 2>/dev/null || exit 0

# Лок уже наш — просто продлеваем.
if [ -f "$LOCK" ] && [ "$(lock_meta "$LOCK" session)" = "$(lock_session "$ROOT")" ]; then
  touch "$LOCK" 2>/dev/null
  exit 0
fi

# Даты — dd.MM.yy по конвенции проекта.
{
  echo "session=$(lock_session "$ROOT")"
  echo "worktree=$ROOT"
  echo "path=$(lock_key_to_path "$KEY")"
  echo "started=$(date '+%d.%m.%y %H:%M')"
  echo "pid=$$"
  echo "task=${CLAUDE_LOCK_TASK:-edit}"
} > "$LOCK" 2>/dev/null

exit 0
