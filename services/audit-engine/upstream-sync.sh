#!/usr/bin/env bash
# Re-pulls vendored audit-engine + stack + API contract from chat-server.
#
# Run from anywhere inside the victory62 repo. Idempotent. Requires SSH
# access to the `chat` alias (configured in ~/.ssh/config).
#
# After running, review the diff with:
#   git diff --stat services/audit-engine/
# and commit if the changes are intentional.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SSH_HOST="${AUDIT_SYNC_SSH_HOST:-chat}"

cd "$SCRIPT_DIR"

echo "→ Syncing engine source from $SSH_HOST:~/.openclaw/workspace-it-dept/audit-engine-v2/"
mkdir -p engine
ssh "$SSH_HOST" 'tar czf - -C .openclaw/workspace-it-dept/audit-engine-v2 \
  --exclude="__pycache__" --exclude="*.pyc" --exclude="*.egg-info" \
  --exclude=".pytest_cache" --exclude="RUNBOOK_SECRETS.md" \
  --exclude=".venv" --exclude="venv" .' \
  | tar xzf - -C engine/

echo "→ Syncing devops stack from $SSH_HOST:~/.openclaw/workspace-it-dept/devops/audit-v2-stack/"
mkdir -p stack
ssh "$SSH_HOST" 'tar czf - -C .openclaw/workspace-it-dept/devops/audit-v2-stack \
  --exclude="__pycache__" --exclude="*.pyc" .' \
  | tar xzf - -C stack/

echo "→ Refreshing API contract SKILL.md"
ssh "$SSH_HOST" 'cat .openclaw/skills/audit-engine-v2-api/SKILL.md' \
  > SKILL_API_CONTRACT.md

echo
echo "✔ Vendoring complete. Diff vs HEAD:"
git -C "$REPO_ROOT" diff --stat services/audit-engine/ | tail -40 || true

echo
echo "Next steps:"
echo "  1. Review diff:    git -C $REPO_ROOT diff services/audit-engine/"
echo "  2. Re-build image: docker compose -f docker-compose.yml -f docker-compose.audit.yml build audit-api"
echo "  3. Smoke-test:     docker compose -f docker-compose.audit.yml exec audit-api curl -sf localhost:8000/api/v2/health"
echo "  4. Commit:         git add services/audit-engine/ && git commit"
