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
  RSpec / тесты legacy / factory      → test-bootstrapper (+ rspec-bootstrap)
  parallel session / lock / hand-off  → session-coordinator (+ session-coordination)
  client docs (паспорт/ИНН) через TG  → client-onboarding-bot
  weekly market digest / district     → market-analytics-publisher
  post-deal кейс / /cases / видео     → case-study-writer
  Figma → ERB+Tailwind                → skill: figma-to-erb-handoff
  enums/soft-del/dd.MM.yy conventions → skill: victory-rails-conventions
  user-facing русский копирайт        → skill: russian-real-estate-copywriting

  Strategic vector (24mo): .claude/memory/strategicVector.md
  Master plan: .claude/plans/splendid-imagining-lerdorf.md

  NO delegation for: trivial fixes, simple code questions, git status, contextual continuations.
ROUTING

exit 0
