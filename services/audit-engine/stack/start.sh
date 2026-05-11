#!/bin/bash
set -e
echo "🚀 Starting Audit Engine v2.0 stack..."

# Проверяем что порт 5433 свободен
if lsof -i :5433 >/dev/null 2>&1; then
  echo "❌ Port 5433 is already in use!"
  exit 1
fi

# Запускаем стек
docker compose up -d

# Ждём готовности
echo "⏳ Waiting for services..."
sleep 5

# Проверяем health
docker compose ps
echo ""
echo "✅ Stack is running!"
echo "   API: http://localhost:8100"
echo "   PostgreSQL: localhost:5433"
echo "   Redis: localhost:6379"
echo ""
echo "   Health check: curl http://localhost:8100/api/v2/health"
