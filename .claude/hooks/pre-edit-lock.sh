#!/usr/bin/env bash
# PreToolUse hook for Edit/Write — warn (but never block) when a sibling
# Claude Code session has claimed the target file via tmp/claude-locks/.
#
# Reads JSON from stdin (Claude Code's standard hook payload).
# Exits 0 always; failures here must not interfere with editing.

set +e

cd "${CLAUDE_PROJECT_DIR:-$(pwd)}" 2>/dev/null || exit 0

INPUT=$(cat)

# Parse file_path from the tool input — try jq, fall back to grep.
FILE=""
if command -v jq >/dev/null 2>&1; then
  FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null)
else
  FILE=$(echo "$INPUT" | grep -oE '"file_path"[[:space:]]*:[[:space:]]*"[^"]+"' | sed -E 's/.*"file_path"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' | head -1)
fi

[ -z "$FILE" ] && exit 0

BASENAME=$(basename "$FILE")
LOCK_FILE="tmp/claude-locks/${BASENAME}.lock"

if [ -f "$LOCK_FILE" ]; then
  echo "⚠️  $BASENAME is locked by another session:" >&2
  sed 's/^/    /' "$LOCK_FILE" >&2
  echo "    (see .claude/skills/session-coordination/SKILL.md)" >&2
fi

exit 0
