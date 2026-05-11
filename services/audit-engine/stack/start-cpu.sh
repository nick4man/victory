#!/bin/bash
# Запуск audit-v2-stack в CPU-режиме (без NVIDIA-драйверов).
# Подробности: docker-compose.cpu.yml, RUNBOOK.md §7.4.
set -e

echo "🚀 Starting Audit Engine v2.0 stack (CPU mode)..."

if lsof -i :5433 >/dev/null 2>&1; then
  echo "❌ Port 5433 is already in use!"
  exit 1
fi

docker compose -f docker-compose.yml -f docker-compose.cpu.yml up -d --build

echo "⏳ Waiting for services..."
sleep 5

docker compose -f docker-compose.yml -f docker-compose.cpu.yml ps
echo ""
echo "✅ Stack is running in CPU mode!"
echo "   API:        http://localhost:8100"
echo "   PostgreSQL: localhost:5433"
echo "   Redis:      localhost:6379"
echo ""
echo "   Health: curl http://localhost:8100/api/v2/health"
