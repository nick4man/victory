# staging.victory62.org Setup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Поднять постоянный staging environment на `staging.victory62.org` — Traefik router + parallel docker-compose stack на той же VDS + отдельная DB. Будет использоваться для всех будущих deploy'ев (не только EOL upgrade).

**Architecture:** Parallel docker-compose stack (`docker-compose.staging.yml`) на той же VDS что и prod. Shared PG instance с отдельной DB (`viktory_realty_staging`), shared Redis с отдельным DB number. Traefik dynamic router с Basic Auth middleware. Let's Encrypt SSL автоматом.

**Tech Stack:** Docker Compose, Traefik v3 file-provider, CrowdSec bouncer (опционально), Let's Encrypt HTTP-01, Basic Auth middleware.

**Reference docs:** `.claude/docs/vds-infra-cheatsheet.md`, `.claude/docs/nextcloud-cheatsheet.md`. Use skill `traefik-config-authoring` для config patterns + agent `traefik-vds-ops` для SSH execution.

---

## File Structure

**New files (4):**
- `docker-compose.staging.yml` (in repo root, не commit'ить если содержит secrets)
- `.env.staging.example` (template, commit'ится)
- `bin/staging-deploy.sh` (deploy helper)
- `lib/tasks/staging.rake` (data clone task)

**Modified files (1):**
- `README.md` или `docs/staging.md` (документация)

**Server-side (via traefik-vds-ops agent):**
- `/etc/traefik/dynamic/staging.yml` (router + middleware config)

**External:**
- DNS A-record: `staging.victory62.org` → VDS IP

**Branch:** `infra/staging-environment-setup`

---

## Pre-flight

- [ ] **Step 0a: Create branch**

```bash
git checkout main && git pull
git checkout -b infra/staging-environment-setup
```

- [ ] **Step 0b: Determine VDS IP**

Run: `dig +short victory62.org A`
Note the IP — потребуется для DNS step.

---

## Task 1: DNS A-record (manual — user-side)

**Files:**
- (none in repo)

- [ ] **Step 1: Add A-record в Cloudflare/DNS provider**

Add: `staging.victory62.org` → `<VDS_IP>` (Type A, TTL 300, Proxy: OFF first — для Let's Encrypt HTTP-01).

- [ ] **Step 2: Verify propagation**

Run: `dig +short staging.victory62.org A`
Expected: матчит `dig +short victory62.org A`.

Wait 1-5 минут если ещё не propagated.

- [ ] **Step 3: Document в notes (no commit)**

User action — не commit. Move to next task.

---

## Task 2: Create staging DB

**Files:**
- (server-side только)

- [ ] **Step 1: SSH to VDS + create DB**

```bash
ssh vds 'docker compose exec -T db createdb -U $POSTGRES_USER viktory_realty_staging'
```

Expected: success или "database already exists".

- [ ] **Step 2: Verify pgvector + postgis extensions**

```bash
ssh vds 'docker compose exec -T db psql -U $POSTGRES_USER -d viktory_realty_staging \
  -c "CREATE EXTENSION IF NOT EXISTS postgis; CREATE EXTENSION IF NOT EXISTS vector;"'
```

Expected: `CREATE EXTENSION` или "extension already exists".

- [ ] **Step 3: Verify**

```bash
ssh vds 'docker compose exec -T db psql -U $POSTGRES_USER -d viktory_realty_staging \
  -c "\dx" | grep -E "postgis|vector"'
```

Expected: оба extension в output.

- [ ] **Step 4: Commit (placeholder — задокументировать в README)**

This is server-side state — no repo change yet. Move to Task 3.

---

## Task 3: Create .env.staging.example template

**Files:**
- Create: `.env.staging.example`

- [ ] **Step 1: Write template**

```bash
# .env.staging.example — staging environment configuration template
# Copy to .env.staging on VDS (not committed). Fill in real values.

# Rails / Ruby
RAILS_ENV=staging
RAILS_LOG_TO_STDOUT=true
RAILS_MAX_THREADS=5

# DB (shared PG instance, separate database)
DATABASE_URL=postgres://USER:PASSWORD@db:5432/viktory_realty_staging

# Redis (shared instance, separate db number)
REDIS_URL=redis://redis:6379/2

# Domain
APP_HOST=staging.victory62.org
APP_PROTOCOL=https

# Secrets — generate fresh for staging (не reuse prod)
SECRET_KEY_BASE=<generate via: docker compose run --rm web bin/rails secret>
ADMIN_TOKEN=<generate via: openssl rand -hex 32>

# External APIs — use SAME keys as prod ONLY if safe; иначе separate dev keys
TELEGRAM_BOT_TOKEN=<separate staging bot recommended>
TELEGRAM_STAFF_CHAT_ID=<separate staging group>
GOOGLE_AI_API_KEY=<same as prod OK — read-only usage>
YANDEX_WEBMASTER_TOKEN=<NOT recommended — leave empty для staging>
INDEXNOW_API_KEY=<leave empty — INDEXNOW_DISABLED=true>
INDEXNOW_DISABLED=true
SENTRY_DSN=<separate staging project recommended>

# Topnlab — staging should NOT push to prod CRM
TOPNLAB_API_KEY=
TOPNLAB_WEBHOOK_DISABLED=true

# Sidekiq — отдельный namespace для staging jobs
SIDEKIQ_NAMESPACE=staging
```

- [ ] **Step 2: Commit template**

```bash
git add .env.staging.example
git commit -m "infra(staging): add .env.staging.example template"
```

---

## Task 4: Create docker-compose.staging.yml

**Files:**
- Create: `docker-compose.staging.yml`

- [ ] **Step 1: Inspect production docker-compose.yml**

Run: `cat docker-compose.yml`
Note services: db, redis, web, sidekiq (если есть).

- [ ] **Step 2: Write staging compose**

```yaml
# docker-compose.staging.yml — parallel stack для staging.victory62.org
# Shared db + redis с prod (отдельная DB + Redis number).

services:
  web-staging:
    build:
      context: .
      dockerfile: Dockerfile
    image: viktory-web:staging
    container_name: viktory-web-staging
    restart: unless-stopped
    env_file:
      - .env.staging
    depends_on:
      - db
      - redis
    networks:
      - default
      - traefik_public
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.victory-staging.rule=Host(`staging.victory62.org`)"
      - "traefik.http.routers.victory-staging.entrypoints=websecure"
      - "traefik.http.routers.victory-staging.tls=true"
      - "traefik.http.routers.victory-staging.tls.certresolver=letsencrypt"
      - "traefik.http.routers.victory-staging.middlewares=staging-auth@file"
      - "traefik.http.services.victory-staging.loadbalancer.server.port=3000"
    command: bin/rails server -b 0.0.0.0 -p 3000

  sidekiq-staging:
    image: viktory-web:staging
    container_name: viktory-sidekiq-staging
    restart: unless-stopped
    env_file:
      - .env.staging
    depends_on:
      - db
      - redis
    networks:
      - default
    command: bundle exec sidekiq -e staging

networks:
  default:
    external: true
    name: victory_default
  traefik_public:
    external: true
    name: traefik_public
```

- [ ] **Step 3: Verify syntax**

Run: `docker compose -f docker-compose.staging.yml config --quiet`
Expected: no output (success). Если errors — fix syntax.

- [ ] **Step 4: Commit**

```bash
git add docker-compose.staging.yml
git commit -m "infra(staging): add docker-compose.staging.yml для parallel stack"
```

---

## Task 5: Traefik dynamic config — staging-auth middleware

**Files:**
- Server-side via traefik-vds-ops agent: `/etc/traefik/dynamic/staging.yml`

- [ ] **Step 1: Generate basic auth hash**

Locally (или на VDS):

```bash
htpasswd -nbB victory '<strong-password-here>'
```

Output example: `victory:$2y$05$abc...`

- [ ] **Step 2: Delegate Traefik config к traefik-vds-ops agent**

Через Agent tool вызвать `traefik-vds-ops`:

> "Add `/etc/traefik/dynamic/staging.yml` with:
> - middleware `staging-auth` (basicAuth, users: `<from step 1>`)
> - НЕ нужен router в этом файле — router descrived в docker-compose labels.
> Apply safety workflow: backup, edit, verify Traefik picks up middleware (`/api/http/middlewares` debug if available), no rollback needed unless 5xx spike."

- [ ] **Step 3: Verify middleware loaded**

```bash
ssh vds 'docker compose -p traefik logs traefik | grep -i staging-auth | tail -5'
```

Expected: log line about middleware loaded.

- [ ] **Step 4: Document в repo (sample for reference)**

```yaml
# Reference: contents of /etc/traefik/dynamic/staging.yml on VDS
# (Not loaded by our app — server-side Traefik file-provider только.)
# Stored here for documentation; real source of truth — VDS.
```

Create `docs/staging-traefik-reference.yml` with the middleware contents (без real password).

- [ ] **Step 5: Commit reference**

```bash
git add docs/staging-traefik-reference.yml
git commit -m "infra(staging): document staging-auth middleware (reference)"
```

---

## Task 6: Build staging image + first boot

**Files:**
- Server-side execution

- [ ] **Step 1: SSH to VDS + pull repo state**

```bash
ssh vds 'cd /path/to/victory && git pull origin infra/staging-environment-setup'
```

- [ ] **Step 2: Create real .env.staging**

```bash
ssh vds 'cp .env.staging.example .env.staging'
# Edit on VDS — fill real values (SECRET_KEY_BASE, ADMIN_TOKEN, etc)
# ВАЖНО: .env.staging НЕ commit'ить — добавлен в .gitignore через пункт ниже
```

- [ ] **Step 3: Build image**

```bash
ssh vds 'docker compose -f docker-compose.staging.yml build web-staging'
```

Expected: build succeeds (~3-5 min first time).

- [ ] **Step 4: Migrate DB**

```bash
ssh vds 'docker compose -f docker-compose.staging.yml run --rm web-staging bin/rails db:migrate'
```

Expected: migrations run cleanly on viktory_realty_staging.

- [ ] **Step 5: Start stack**

```bash
ssh vds 'docker compose -f docker-compose.staging.yml up -d'
```

- [ ] **Step 6: Health check**

```bash
ssh vds 'docker compose -f docker-compose.staging.yml logs web-staging --tail 50'
```

Expected: Puma boot, no errors.

```bash
curl -u 'victory:<password>' -sI https://staging.victory62.org/
```

Expected: `HTTP/2 200` (или 302 redirect).

- [ ] **Step 7: Update .gitignore**

In repo locally:

```bash
echo '.env.staging' >> .gitignore
git add .gitignore
git commit -m "infra(staging): ignore .env.staging (server-side)"
```

---

## Task 7: Anonymized data clone rake task

**Files:**
- Create: `lib/tasks/staging.rake`

- [ ] **Step 1: Write rake task**

```ruby
# lib/tasks/staging.rake
# frozen_string_literal: true

namespace :staging do
  desc 'Clone anonymized snapshot из prod в staging DB (run on VDS)'
  task clone_from_prod: :environment do
    abort 'Only run в staging env' unless Rails.env.staging?

    prod_dump = "/tmp/victory-prod-#{Time.current.strftime('%Y%m%d-%H%M')}.sql"

    # 1. Dump prod
    system("pg_dump -U #{ENV['POSTGRES_USER']} -h db viktory_realty_production > #{prod_dump}") or abort 'dump failed'

    # 2. Truncate staging
    ActiveRecord::Base.connection.execute('DROP SCHEMA public CASCADE; CREATE SCHEMA public;')

    # 3. Restore
    system("psql -U #{ENV['POSTGRES_USER']} -h db viktory_realty_staging < #{prod_dump}") or abort 'restore failed'

    # 4. Anonymize PII
    Rails.logger.info "Anonymizing client_passport_*, phone, email fields..."
    ActiveRecord::Base.connection.execute(<<~SQL)
      UPDATE inquiries SET
        client_passport_number = '0000 000000',
        client_passport_issued_by = 'АНОНИМИЗИРОВАНО',
        client_email = CONCAT('staging-', id, '@example.test'),
        client_phone = CONCAT('+7900', LPAD(id::text, 7, '0'));
      UPDATE users SET
        email = CONCAT('staging-', id, '@example.test'),
        phone = CONCAT('+7900', LPAD(id::text, 7, '0'))
        WHERE id > 0;
    SQL

    # 5. Cleanup
    File.delete(prod_dump)
    puts "Staging clone complete + anonymized"
  end
end
```

- [ ] **Step 2: Commit task**

```bash
git add lib/tasks/staging.rake
git commit -m "infra(staging): rake staging:clone_from_prod (anonymized)"
```

---

## Task 8: Staging deploy helper script

**Files:**
- Create: `bin/staging-deploy.sh`

- [ ] **Step 1: Write script**

```bash
#!/usr/bin/env bash
# bin/staging-deploy.sh — pull, build, migrate, restart staging stack
set -euo pipefail

cd "$(dirname "$0")/.."

echo "==> Pulling latest от origin/main"
git fetch origin
git checkout main && git pull origin main

echo "==> Building staging image"
docker compose -f docker-compose.staging.yml build web-staging

echo "==> Running migrations"
docker compose -f docker-compose.staging.yml run --rm web-staging bin/rails db:migrate

echo "==> Restarting stack"
docker compose -f docker-compose.staging.yml up -d

echo "==> Health check (5s wait для boot)"
sleep 5
docker compose -f docker-compose.staging.yml logs web-staging --tail 20

echo "==> Smoke test"
curl -u "victory:${STAGING_BASIC_AUTH_PASS}" -sI https://staging.victory62.org/ | head -3

echo "==> Done"
```

- [ ] **Step 2: Make executable**

```bash
chmod +x bin/staging-deploy.sh
```

- [ ] **Step 3: Commit**

```bash
git add bin/staging-deploy.sh
git commit -m "infra(staging): add bin/staging-deploy.sh helper"
```

---

## Task 9: README + documentation

**Files:**
- Create: `docs/staging.md`

- [ ] **Step 1: Write doc**

```markdown
# Staging Environment — staging.victory62.org

## Overview

Permanent staging environment на той же VDS что и prod, parallel docker-compose
stack. Shared DB instance с отдельной DB (`viktory_realty_staging`), shared
Redis с отдельным DB number (2).

## URLs

- Site: https://staging.victory62.org
- Auth: Basic Auth (Traefik middleware) — ask admin для credentials

## Deploy

```bash
ssh vds 'cd /path/to/victory && bin/staging-deploy.sh'
```

## Data clone

```bash
ssh vds 'cd /path/to/victory && \
  docker compose -f docker-compose.staging.yml run --rm web-staging \
    bin/rails staging:clone_from_prod RAILS_ENV=staging'
```

## Logs

```bash
ssh vds 'docker compose -f docker-compose.staging.yml logs -f web-staging'
```

## Stop

```bash
ssh vds 'docker compose -f docker-compose.staging.yml down'
```

## Notes

- `.env.staging` живёт только на VDS — не commit'ится
- Sidekiq uses separate namespace (`staging`) — jobs не идут в prod queue
- INDEXNOW + Yandex Recrawl disabled на staging (`INDEXNOW_DISABLED=true`,
  пустой `YANDEX_WEBMASTER_TOKEN`) — staging не должен пинговать search engines
- Topnlab API key пустой — staging не пишет в CRM
```

- [ ] **Step 2: Commit**

```bash
git add docs/staging.md
git commit -m "infra(staging): document staging environment usage"
```

---

## Task 10: Final verification

- [ ] **Step 1: Push branch**

```bash
git push -u origin infra/staging-environment-setup
```

- [ ] **Step 2: Open PR**

```bash
gh pr create --base main --title "infra: setup staging.victory62.org" \
  --body "Phase 1a from docs/superpowers/specs/2026-06-04-eol-rails-ruby-upgrade-design.md

Sets up permanent staging environment на той же VDS:
- docker-compose.staging.yml (parallel stack)
- staging DB (viktory_realty_staging) + Redis db:2
- Traefik router + Basic Auth middleware
- DNS A-record (manual, done)
- rake staging:clone_from_prod (anonymized PII)
- bin/staging-deploy.sh helper
- docs/staging.md

Не EOL upgrade — это infrastructure investment, нужна для всех будущих deploy'ев."
```

- [ ] **Step 3: Verify CI green**

Wait для CI run. Expected: RuboCop ✓ (no app code changes), Brakeman/bundler-audit unchanged.

- [ ] **Step 4: Verify staging actually serves**

```bash
curl -u 'victory:<pass>' -sI https://staging.victory62.org/admin/health.json
```

Expected: HTTP/2 200 + JSON body со status.

- [ ] **Step 5: Merge**

После approve — merge. Staging environment live.

---

## Acceptance

- [x] Spec coverage: Phase 1a из design Section 3 — covered (Traefik + compose + DB + auth + DNS + clone script + docs)
- [x] Placeholder scan: passwords и SECRET_KEY_BASE marked для manual generation, не hardcoded
- [x] Type consistency: image names, service names, network names consistent
