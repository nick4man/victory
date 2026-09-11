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

# Session identity: CLAUDE_SESSION env wins; else per-worktree .claude-session
# marker file (the durable source of truth — a hook subprocess can't export env
# back to the session, so each worktree self-identifies via its marker).
MARKER_SESSION=$(cat .claude-session 2>/dev/null || echo "")
SESSION_ID="${CLAUDE_SESSION:-${MARKER_SESSION:-unknown}}"
WORKTREE_PATH=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

# Main checkout — вычисляем, а не хардкодим: репозиторий живёт на двух хостах с
# разными корнями. `--git-common-dir` даёт `<main checkout>/.git` (в самом main
# checkout — относительный `.git`), значит родитель и есть main checkout.
# Нужен и для inbox-очереди (ниже), и для предупреждений про прод-bind-mount.
GIT_COMMON=$(git rev-parse --git-common-dir 2>/dev/null)
MAIN_CHECKOUT=""
[ -n "$GIT_COMMON" ] && MAIN_CHECKOUT=$(cd "$GIT_COMMON/.." 2>/dev/null && pwd)
[ -n "$MAIN_CHECKOUT" ] || MAIN_CHECKOUT="$WORKTREE_PATH"
# Все worktree — соседи main checkout, поэтому подсказки строим от его родителя.
WORKTREES_ROOT=$(dirname "$MAIN_CHECKOUT")

# git-хуки живут в .git/hooks, который под git не попадает — доставляем из
# отслеживаемого .githooks/. Вызов идемпотентный (symlink уже на месте → no-op),
# поэтому дёргаем на каждом старте вместо ручного шага при клонировании.
# Нужен для post-commit: он снимает claude-локи с закоммиченных файлов.
[ -x bin/install-git-hooks ] && bin/install-git-hooks >/dev/null 2>&1

# Pull the first ~12 lines of activeContext.md if present — gives the
# current phase / branch / focus without loading the whole memory-bank.
ACTIVE_CTX=""
if [ -f .claude/memory/activeContext.md ]; then
  ACTIVE_CTX=$(head -14 .claude/memory/activeContext.md 2>/dev/null | sed 's/^/    /')
fi

# Lock-file inventory + stale detection (empty OR > 2h old).
#
# 08.08.26: сканируем ВСЕ worktree, а не только свой. Локи теперь ставятся
# автоматически и блокируют правку, поэтому на старте важнее всего знать, что
# держат СОСЕДНИЕ сессии — свои локи и так не мешают. Имена декодируем из
# %-ключа обратно в путь.
LOCKS_ACTIVE=""
LOCKS_STALE=""
if [ -r .claude/hooks/lib/locks.sh ]; then
  . .claude/hooks/lib/locks.sh
  ME_SESSION=$(lock_session "$WORKTREE_PATH")
  for wt in $(lock_worktrees); do
    while IFS= read -r lock; do
      [ -n "$lock" ] || continue
      path=$(lock_key_to_path "$(basename "$lock")")
      owner=$(lock_meta "$lock" session)
      size=$(stat -c%s "$lock" 2>/dev/null || echo 0)
      age_min=$(lock_age_minutes "$lock" 2>/dev/null || echo 0)
      mark=''
      [ "$owner" = "$ME_SESSION" ] && mark=' (свой)'

      if [ "$size" -eq 0 ]; then
        LOCKS_STALE="${LOCKS_STALE}    ⚠️  ${path} — пустой, без метаданных
"
      elif lock_is_stale "$lock"; then
        LOCKS_STALE="${LOCKS_STALE}    ⚠️  ${path} — ${owner}, $((age_min / 60))ч без активности
"
      else
        LOCKS_ACTIVE="${LOCKS_ACTIVE}    ${path} — ${owner}${mark}, $((age_min)) мин
"
      fi
    done < <(lock_files "$wt")
  done
fi

# Inbox scan — only if CLAUDE_SESSION is set and valid.
# The queue lives in the MAIN checkout (parent of --git-common-dir), not in this
# worktree: each worktree has its own .claude/ on disk and inbox/**/*.md is
# gitignored, so a relative path would read an inbox no sender can write to.
INBOX_TOTAL=0
INBOX_HEADLINES=""
INBOX_DIR="$MAIN_CHECKOUT/.claude/sessions/inbox/$SESSION_ID"
if [ "$SESSION_ID" != "unknown" ] && [ -d "$INBOX_DIR" ]; then
  # Total count (top-level *.md only, not archive/).
  INBOX_TOTAL=$(find "$INBOX_DIR" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l)
  if [ "$INBOX_TOTAL" -gt 0 ]; then
    # First 3 messages by mtime (oldest first — FIFO).
    while IFS= read -r msg; do
      [ -z "$msg" ] && continue
      mname=$(basename "$msg" .md)
      mfrom=$(grep '^from:' "$msg" 2>/dev/null | head -1 | sed 's/from: *//')
      mprio=$(grep '^priority:' "$msg" 2>/dev/null | head -1 | sed 's/priority: *//')
      # First non-empty line after the second `---` (body start).
      mpreview=$(awk '/^---$/{n++; next} n==2' "$msg" 2>/dev/null | sed '/^$/d' | head -1 | head -c 70)
      INBOX_HEADLINES="${INBOX_HEADLINES}    [${mname}] from ${mfrom} (${mprio})
      ${mpreview}
"
    done < <(ls -1tr "$INBOX_DIR"/*.md 2>/dev/null | head -3)
  fi
fi

# KPI cache snapshot (refreshed manually via `bundle exec rake kpi:phase_a > .claude/sessions/kpi-cache.txt`).
KPI_SECTION=""
KPI_CACHE=".claude/sessions/kpi-cache.txt"
if [ -f "$KPI_CACHE" ]; then
  KPI_MTIME=$(stat -c%Y "$KPI_CACHE" 2>/dev/null || echo 0)
  KPI_AGE_HOURS=$(( ($(date +%s) - KPI_MTIME) / 3600 ))
  KPI_BODY=$(cat "$KPI_CACHE" 2>/dev/null | sed 's/^/    /')
  if [ "$KPI_AGE_HOURS" -ge 24 ]; then
    KPI_SECTION="
=== KPI (Phase A) — ⚠️ cache stale (${KPI_AGE_HOURS}h old; refresh: \`bundle exec rake kpi:phase_a > $KPI_CACHE\`) ===
${KPI_BODY}"
  else
    KPI_SECTION="
=== KPI (Phase A) — ${KPI_AGE_HOURS}h ago ===
${KPI_BODY}"
  fi
fi

# Состояние прода.
#
# Мерж в main и выкатка — независимые события: деплой ручной. Поэтому «в main»
# и «на сайте» расходятся молча, и 07.09.26 расхождение дошло до 33 коммитов
# незамеченным. Источник правды — ветка `prod`, её двигает bin/prod-mark после
# деплоя. Обновляем refs здесь же: .git у всех worktree общий, так что одного
# fetch хватает на все сессии, а чаще раза в 5 минут в сеть не ходим.
PROD_BLOCK=""
if [ -r .claude/hooks/lib/prod-state.sh ]; then
  . .claude/hooks/lib/prod-state.sh
  prod_fetch_if_stale

  P_SHA=$(prod_sha)
  if [ -z "$P_SHA" ]; then
    PROD_BLOCK="
=== ПРОД ===
  Отметки о деплое нет (ветки origin/prod не существует).
  Пока её нет, отличить «лежит в main» от «работает на сайте» неоткуда.
  Поставить — bin/prod-mark на прод-хосте, последним шагом деплоя."
  else
    P_AHEAD=$(prod_commits_ahead "$P_SHA")
    P_LOCAL=$(prod_local_sha)
    PROD_BLOCK="
=== ПРОД ===
  Выкачено:     $(prod_describe "$P_SHA")"

    if [ -n "$P_AHEAD" ] && [ "$P_AHEAD" -gt 0 ] 2>/dev/null; then
      PROD_BLOCK="${PROD_BLOCK}
  Ждёт деплоя:  $P_AHEAD коммит(ов) в main"
    fi

    B_BEHIND=$(prod_branch_behind_main)
    if [ -n "$B_BEHIND" ] && [ "$B_BEHIND" -gt 0 ] 2>/dev/null; then
      PROD_BLOCK="${PROD_BLOCK}
  Твоя ветка:   отстаёт от main на $B_BEHIND"
    fi

    # Отметка ставится руками, поэтому её можно забыть. На прод-хосте это
    # видно сразу — сверяем с реальным чекаутом.
    if [ -n "$P_LOCAL" ] && [ "$P_LOCAL" != "$P_SHA" ]; then
      PROD_BLOCK="${PROD_BLOCK}
  ⚠️  Отметка врёт: в прод-чекауте ${P_LOCAL:0:7}, а origin/prod указывает на ${P_SHA:0:7}.
      Похоже, выкатили и не запустили bin/prod-mark."
    fi
  fi
fi

cat <<EOF
=== VICTORY62 SESSION ===
  Session:       $SESSION_ID
  Worktree:      $WORKTREE_PATH
  Branch:        $BRANCH
  Uncommitted:   $UNCOMMITTED file(s)
  Last commit:   $LAST_COMMIT

Active context (.claude/memory/activeContext.md head):
$ACTIVE_CTX
EOF

[ -n "$PROD_BLOCK" ] && printf '%s\n' "$PROD_BLOCK"

# Session identity / worktree guards
if [ "$SESSION_ID" = "main" ]; then
  cat <<WARN

🚨  MAIN CHECKOUT ($MAIN_CHECKOUT) — this is the LIVE-PROD bind-mount
   (victory-web-1 mounts it at /app in RAILS_ENV=development with code-reload,
   so edits here hit the live site instantly). Reserved for deploy/merge ONLY —
   do NOT do active development here. Work in your session worktree
   ($WORKTREES_ROOT/victory-<session>). See .claude/sessions/README.md
WARN
elif [ "$SESSION_ID" = "unknown" ]; then
  cat <<'WARN'

⚠️  Session identity not set — no .claude-session marker and CLAUDE_SESSION unset.
   Each worktree carries a .claude-session file (victory|chat|seo|upgrade); if
   missing, `echo <session> > .claude-session` or export CLAUDE_SESSION. Inbox +
   per-session routing stay disabled until set. See .claude/sessions/README.md
WARN
fi

# Mismatch guard: env says one session but the worktree marker says another →
# almost certainly launched in the wrong worktree.
if [ -n "$CLAUDE_SESSION" ] && [ -n "$MARKER_SESSION" ] && [ "$CLAUDE_SESSION" != "$MARKER_SESSION" ]; then
  cat <<WARN

⚠️  SESSION/WORKTREE MISMATCH: CLAUDE_SESSION=$CLAUDE_SESSION but this worktree's
   marker is '$MARKER_SESSION' ($WORKTREE_PATH). You may have launched the
   '$CLAUDE_SESSION' session in the wrong worktree. Expected: $WORKTREES_ROOT/victory-$CLAUDE_SESSION
WARN
fi

# Inbox notification
if [ "$INBOX_TOTAL" -gt 0 ]; then
  cat <<EOF

=== 📬 INBOX ($INBOX_TOTAL pending for $SESSION_ID) ===
$INBOX_HEADLINES   Use \`bin/claude-inbox list\` / \`bin/claude-inbox read <id>\` / \`bin/claude-inbox done <id>\`
EOF
fi

# Stale lock warning
if [ -n "$LOCKS_STALE" ]; then
  cat <<EOF

⚠️  Протухшие локи (пустые или > 2ч без активности):
$LOCKS_STALE   Снять: \`bin/lock-clean --all --force\` (или сами уйдут при первой правке).
EOF
fi

# Active locks (informational)
if [ -n "$LOCKS_ACTIVE" ]; then
  cat <<EOF

🔒 Активные локи (правка чужих — будет заблокирована):
$LOCKS_ACTIVE   Снять конкретный: \`bin/lock-clean --release <путь>\` | обойти: CLAUDE_LOCK_BYPASS=1
EOF
fi

# Наблюдатель — только в victory: он там живёт.
# Показываем не саму сводку (её собирает агент), а поводы его позвать.
if [ "$SESSION_ID" = "victory" ]; then
  CONFLICTS_FILE="${CLAUDE_SHARED_DIR:-$HOME/.claude-shared}/events/conflicts.jsonl"
  CONFLICTS_24H=0
  if [ -f "$CONFLICTS_FILE" ]; then
    CUTOFF=$(date -d '24 hours ago' -Iseconds 2>/dev/null || echo '')
    if [ -n "$CUTOFF" ]; then
      CONFLICTS_24H=$(awk -v c="$CUTOFF" -F'"' '$4 > c' "$CONFLICTS_FILE" 2>/dev/null | wc -l)
    fi
  fi

  # Чужие сессии с незапушенной работой — главный повод свести их между собой.
  OTHERS_AHEAD=$(bin/session-status --porcelain 2>/dev/null \
    | awk -F'\t' '$1 != "victory" && $1 != "main" && $4 != "-" && $4 > 0 {n++} END {print n+0}')

  if [ "$CONFLICTS_24H" -gt 0 ] || [ "${OTHERS_AHEAD:-0}" -gt 0 ]; then
    cat <<EOF

=== 👁  НАБЛЮДАТЕЛЬ ===
  Конфликтов локов за сутки: $CONFLICTS_24H
  Сессий с незапушенной работой: ${OTHERS_AHEAD:-0}
  Свести картину: агент \`session-observer\` | снимок: \`bin/session-status\`
  Полномочия ролей: .claude/docs/session-authority.md
EOF
  fi
fi

# KPI block
if [ -n "$KPI_SECTION" ]; then
  printf '%s\n' "$KPI_SECTION"
fi

cat <<'ROUTING'

=== ROUTING (full map: .claude/docs/delegation-map.md) ===
  topnlab / МЛС sync / миграция CRM   → topnlab-api-expert
  TG staff bot / escalation / inbox   → telegram-staff-bot-dev
  чат-бот сайта / chat_tools / LLM    → site-chatbot-dev
  SEO / JSON-LD / meta / sitemap      → seo-content-curator (+ victory-seo-checklist)
  property valuation / CMA            → property-valuation-expert
  Prawn PDF / audit_pdf / кириллица   → pdf-report-designer
  markdown → PDF → TG group           → pdf-telegram-dispatcher
  рефакторинг / fat model / concerns  → rails-architect
  код-ревью / before merge / PR check → code-reviewer
  RSpec / тесты legacy / factory      → test-bootstrapper (+ rspec-bootstrap)
  parallel session / lock / hand-off  → session-coordinator (+ session-coordination)
  context handoff between sessions    → skill: session-handoff-protocol
  client docs (паспорт/ИНН) через TG  → client-onboarding-bot
  weekly market digest / district     → market-analytics-publisher
  post-deal кейс / /cases / видео     → case-study-writer
  VDS Traefik / CrowdSec / роутеры    → traefik-vds-ops (+ traefik-config-authoring, crowdsec-policy-management)
  Nextcloud / rclone / nxt: / Офис    → nextcloud-rclone-ops (+ rclone-nextcloud-patterns)
  Yandex.Webmaster / ИКС / recrawl    → yandex-webmaster-seo-ops (+ yandex-webmaster-api-patterns)
  Figma → ERB+Tailwind                → skill: figma-to-erb-handoff
  enums/soft-del/dd.MM.yy conventions → skill: victory-rails-conventions
  user-facing русский копирайт        → skill: russian-real-estate-copywriting

  Strategic vector (24mo): .claude/memory/strategicVector.md
  Master plan: .claude/plans/_shared/splendid-imagining-lerdorf.md
  Inter-session: .claude/sessions/README.md
  VDS infra cheatsheet: .claude/docs/vds-infra-cheatsheet.md
  Nextcloud cheatsheet: .claude/docs/nextcloud-cheatsheet.md

  NO delegation for: trivial fixes, simple code questions, git status, contextual continuations.
ROUTING

exit 0
