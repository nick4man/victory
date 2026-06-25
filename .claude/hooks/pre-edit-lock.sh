#!/usr/bin/env bash
# PreToolUse hook for Edit/Write — warn (but never block) when ANY
# Claude Code session has claimed the target file via tmp/claude-locks/.
#
# 04.06.26: cross-worktree aware. Checks tmp/claude-locks/ в **каждом**
# git worktree (через shared .git), не только в current. Это нужно после
# git worktree setup — каждая session работает в своём worktree, lock files
# теперь per-worktree.
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

# Check ALL worktrees через git worktree list. If git unavailable или command
# fails — fallback to legacy single-worktree check.
WORKTREES=$(git worktree list --porcelain 2>/dev/null | awk '/^worktree/ {print $2}')
if [ -z "$WORKTREES" ]; then
  # Legacy path — single worktree
  LOCK_FILE="tmp/claude-locks/${BASENAME}.lock"
  if [ -f "$LOCK_FILE" ]; then
    echo "⚠️  $BASENAME is locked:" >&2
    sed 's/^/    /' "$LOCK_FILE" >&2
    echo "    (see .claude/skills/session-coordination/SKILL.md)" >&2
  fi
  exit 0
fi

# Cross-worktree scan
FOUND=0
for wt in $WORKTREES; do
  LOCK="$wt/tmp/claude-locks/${BASENAME}.lock"
  if [ -f "$LOCK" ]; then
    if [ "$FOUND" -eq 0 ]; then
      echo "⚠️  $BASENAME is locked across worktrees:" >&2
      FOUND=1
    fi
    echo "    [worktree: $wt]" >&2
    sed 's/^/      /' "$LOCK" >&2
  fi
done

[ "$FOUND" -eq 1 ] && echo "    (see .claude/skills/session-coordination/SKILL.md)" >&2

exit 0
