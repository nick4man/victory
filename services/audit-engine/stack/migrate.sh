#!/bin/bash
echo "🔄 Running Alembic migrations..."
docker compose exec api alembic upgrade head
echo "✅ Migrations applied"
