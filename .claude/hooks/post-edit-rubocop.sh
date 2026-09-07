#!/usr/bin/env bash
# PostToolUse hook for Edit/Write — silently run `rubocop -a` on edited .rb
# files in the background. Does NOT block (always exits 0). Stderr only on
# fatal errors; auto-corrections are applied transparently.
#
# 08.08.26: раньше звал `bundle exec rubocop` напрямую. На хосте нет менеджера
# версий Ruby (системный ruby не совпадает с пином в Gemfile), поэтому вызов
# молча падал и автокоррекция не работала ни в одной сессии. Теперь идём через
# bin/rb — контейнер с целевым Ruby. Если bin/rb нет (старый checkout) —
# тихо выходим, как и раньше.

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
    [ -x bin/rb ] || exit 0
    # Best-effort autocorrect in background. The whole pipeline cannot
    # afford to wait — `&` + nohup detaches.
    (
      nohup bin/rb bundle exec rubocop -a --force-exclusion "$FILE" >/dev/null 2>&1 &
    ) 2>/dev/null
    ;;
  *)
    exit 0
    ;;
esac

exit 0
