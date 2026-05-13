#!/usr/bin/env bash
# SessionStart hook — short orientation print on every Claude Code session.
# Always exits 0 (never blocks). Output appears as additional context in
# the agent's first turn.

set +e

cd "${CLAUDE_PROJECT_DIR:-$(pwd)}" 2>/dev/null || exit 0

# Branch + uncommitted count (lightweight, <100ms).
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
UNCOMMITTED=$(git status --porcelain 2>/dev/null | wc -l)
LAST_COMMIT=$(git log -1 --format='%h %s' 2>/dev/null)

# Pull the first ~12 lines of activeContext.md if present — gives the
# current phase / branch / focus without loading the whole memory-bank.
ACTIVE_CTX=""
if [ -f .claude/memory/activeContext.md ]; then
  ACTIVE_CTX=$(head -14 .claude/memory/activeContext.md 2>/dev/null | sed 's/^/    /')
fi

# Lock-file inventory if any (signals work-in-progress from a sibling session).
LOCKS=""
if [ -d tmp/claude-locks ] && [ -n "$(ls -A tmp/claude-locks 2>/dev/null)" ]; then
  LOCKS=$(ls tmp/claude-locks 2>/dev/null | sed 's/^/    /')
fi

cat <<EOF
=== VICTORY62 SESSION ===
  Branch:        $BRANCH
  Uncommitted:   $UNCOMMITTED file(s)
  Last commit:   $LAST_COMMIT

Active context (.claude/memory/activeContext.md head):
$ACTIVE_CTX
EOF

if [ -n "$LOCKS" ]; then
  echo ""
  echo "⚠️  Lock files present (another session may be editing these):"
  echo "$LOCKS"
fi

exit 0
