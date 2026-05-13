#!/usr/bin/env bash
# PostToolUse hook for Edit/Write — silently run `rubocop -a` on edited .rb
# files in the background. Does NOT block (always exits 0). Stderr only on
# fatal errors; auto-corrections are applied transparently.
#
# Requires rubocop in the bundle (added by Phase 3.2). Skips silently if
# bundle/rubocop not available or wrong Ruby version.

set +e

cd "${CLAUDE_PROJECT_DIR:-$(pwd)}" 2>/dev/null || exit 0

INPUT=$(cat)

FILE=""
if command -v jq >/dev/null 2>&1; then
  FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
else
  FILE=$(echo "$INPUT" | grep -oE '"file_path"[[:space:]]*:[[:space:]]*"[^"]+"' | sed -E 's/.*"file_path"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' | head -1)
fi

case "$FILE" in
  *.rb|*.rake|*.ru)
    # Best-effort autocorrect in background. The whole pipeline cannot
    # afford to wait — `&` + nohup detaches.
    (
      nohup bundle exec rubocop -a --force-exclusion "$FILE" >/dev/null 2>&1 &
    ) 2>/dev/null
    ;;
  *)
    exit 0
    ;;
esac

exit 0
