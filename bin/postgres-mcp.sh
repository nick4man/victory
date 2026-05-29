#!/usr/bin/env bash
# postgres-mcp.sh — MCP postgres server wrapper.
# Reads DATABASE_URL from project .env, runs the official server inside
# the docker network where the `db` service is reachable.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Extract only DATABASE_URL from .env (avoids parsing the whole file,
# which contains values with bash-unfriendly characters like parens).
DATABASE_URL="${DATABASE_URL:-$(grep -E '^DATABASE_URL=' "$PROJECT_DIR/.env" 2>/dev/null | head -1 | cut -d= -f2-)}"

if [ -z "${DATABASE_URL:-}" ]; then
  echo "postgres-mcp: DATABASE_URL not set (expected in .env or environment)" >&2
  exit 1
fi

# Force read-only mode by appending options when missing. The official
# @modelcontextprotocol/server-postgres is read-only by default, so just pass
# the URL through. The container needs the victory_default network to resolve
# the `db` hostname.
exec docker run -i --rm \
  --network=victory_default \
  -e "DATABASE_URL=${DATABASE_URL}" \
  node:20-alpine \
  sh -c 'npx -y @modelcontextprotocol/server-postgres "$DATABASE_URL"'
