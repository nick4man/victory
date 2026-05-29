#!/usr/bin/env bash
# E1 — Скрипт пересборки и перезапуска audit-v2-api на live audit-stack.
#
# Вызывается:
#   - из GitHub Actions deploy-job (CI passed → push в master)
#   - вручную: ./redeploy.sh <git-sha-или-пусто>
#   - rollback: ./redeploy.sh --previous
#
# Что делает:
#   1. pull последнего master (если git-dir есть)
#   2. сохраняет тэг текущего api-образа как :previous (для rollback)
#   3. docker compose build api
#   4. docker compose up -d --force-recreate api
#   5. ждёт healthy
#   6. фиксирует deployed-tag в /tmp/audit-stack-deployed-sha
#
# --previous: возвращает image из :previous обратно в :latest, перезапускает.

set -euo pipefail

cd "$(dirname "$0")"

ACTION="${1:-deploy}"
COMPOSE_FILE="docker-compose.yml"
SERVICE="api"
IMAGE_BASE="audit-v2-stack-api"
DEPLOY_LOG="/tmp/audit-stack-deploy.log"

log() {
    echo "[redeploy $(date -u +%H:%M:%S)] $*" | tee -a "$DEPLOY_LOG"
}

# -------------------------------------------------------------------
# Rollback path
# -------------------------------------------------------------------
if [[ "$ACTION" == "--previous" ]] || [[ "$ACTION" == "rollback" ]]; then
    log "ROLLBACK: восстанавливаем previous image"
    if ! docker image inspect "${IMAGE_BASE}:previous" >/dev/null 2>&1; then
        log "❌ ${IMAGE_BASE}:previous отсутствует — rollback невозможен"
        exit 2
    fi
    docker tag "${IMAGE_BASE}:previous" "${IMAGE_BASE}:latest"
    docker compose -f "$COMPOSE_FILE" up -d --force-recreate "$SERVICE"
    log "✅ Rollback завершён, контейнер пересоздан с previous-image"
    exit 0
fi

# -------------------------------------------------------------------
# Forward deploy
# -------------------------------------------------------------------
GIT_SHA="${ACTION:-unknown}"
log "DEPLOY: SHA=${GIT_SHA}"

# 1. Сохраняем текущий image как :previous (для rollback)
if docker image inspect "${IMAGE_BASE}:latest" >/dev/null 2>&1; then
    docker tag "${IMAGE_BASE}:latest" "${IMAGE_BASE}:previous"
    log "✅ Tagged current latest as :previous"
fi

# 2. Pull (если в git-clone)
if [[ -d "$(git -C ../../audit-engine-v2 rev-parse --show-toplevel 2>/dev/null)" ]]; then
    log "git pull для audit-engine-v2..."
    (cd ../../audit-engine-v2 && git fetch origin && git checkout master && git pull --ff-only) || \
        log "⚠️  git pull failed (продолжаем со state на диске)"
fi

# 3. Build
log "docker compose build $SERVICE..."
docker compose -f "$COMPOSE_FILE" build "$SERVICE" 2>&1 | tail -5 | tee -a "$DEPLOY_LOG"

# 4. Recreate
log "docker compose up -d --force-recreate $SERVICE..."
docker compose -f "$COMPOSE_FILE" up -d --force-recreate "$SERVICE"

# 5. Healthcheck (отдельный — независимо от docker-healthcheck)
log "Ожидаем /api/v2/health..."
for i in $(seq 1 30); do
    if curl -fsS http://localhost:8100/api/v2/health >/dev/null 2>&1; then
        log "✅ API здоров"
        break
    fi
    sleep 2
    if [[ $i -eq 30 ]]; then
        log "❌ API не вернул /health за 60s — откатываюсь"
        if docker image inspect "${IMAGE_BASE}:previous" >/dev/null 2>&1; then
            docker tag "${IMAGE_BASE}:previous" "${IMAGE_BASE}:latest"
            docker compose -f "$COMPOSE_FILE" up -d --force-recreate "$SERVICE"
            log "⚠️  Автоматический rollback применён"
        fi
        exit 3
    fi
done

# 6. Migrate (alembic upgrade head делается из CMD контейнера, но дублируем
#    отдельно — на случай если в новом образе миграции не успели прокатиться)
log "Прокатываем миграции..."
docker compose -f "$COMPOSE_FILE" exec -T "$SERVICE" alembic upgrade head 2>&1 | tail -3 | tee -a "$DEPLOY_LOG"

# 7. Фиксируем SHA
echo "$GIT_SHA" > /tmp/audit-stack-deployed-sha
log "✅ Deploy завершён. SHA=${GIT_SHA}"
