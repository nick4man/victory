#!/usr/bin/env bash
# PreToolUse hook для Edit/Write — БЛОКИРУЕТ правку файла, занятого другой
# Claude-сессией.
#
# 08.08.26: раньше хук только предупреждал (всегда exit 0) и полагался на
# ручную постановку локов — за два месяца не создано ни одного лока, то есть
# защиты не было вообще. Теперь локи ставятся автоматически
# (post-edit-lock.sh), а этот хук на них реально опирается.
#
# Exit 2 = Claude Code отменяет вызов инструмента и отдаёт stderr модели.
# Любой сбой самого хука — exit 0: сломанная координация не должна
# останавливать работу.
#
# Аварийный обход: CLAUDE_LOCK_BYPASS=1

set +e

ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
cd "$ROOT" 2>/dev/null || exit 0

# shellcheck source=lib/locks.sh
. "$ROOT/.claude/hooks/lib/locks.sh" 2>/dev/null || exit 0

[ -n "${CLAUDE_LOCK_BYPASS:-}" ] && exit 0

INPUT=$(cat)

FILE=""
if command -v jq >/dev/null 2>&1; then
  FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null)
else
  FILE=$(echo "$INPUT" | grep -oE '"file_path"[[:space:]]*:[[:space:]]*"[^"]+"' | sed -E 's/.*"file_path"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' | head -1)
fi

[ -z "$FILE" ] && exit 0

ROOT=$(lock_root)
KEY=$(lock_key "$FILE" "$ROOT") || exit 0   # вне репо — не наше дело
ME=$(lock_session "$ROOT")

for wt in $(lock_worktrees); do
  LOCK="$wt/tmp/claude-locks/$KEY"
  [ -f "$LOCK" ] || continue

  OWNER=$(lock_meta "$LOCK" session)
  [ "$OWNER" = "$ME" ] && continue          # свой лок не мешает

  # Протухший лок снимаем сами: сессия могла упасть, не сняв его. Без этого
  # блокирующий хук превращается в дедлок.
  if lock_is_stale "$LOCK"; then
    rm -f "$LOCK" 2>/dev/null
    echo "ℹ️  Снят протухший лок $(lock_key_to_path "$KEY") (сессия $OWNER, старше ${LOCK_TTL_HOURS}ч)." >&2
    continue
  fi

  AGE=$(lock_age_minutes "$LOCK")
  TASK=$(lock_meta "$LOCK" task)
  STARTED=$(lock_meta "$LOCK" started)

  REL=$(lock_key_to_path "$KEY")

  # След для наблюдателя: повторяющиеся отказы по одному пути означают, что
  # границы доменов размыты и нужен арбитраж, а не очередной обход. Хук агентов
  # не зовёт — он только оставляет запись, которую session-observer читает.
  EVENTS_DIR="${CLAUDE_SHARED_DIR:-$HOME/.claude-shared}/events"
  if mkdir -p "$EVENTS_DIR" 2>/dev/null; then
    printf '{"at":"%s","path":"%s","blocked":"%s","holder":"%s","task":"%s"}\n' \
      "$(date -Iseconds)" "$REL" "$ME" "${OWNER:-?}" "${TASK:-?}" \
      >> "$EVENTS_DIR/conflicts.jsonl" 2>/dev/null
  fi

  {
    echo "⛔ $REL занят сессией ${OWNER:-?}"
    echo "   worktree: $wt"
    echo "   с ${STARTED:-?} (${AGE:-?} мин назад)${TASK:+, task=$TASK}"
    echo "   Снять: bin/lock-clean --release $REL"
    echo "   Обойти разово: CLAUDE_LOCK_BYPASS=1"
    echo "   Согласуй с той сессией: живой — SendMessage, оффлайн — bin/claude-inbox send."
    echo "   Повторяется по одному пути — это спор о границах: эскалируй наблюдателю в victory."
  } >&2

  exit 2
done

exit 0
