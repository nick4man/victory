# EOL Rails+Ruby Upgrade — Phase 1 Design

> **Status:** Approved by user — ready for implementation plan
> **Date:** 2026-06-04
> **Project:** victory62 (АН «Виктори»)
> **Branch target:** `feat/eol-phase-1-ruby33-rails72`

## 1. Context

Production stack victory62.org работает на Rails 7.1.6 + Ruby 3.2.2 — оба
EOL'd. Текущие последствия:

- **bundler-audit RED**: Rails 7.1 имеет 8 CVE (XSS в Action View, content-type
  bypass в Active Storage, path traversal, ReDoS в number_to_delimited, etc),
  patch только в `~> 7.2.3, >= 7.2.3.1` / `~> 8.0.4, >= 8.0.4.1` / `>= 8.1.2.1`.
- **Brakeman 2 HIGH EOL warnings**: Rails 7.1.6 EOL 2025-10-01, Ruby 3.2.2
  EOL 2026-03-31.
- CI на main красный (Brakeman + bundler-audit jobs), блокирует другую
  работу (PR'ы, deploy gating).

Долгосрочный target — Rails 8 + Ruby 3.4. Этот документ покрывает
**Phase 1 (ASAP)**: Rails 7.1.6 → 7.2.3.1, Ruby 3.2.2 → 3.3.6. Phase 2
(Rails 7.2 → 8.0/8.1, Ruby 3.3 → 3.4) — отдельный спринт после Phase 1
стабилизации.

## 2. Goals & Non-Goals

**Goals:**
- Закрыть все Rails 7.1 CVE → bundler-audit GREEN для Rails-related advisories.
- Закрыть оба Brakeman EOL HIGH warnings (Rails + Ruby).
- Поднять стабильную staging-среду (`staging.victory62.org`) — будет нужна для всех будущих deploy'ев.
- Добавить ~20-30 critical specs ДО upgrade как safety net (75 → ~100).

**Non-Goals:**
- Rails 8 / Ruby 3.4 — Phase 2.
- Devise 4.9 → 5.0 (мажорный bump) — Devise OFF на проде, не критично; Phase 2.
- friendly_id 5.5 → 6.x — 5.5 совместим с 7.2, оставляем.
- `template_class.constantize` UnsafeReflection fix (Brakeman Medium) — не EOL-related, отдельный fix.
- 4 weak Brakeman warnings (LinkToHref, DynamicRender, VerbConfusion, Redirect) — кандидаты на `.brakeman.ignore`, не блокеры.

## 3. Architecture

### Phase 1a — Setup staging.victory62.org (1-2 дня)

Постоянный staging subdomain для всех будущих deploy'ев — не только этого
upgrade. Живёт на той же VDS что и prod, но изолированный.

```
                    cloudflare DNS
                          │
                          ▼
                    Traefik (VDS)
                    ┌─────────┴────────┐
                    ▼                  ▼
       victory62.org (prod)    staging.victory62.org
                    │                  │
                    ▼                  ▼
            docker compose       docker-compose.staging.yml
            web :3000            web :3001 (different container)
                    │                  │
                    └────────┬─────────┘
                             ▼
                    PG instance (shared)
                    ├── viktory_realty_production
                    └── viktory_realty_staging
                    
                    Redis instance (shared, separate db numbers)
                    ├── db:0 (prod)
                    └── db:2 (staging)
```

**Конфигурация:**
- Traefik router `staging-victory` → `web:3001`, TLS via Let's Encrypt (HTTP-01)
- Basic auth middleware (или IP allowlist) — не хотим индексации/случайных visitor
- DB: отдельная база `viktory_realty_staging` в той же PG instance (custom postgis+pgvector image)
- Redis: shared instance, `REDIS_URL=redis://...?db=2` для staging
- Periodic clone: anonymized snapshot из prod в staging (отдельный rake task)
- Sidekiq: отдельный namespace (staging jobs не идут в prod queue)

### Phase 1b — EOL Upgrade Branch (3-5 дней)

Branch `feat/eol-phase-1-ruby33-rails72`, per-step commits для clean rollback:

```
Step 0: Test bootstrap (~2-3 дня)
   • test-bootstrapper agent + rspec-bootstrap skill
   • Цель: 75 → ~100 specs, критичные сервисы covered
   • Targets: chat_responder, search_group_messages/search_all_leads,
     property_evaluation_service, sidekiq_cron_loader, health_controller,
     article.rb hooks, property.rb hooks, topnlab_reports_controller, и
     request specs для PropertiesController/BlogController/LandingsController#show
   • Acceptance: все new specs green на текущем Rails 7.1 / Ruby 3.2
   • Commit + push в отдельной ветке (предшествующей или включённой в feat/eol-phase-1)

Step 1: Ruby 3.2.2 → 3.3.6
   • Dockerfile: FROM ruby:3.3.6-slim-bookworm
   • Gemfile: ruby '3.3.6'
   • .ruby-version: 3.3.6 (новый файл для rbenv/asdf/editor)
   • docker compose build web
   • bin/rspec локально (75+ specs должны быть green)
   • Commit "chore(ruby): bump Ruby 3.2.2 → 3.3.6"

Step 2: Rails 7.1.6 → 7.2.3.1
   • Gemfile: gem 'rails', '~> 7.2.3', '>= 7.2.3.1'
   • bundle update rails  (подтянет actionview, activerecord, etc на 7.2.3.1)
   • bin/rails app:update → review diff в config/ interactively
     - Accept: bin/* regen, public/* updates
     - Review: config/environments/*.rb, config/application.rb
     - Accept: config/initializers/new_framework_defaults_7_2.rb
   • config/application.rb: config.load_defaults 7.2 (flip с 7.1)
   • Review каждую line в new_framework_defaults_7_2.rb — оставить `false`
     для опций требующих миграции (если есть)
   • Resolve deprecation warnings до 0
   • bin/rspec повторно
   • Commit "chore(rails): bump Rails 7.1.6 → 7.2.3.1 + flip load_defaults"

Step 3: Compatibility bumps
   • Gemfile: gem 'ransack', '~> 4.2'  (для Rails 7.2 compat)
   • Gemfile: gem 'neighbor', '~> 0.6' (pgvector compat)
   • Gemfile: gem 'bcrypt', '~> 3.1', '>= 3.1.22' (CVE clean)
   • bundle update ransack neighbor bcrypt
   • Smoke: PropertyEmbedding.nearest_neighbors, LeadEventEmbedding.nearest_neighbors
   • Smoke: ransack search в admin panel
   • Commit "chore(deps): ransack 4.2 + neighbor 0.6 + bcrypt 3.1.22"

Step 4: Audit + cleanup
   • grep -rn 'Rails.application.secrets' app config lib  → 0 expected
   • grep -rn 'Arel.sql' app/services app/models           → review каждый
   • Brakeman + bundler-audit локально
   • Commit (если нужно)

Step 5: Push → CI → review
   • git push -u origin feat/eol-phase-1-ruby33-rails72
   • Open PR → main
   • CI должен показать: RuboCop ✓, Brakeman -2 HIGH (только UnsafeReflection +
     4 weak останутся), bundler-audit ✓ для Rails CVE
```

### Phase 1c — Deploy (1-2 дня + 24ч watch)

- Pre-flight checklist (10 пунктов — см. Section 7).
- Staging deploy first (3 рабочих дня acceptance).
- Production deploy в low-traffic window.
- 24-hour watch period с rollback готовым.

## 4. Gem Compatibility Matrix

| Gem | Current | Phase 1 target | Risk | Note |
|---|---|---|---|---|
| **rails** | 7.1.6 | 7.2.3.1 | 🟡 medium | `app:update`, flip `load_defaults 7.2`. |
| **ruby** (runtime) | 3.2.2 | 3.3.6 | 🟢 low | YJIT по умолчанию on. |
| **ransack** | ~> 4.1 | ~> 4.2 | 🟡 medium | 4.1 supports Rails 7.1; 4.2 supports 7.2+. |
| **neighbor** | ~> 0.5 | ~> 0.6 | 🟡 medium | API unchanged (nearest_neighbors), 0.6 Rails 7.2-ready. |
| **bcrypt** | ~> 3.1.7 | ~> 3.1, >= 3.1.22 | 🟢 low | CVE clean, JRuby-only иначе. |
| **friendly_id** | ~> 5.5 | без bump | 🟢 low | 5.5 совместим с Rails 7.2. |
| **pg_search** | ~> 2.3 | без bump | 🟢 low | Verify через test. |
| **devise** | ~> 4.9 | без bump | 🟢 low | Devise OFF на проде. |
| **aasm** | ~> 5.5 | без bump | 🟢 low | 5.5 supports Rails 8 даже. |
| **sidekiq** | ~> 7.2 | без bump | 🟢 low | Current. |
| **sidekiq-cron** | ~> 2.4 | без bump | 🟢 low | Just bumped в prior PR. |
| **kaminari, meta-tags, prawn, redcarpet, rqrcode, stoplight, faraday, faraday-retry, geocoder, image_processing, jwt, pundit, redis, rack-cors, bootsnap** | various | без bump | 🟢 low | Все совместимы с Rails 7.2 / Ruby 3.3. |

**Transitive** (bundler пересчитает автоматом):
- actionview, activestorage, activesupport, actionpack, etc → 7.2.3.1
- rack (≥3.2.6), rack-session (≥2.1.2) — уже bumped
- nokogiri, net-imap, jwt — patch если bundler-audit flag'ит

## 5. Code & Config Changes

### Files modified

```diff
Dockerfile
- FROM ruby:3.2.2-slim-bookworm
+ FROM ruby:3.3.6-slim-bookworm

Gemfile
- ruby '3.2.2'
+ ruby '3.3.6'
- gem 'rails', '~> 7.1.0'
+ gem 'rails', '~> 7.2.3', '>= 7.2.3.1'
- gem 'ransack', '~> 4.1'
+ gem 'ransack', '~> 4.2'
- gem 'neighbor', '~> 0.5'
+ gem 'neighbor', '~> 0.6'
- gem 'bcrypt', '~> 3.1.7'
+ gem 'bcrypt', '~> 3.1', '>= 3.1.22'

config/application.rb
- config.load_defaults 7.1
+ config.load_defaults 7.2

.ruby-version (new)
+ 3.3.6
```

### Generated by `bin/rails app:update` — review interactively

- `config/initializers/new_framework_defaults_7_2.rb` — **review каждую line**.
  Возможные опции для оставить `false` если требуют миграции:
  - `Rails.application.config.active_storage.video_preview_arguments` (можно
    оставить current)
  - Любые `host_authorization` tweaks — verify с Traefik X-Forwarded-Host
- `config/environments/*.rb` — accept minor changes
- `bin/*` scripts — accept (regen)
- `config/storage.yml`, `config/cable.yml` — verify

### Audit greps перед PR

```bash
grep -rn 'Rails.application.secrets' app config lib  # must be 0
grep -rn 'Arel.sql' app/services app/models           # review each
grep -rn 'load_defaults' config/                       # должен быть 1
```

### Known concerns (untouched, separate fixes)

- `request.get?` для HEAD в `application_controller.rb:269` — Brakeman weak,
  Rails 7.2 не меняет.
- `template_class.constantize` в `webhooks/topnlab_reports_controller.rb:16` —
  Brakeman Medium, требует whitelist + safe_constantize fix, отдельная задача.

## 6. Test & Validation Strategy

### Layer 0 — Test bootstrap (NEW, 2-3 дня перед upgrade)

Использовать `test-bootstrapper` agent + `rspec-bootstrap` skill.

**Priority targets (~20-30 new specs):**

1. `app/services/llm/chat_responder.rb` — main chatbot logic
2. `app/services/chat_tools/staff/search_group_messages.rb` (recent `in_order_of` fix)
3. `app/services/chat_tools/staff/search_all_leads.rb` (recent `in_order_of` fix)
4. `app/services/property_evaluation_service.rb` — valuation
5. `config/initializers/sidekiq_cron_loader.rb` — server-mode hook
6. `app/controllers/admin/health_controller.rb` — health endpoint
7. `app/models/article.rb` — after_commit hooks (IndexNow + Y.Recrawl)
8. `app/models/property.rb` — after_commit hooks
9. `app/controllers/webhooks/topnlab_reports_controller.rb` — report flow
10. Request specs: `PropertiesController`, `BlogController`, `LandingsController#show`

**Acceptance**: 75 → ~100 specs, все green на текущем Rails 7.1 / Ruby 3.2.

### Layer 1 — Local Docker (на dev machine)

```bash
docker compose build web                                # новый image
docker compose up -d db redis
docker compose run --rm web bin/rails db:migrate
docker compose run --rm web bin/rspec                   # 100% green
docker compose run --rm web bin/rubocop                 # baseline green
docker compose run --rm web bin/rails server &
curl http://localhost:3000                              # basic smoke
docker compose run --rm web bin/rails runner \
  "puts Property.first&.public_url; puts LeadEvent.in_order_of(:id, [1,2]).to_sql"
```

**Acceptance criteria:**
- 100/100 specs pass
- RuboCop с baseline green
- Brakeman: -2 EOL HIGH, total ≤ 5
- bundler-audit: 0 Rails-related CVE
- Boot ok без deprecation panics

### Layer 2 — Staging (staging.victory62.org)

```bash
docker compose -f docker-compose.staging.yml pull web
docker compose -f docker-compose.staging.yml up -d
curl -s "https://staging.victory62.org/admin/health.json?token=$ADMIN_TOKEN" | jq .
```

**Run live-test-playbook полностью:**
- 🧊 Group A — read-only health checks
- 🧰 Group B — write flows (search, mortgage, valuation)
- 📞 Group C — TG bot escalation/inbox
- 🔍 Semantic search (in_order_of verify)

**Manual acceptance: 3 рабочих дня** — staff пользуется как обычно, отслеживаем
аномалии в Sentry/Sidekiq/access log.

### Layer 3 — Production deploy

См. Section 7 (Pre-deploy checklist) + Section 8 (Deploy + rollback).

## 7. Pre-Deploy Checklist

**ВСЕ должны быть ✅ перед prod deploy:**

```bash
# 1. Sidekiq queue empty (drain)
ssh vds 'docker compose exec -T web bin/rails runner \
  "puts Sidekiq::Queue.all.map { |q| [q.name, q.size] }"'
# → все queue.size = 0

# 2. Cron jobs sanity (sidekiq-cron 2.4 compat)
ssh vds 'docker compose exec -T web bin/rails runner \
  "puts Sidekiq::Cron::Job.all.map(&:name)"'
# → ~15 jobs

# 3. No pending migrations
ssh vds 'docker compose exec -T web bin/rails db:migrate:status' | grep down
# → пусто

# 4. DB backup сделан + uploaded в Nextcloud
ls -la /tmp/pre-eol-backup-*.sql && rclone ls "nxt:Офис/Backups/" | tail -3

# 5. Rollback Docker tag exists
ssh vds 'docker images viktory-web --format "{{.Tag}}"' \
  | grep prod-pre-eol-phase-1

# 6. Staging acceptance period completed (3 calendar days, no Sentry red)

# 7. Low-traffic deploy window (не peak 09:00-12:00 MSK)
date

# 8. Team available — director + manager в TG 2ч после deploy

# 9. PR CI: rubocop ✓, brakeman -2 HIGH, bundler-audit Rails ✓
gh pr view <eol-pr-number> --json statusCheckRollup

# 10. Final signoff director в TG
```

## 8. Deploy & Rollback

### Pre-deploy artifact prep

```bash
# DB backup
ssh vds 'docker compose exec -T db pg_dump -U $POSTGRES_USER viktory_realty_production' \
  > /tmp/pre-eol-backup-$(date +%Y%m%d-%H%M).sql
rclone copy /tmp/pre-eol-backup-*.sql nxt:Офис/Backups/

# Rollback tag
ssh vds 'docker tag viktory-web:latest viktory-web:prod-pre-eol-phase-1'
```

### Deploy procedure

```bash
# Staging first
docker compose -f docker-compose.staging.yml pull web
docker compose -f docker-compose.staging.yml up -d web
# Watch staging 3 рабочих дня

# Prod deploy после acceptance
docker compose pull web
docker compose up -d web
# Если есть pending миграции — bin/rails db:migrate ПЕРВОЙ командой
```

### Post-deploy smoke (10 минут)

- `/admin/health.json` все 4 checks ok
- `Sidekiq::Cron::Job.all` (2.x compat verify)
- Boot без deprecation panics в logs (`docker compose logs web --tail 100`)
- Sentry — нет new errors first 10 min
- Curl 5 ключевых URLs (home, property show, blog, /kupit/kvartira, /agents/X)

### 24-hour watch period

Метрики:
- Sentry error rate vs baseline (1h, 4h, 24h checkpoints)
- /admin/health.json checks каждые 2-3 часа
- Sidekiq queue depth (`Sidekiq::Queue.all.map { |q| [q.name, q.size] }`)
- Traefik access log 5xx rate

### Rollback procedure (5-10 минут)

```bash
ssh vds
docker compose down web                                # graceful
docker tag viktory-web:prod-pre-eol-phase-1 viktory-web:latest
docker compose up -d web
curl -sI https://victory62.org/admin/health.json       # confirm 200
```

### Rollback triggers (любое одно)

- Sentry errors > 5x baseline 1ч после deploy
- /admin/health.json status != "ok"
- 5xx rate > 1% в Traefik access log
- Sidekiq Job retry rate > 10% baseline
- Manual: явный bug-report от пользователя по critical flow

### Communication

- Pre-deploy: TG-channel post staff "EOL Phase 1 deploy через 15 минут — watch for issues"
- Post-deploy: TG-channel "Deploy completed @ HH:MM, watch period 24h"
- Rollback (if needed): TG-channel "Rollback executed — service restored"

## 9. Open Items / Phase 2 Pointers

Не входит в Phase 1, документ-ссылки на будущий sprint:

- **Phase 2**: Rails 7.2 → 8.0/8.1, Ruby 3.3 → 3.4
- **Devise 4.9 → 5.0** (мажорный bump, Devise off на проде — низкий приоритет)
- **`template_class.constantize` UnsafeReflection** в topnlab_reports_controller —
  whitelist через `safe_constantize` + namespace-check
- **friendly_id 5.5 → 6.x** — после Rails 8 stable
- **Rails 8 modern stack**: Solid Queue / Solid Cache (вместо sidekiq + redis cache?), Propshaft (вместо Sprockets), Kamal-ready
- **4 Brakeman weak warnings** → `.brakeman.ignore` после индивидуального review

## 10. Acceptance Definition

Phase 1 считается завершённой когда:

- [x] Design approved (этот документ)
- [ ] Layer 0 — ~100 specs all green на текущем 7.1/3.2
- [ ] staging.victory62.org работает + accessible с basic auth
- [ ] Branch `feat/eol-phase-1-ruby33-rails72` — все 5 steps committed
- [ ] Local Layer 1: 100/100 specs, RuboCop green, Brakeman -2 EOL HIGH
- [ ] Staging Layer 2: live-test-playbook все группы pass + 3 рабочих дня без anomalies
- [ ] Pre-deploy checklist all ✅
- [ ] Production deploy + 24h watch без rollback
- [ ] CI на main: RuboCop ✓, Brakeman -2 HIGH (только UnsafeReflection + 4 weak), bundler-audit ✓ для Rails CVE
- [ ] Memory updated: techContext.md → Ruby 3.3.6, Rails 7.2.3.1
- [ ] Phase 2 backlog item создан с datapointers
