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
    for lock in "$wt"/tmp/claude-locks/*.lock; do
      [ -e "$lock" ] || continue
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
    done
  done
fi

# Inbox scan — only if CLAUDE_SESSION is set and valid.
INBOX_TOTAL=0
INBOX_HEADLINES=""
INBOX_DIR=".claude/sessions/inbox/$SESSION_ID"
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

# Session identity / worktree guards
if [ "$SESSION_ID" = "main" ]; then
  cat <<'WARN'

🚨  MAIN CHECKOUT (/home/q/victory) — this is the LIVE-PROD bind-mount
   (victory-web-1 mounts it at /app in RAILS_ENV=development with code-reload,
   so edits here hit the live site instantly). Reserved for deploy/merge ONLY —
   do NOT do active development here. Work in your session worktree
   (/home/q/victory-<session>). See .claude/sessions/README.md
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
   '$CLAUDE_SESSION' session in the wrong worktree. Expected: /home/q/victory-$CLAUDE_SESSION
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
