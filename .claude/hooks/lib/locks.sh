#!/usr/bin/env bash
# Общая логика claude-локов. Подключается через `source`.
#
# Локи живут в `<worktree>/tmp/claude-locks/`. Каталог per-worktree (после
# перехода на worktree-per-session tmp/ больше не общий), поэтому проверка
# «занят ли файл» всегда обходит ВСЕ worktree через общий .git.
#
# Ключ лока — repo-relative путь, где `/` заменён на `%`:
#
#     app/models/property.rb  →  app%models%property.rb.lock
#
# Именно путь, а не basename: в репо 35 совпадающих имён (base.rb, client.rb,
# _form.html.erb…). Пока хук только предупреждал, ложное совпадение было шумом;
# с блокирующим хуком оно бы запрещало правку невиновного файла.

LOCK_TTL_HOURS="${LOCK_TTL_HOURS:-2}"

# Корень текущего worktree.
lock_root() {
  git rev-parse --show-toplevel 2>/dev/null || echo "${CLAUDE_PROJECT_DIR:-$PWD}"
}

# Идентичность сессии: env-override, затем marker-файл, затем имя каталога.
# Тот же порядок, что в .claude/hooks/session-start.sh.
lock_session() {
  local root="${1:-$(lock_root)}"
  if [ -n "${CLAUDE_SESSION:-}" ]; then
    echo "$CLAUDE_SESSION"
    return
  fi
  local marker
  marker=$(cat "$root/.claude-session" 2>/dev/null)
  if [ -n "$marker" ]; then
    echo "$marker"
    return
  fi
  basename "$root" | sed 's/^victory-//'
}

# Путь (абсолютный или относительный) → ключ лока. Пустая строка, если файл
# вне репозитория: такие пути не лочим вовсе (иначе хук заблокировал бы правку
# plan-файла в ~/.claude/plans/).
lock_key() {
  local file="$1" root="${2:-$(lock_root)}" rel

  case "$file" in
    /*) rel="${file#"$root"/}"
        # Не отрезалось — значит файл вне worktree.
        [ "$rel" = "$file" ] && return 1
        ;;
    *)  rel="$file" ;;
  esac

  # ../ наружу — тоже вне репо.
  case "$rel" in ../*) return 1 ;; esac

  printf '%s.lock' "${rel//\//%}"
}

# Ключ → читаемый путь (обратная замена, для сообщений).
lock_key_to_path() {
  local key="${1%.lock}"
  printf '%s' "${key//%//}"
}

# Значение поля из lock-файла: lock_meta <file> <field>
lock_meta() {
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1
}

# Возраст файла в минутах.
lock_age_minutes() {
  local mtime now
  mtime=$(stat -c %Y "$1" 2>/dev/null) || return 1
  now=$(date +%s)
  echo $(( (now - mtime) / 60 ))
}

# Протух ли лок (старше LOCK_TTL_HOURS).
lock_is_stale() {
  local age
  age=$(lock_age_minutes "$1") || return 0
  [ "$age" -gt $(( LOCK_TTL_HOURS * 60 )) ]
}

# Все worktree репозитория.
lock_worktrees() {
  git worktree list --porcelain 2>/dev/null | awk '/^worktree /{print $2}'
}
