# activeContext.md — что сейчас в работе

> Обновляй этот файл вручную или при смене фазы. Здесь — только «живое».

## Branch (обновлено 08.08.26)

- Worktree: `/home/q/victory-chat`, marker `.claude-session` = `chat`
- Активная ветка: `dev/chat`, синхронна с `main` (0 ahead / 0 behind, `ddcc3e9`)
- Состояние: рабочее дерево чистое; в проде Rails 8.1.3.1 / Ruby 3.3.6 (PR #8)

## Текущая фаза

**Инфраструктура сессий закрыта (08.08.26)** — 4 worktree разведены, у chat
есть свой изолированный Rails-стек (см. ниже). Дальше — по site-chatbot.

Предыдущая содержательная фаза — Phase 8 (TG ↔ victory62 cross-link), коммиты:
- `98c5477 Phase 8: cross-link TG ↔ victory62 — Rails side`
- `071563c Express PDF + TG notifier + QR codes on both reports`
- `b5f5640 Phase 7: News UX — embeddings, share/TG CTA, swipe carousel, modal preview`
- `3ac78a2 Fix: TG inbox photo download must be async`
- `832f06b Production: status PROD + TG inbox + deploy docs`

## Параллельные сессии Claude Code (актуально с 08.08.26)

**4 сессии, у каждой свой git worktree** (раньше все делили `/home/q/victory` →
коллизии на checkout). Полная конвенция — `.claude/sessions/README.md`.

| Session | Worktree | Ветка |
|---|---|---|
| victory | `/home/q/victory-victory` | `dev/victory` |
| chat | `/home/q/victory-chat` | `dev/chat` |
| seo | `/home/q/victory-seo` | `dev/seo` |
| upgrade | `/home/q/victory-upgrade` | `dev/upgrade` |

🚨 `/home/q/victory` — main checkout и **live-prod bind-mount** (`victory-web-1`
монтирует его в `/app` с code-reload). Только merge/deploy, не разработка.

Идентичность — из marker-файла `.claude-session` в корне worktree.
Секреты — symlink `.env → /home/q/victory/.env` (один источник на все worktree).

### Как chat-сессия исполняет код (08.08.26)

На хосте нет менеджера версий Ruby: системный — 3.3.8, Gemfile пинит 3.3.6,
поэтому `bundle exec` с хоста не работает. Прод-контейнер примонтирован к
main-checkout'у и наш код не видит. Решение — свой изолированный стек:

```bash
bin/chat-stack up            # db + redis + web на http://localhost:3001
bin/chat-stack rspec <path>  # спеки в RAILS_ENV=test, своя БД
bin/chat-stack runner '...'  # rails runner
bin/chat-stack logs | sh | down | nuke
```

Конфиг — `docker-compose.chat.yml` (compose-project `victory-chat`, свои волюмы
`victory-chat_*`). Прод (project `victory`, порт 3000) не затрагивается.
Sidekiq намеренно не поднят — фоновые джобы копятся в своём redis и не уходят
в реальные TG/Topnlab.

Координация: Memory-bank, `.mcp.json`, `.claude/agents/`, `.claude/skills/` проектные → все сессии видят одинаковую конфигурацию. Для одновременных правок одного файла — lock-file pattern (см. skill `session-coordination` и agent `session-coordinator`).

Session-domain split (рекомендуемый):
- Rails-код / migrations / specs → **victory**
- Site-chatbot tools / prompts / LLM chain → **chat**
- SEO meta / JSON-LD / sitemap / content-SEO → **seo** (Rails-side изменения — hand-off в victory)
- Rails/Ruby EOL-апгрейды → **upgrade**
- Документы / планирование / TG-доставка → любая, но обычно **chat**

## Что сейчас «в фокусе» при работе

Топ-3 области, куда наиболее вероятно идут изменения:
1. **TG интеграция**: `app/services/telegram/`, `app/services/express_report_notifier.rb`, `app/services/audit_report_notifier.rb`
2. **Express PDF / audit-PDF**: `app/services/audit_pdf/`, `app/services/pdf_generator_service.rb`
3. **Property AVM / valuations**: `app/services/property_evaluation/`, `app/services/valuations/`, `app/controllers/property_valuations_controller.rb`

## Security/bugfix sweep (18.05.26) — 5 итераций closed

5-iter security + reliability sweep после feature work (A3 dossier + B2
foreign + A6 docs). Key wins:

**Iter 1 (security) — `cc64386`**
- Admin token больше не utekает через URL Referer (все redirect'ы и
  view links без `token=` — session-cookie only)
- Telegram webhook требует `X-Telegram-Bot-Api-Secret-Token` если ENV
  настроен (graceful fallback с warn-log если не настроен)
- Yookassa + AmoCRM webhooks возвращают 501 если ENV-secrets blank,
  иначе HMAC/Bearer auth
- MagicLinkToken#consume! теперь atomic (with_lock + double-check)
- Form-controllers (6 шт) больше не дампают raw PII через to_unsafe_h
- filter_parameter_logging расширен phone/email/message — фильтрует
  даже Rails-уровень «Processing by…» log

**Iter 2 (data integrity) — `99052f4`**
- Document model получил `default_scope { where(deleted_at: nil) }`
  + scope :with_deleted (соблюдает CLAUDE rule #1). User уже имел.

**Iter 3 (observability + БОЛЬШОЙ скрытый bug) — `26485a6`**
- 🎯 **CurrencyRatesService never worked live** — всегда FALLBACK_RATES
  (USD=95, EUR=103). Причина: Nokogiri::XML strict парсер отвергал
  CBR.ru XML после CP1251→UTF-8 (declaration лжёт). Fix: replace
  declaration на UTF-8 + drop strict. Foreign-investor PDFs и
  /foreign landing **неделями** показывали stale rates с пометкой
  «cbr.ru». Сейчас live: USD=73.13, EUR=85.18, AED=19.91 from cbr.ru.
- PropertyEvaluationService SemanticCompFinder/CrossCityAdapter
  failures теперь logged (был silent rescue → [])
- PropertyAvm tier-fallback + distance_km_to errors теперь logged
- ApplicationJob discard_on tells which job + args + reason

**Iter 4 (XSS + permit + uploads) — `49be987`**
- Article/CaseStudy markdown теперь passes через Rails-html-sanitizer
  с explicit allow-list — `<script>` стрипается, `onerror=` стрипается
- dashboard/settings_controller permit! → permit(*DEFAULT_NOTIFICATION_KEYS)
- Property.images + .floor_plans + User.avatar validate content_type
  + byte_size — .exe/.svg больше не примутся как .jpg

**Iter 5 (verification + bonus puma fix)**
- E2E все ключевые URL'ы возвращают 200
- Telegram → 401 без secret, Yookassa/AmoCRM → 501 без ENV
- CurrencyRates live (USD=73.13) подтверждено
- Bonus: puma.rb убран broken `Redis.current` (removed в redis-rb v5)
  — был WARNING на каждый worker boot/fork

Что НЕ сделано (carry-forward):
- JSONB metadata schema validation (Inquiry/User) — risky, нужен
  data audit перед enforce
- PropertyValuation/ViewingSchedule enums без `_prefix:` — too many
  callers (>10) для safe rename
- JWT token blacklist/rotation (отдельный security sprint)
- N+1 perf audit (отдельный perf sprint)
- Sentry/error tracking setup (отдельная инфра-задача)

## Property Visibility Decoupling (18.05.26) — 3 independent concerns

`Property#in_ad?` отделён от site visibility. До: `ready_for_site?`
требовал `in_ad=TRUE` → когда Topnlab снимал in_ad (Avito balance, модерация,
другие outbound-проблемы) — property пропадал с victory62.org. Это
архитектурно неправильно: мы модераторы своего сайта, не платим ни кому.

3 concerns (orthogonal):
| Concern | Source | Use |
|---|---|---|
| Site visibility | `status=:active` + `published_at` (via `ready_for_site?` gate) | /properties, /landings/*, cabinet, sitemaps |
| Outbound paid ad | `in_ad` (Topnlab) | Admin/cabinet badge только. Informational |
| MLS feeds | `in_mls` (Topnlab) | FeedsController via `in_advertising` scope |

`ready_for_site?` теперь: `force_archive ? false : (force_publish || (deal_state ∈ ACTIVE_DEAL_STATES + content))`.

ACTIVE_DEAL_STATES = `%w[ad active lead prepayment deferred]` (mirrors importer
ACTIVE_STATES — same set we sync from CRM).

Changes (4 commits):
  e90c3d1 — Property model + migration + bulk swap (~24 callers) `in_advertising → on_site`
  6bc816b — Admin UI: «Сайт» column + «Внешн. реклама» chips + «Скрыть с сайта» button
  8127c7d — Cabinet «Мои объекты» dashboard at /cabinet/properties

Funnel impact:
  Before: 9 status=active → 8 in_advertising → 8 on /properties
  After:  56 status=active → 56 on_site (4× больше on site)
           24 in_advertising (unchanged — outbound feeds respect agent's in_ad)

Bonus:
  /kupit/kvartira fixed (16 Рязанских квартир, было 0)
  force_archive — admin hide для жалоб клиентов/спорных сделок

## Catalog Polish + Client Onboarding (18.05.26) — 4/5 deliverables shipped

OODA-driven bundle ответил на user mandate (catalog UX + client flow):
1. ✅ D1 (1431c65) — «БАЗА АГЕНТСТВ» badge только для НЕ-наших
2. 🔬 D2 — external-feed inbound: research-only, см. ниже
3. ✅ D3 (71b9dd7) — CabinetInvitationMailer fired by Topnlab::OwnerSyncService
4. ✅ D4 (469d454) — LeadStageTransition broadcasts → CabinetChannel +
   Notification + CabinetMailer.stage_update (feature-flagged
   `ENABLE_LEAD_STAGE_BROADCAST`)
5. ✅ D5 (058942c) — `signed_agency_contract_at` gate перед публикацией
   + grandfather backfill (26 published остались)

**D2 (external feeds inbound) — decision: DEFER**

Цель user'а — «получить список объектов для публикации через открытые
фиды Яндекс / Topnlab». ExternalListing infra готова
(YRL parser + 6 sources enum + 4h cron), но:
- `ENV['YRL_FEED_URLS']` пуст; 0 ExternalListing rows
- /properties index НЕ показывает ExternalListings (только comparable data)

Два пути:
- **Option A — Yandex YRL public feeds** (zero-code, free): найти YRL
  Рязанских агентств (961-961.ru, novosele.ru, agent62.ru — требует
  верификации), добавить в .env, restart sidekiq. Risk: SEO duplicate
  content, lead-capture gap (buyer уходит на external URL).
- **Option B — Topnlab MLS** (~2h, требует API key): новый
  TopnlabMlsSyncJob, POST `/clients/get-entities-from-mls`, rate 1/sec.

Defer triggers перед implementation:
1. User decision — действительно показываем чужие listings? (SEO risk)
2. Lead-capture path для external — нам нужен redirect через наш
   detail page, не direct outbound link
3. Verify Yandex YRL public для целевых Рязанских агентств

Backlog: `app/views/properties/_external_card.html.erb` + index
controller mix, если решим показывать.

## MLS/YRL launch — Phase 0 baseline (18.05.26)

Запущен plan `.claude/plans/merry-honking-kay.md` («MLS/YRL feeds на полную
катушку + commission-strategy»). Phase 0 — baseline snapshot Yandex
метрик для post-launch diff.

**Yandex.Webmaster snapshot (host=victory62.org):**
- **SQI = 10** (Site Quality Index — низкая, ожидаемо для нового проекта)
- **SQI trend (15-18.05):** stable 10
- **Top query:** «купить квартиру в рязани»
- **Opportunities (mid-position + low-CTR + impressions>50):** 0 пока
  (Phase A early — мало impressions для opportunity detection)
- **Recrawl quota:** 139/150 remaining (11 used сегодня)
- **Sitemaps tracked:** sitemap.xml (4 URLs), sitemap-news.xml (0 URLs)

**Artifacts:**
- `tmp/yandex_baseline_2026-05-18.json` (5.2 KB) — full snapshot
- `tmp/yandex_opportunities_2026-05-18.json` (2 bytes — empty array)

**Next: Phase 1.** `rake yrl:launch:phase1` →
- backfill `in_mls=true` для ad-stage Topnlab properties (~24)
- ping Yandex.Webmaster recrawl для свежих URL'ов (~21 calls из 139 quota)
- остаётся ~118 quota для Phase 2 + дальше

Plan детально: `.claude/plans/merry-honking-kay.md`.
Diff-instruction: через 7 дней после Phase 1+2 — re-run `rake yrl:baseline`,
diff с `yandex_baseline_2026-05-18.json`.

## Topnlab sync audit (18.05.26) — P0+P1 fixed

Аудит: что было / что починено:

**Что работало правильно:**
- Property sync (every 30min): 73 active объектов, runs clean
- Staff sync: 14/17 agents have crm_user_id
- BuyerOrders (950): all assigned to agent + client_name present
- Magic-link cabinet auth: fully built, role=:client auto-created on first login
- TopnlabSyncRun#finish!: корректно handles both `errors:` and `error_log:` kwargs

**P0 — Fixed (owner linkage):**
- Добавлен `Topnlab::Client#get_clients_by_entity` (POST /clients/get-by-entity)
- Создан `Topnlab::OwnerSyncService` — pulls seller client → upsert User(role=:client) → set Property#owner_user_id
- Создан `TopnlabOwnerSyncJob` (queue: scheduled, cron: daily 03:00)
- `TopnlabPropertyImportJob` теперь enqueues TopnlabOwnerSyncJob после webhook import если owner_user_id nil
- Webhook controller теперь handles `type=order` → enqueues TopnlabOrdersSyncJob

**P1b — Fixed (BuyerOrder client linkage):**
- Миграция `20260528001000_add_client_crm_id_to_buyer_orders.rb`
- `OrderMapper#client_crm_id` — извлекает `client.id` из payload
- Теперь BuyerOrder.client_crm_id = Topnlab физлица.id → будущий cross-ref с User.crm_user_id

**P2 — TODO (требует решения):**
- `TopnlabClientsSyncJob` — bulk pull всех Topnlab clients в User(role=:client). 
  БЛОКЕР: нужно твоё одобрение на mass User.create (потенциально 100s records).
  Вопрос: создавать Users для клиентов без email? (они не смогут логиниться до сбора email)
- Inquiry → CRM sync (push): Inquiry.crm_id сейчас не заполняется.
  Нужен job TopnlabInquirySyncJob (push новых Inquiry в Topnlab как type=order).
- `Property.owner_user_id` currently NULL for all 102 properties.
  НУЖНО запустить `TopnlabOwnerSyncJob.perform_now` в victory-сессии после миграции.

**Чтобы активировать:**
В victory-сессии выполни:
  bundle exec rails db:migrate
  bundle exec rails db:structure:dump  # обновить structure.sql
  bundle exec rails runner "TopnlabOwnerSyncJob.perform_now"  # первый запуск

## A6 — Document intake (статус 17.05.26)

**Архитектурно собрано, в проде НЕ ПРОТЕСТИРОВАНО на реальных фото.**

Pipeline wired end-to-end:
- TG webhook → CF Worker → `/webhooks/telegram` → `Telegram::InboundProcessor#client_photo_intake?` (line 55-56) → `ClientBot::PhotoIntakeProcessor`
- Photo → `ClientDocument.intake!` → `DocumentIntake::ParserJob` (async) → Yandex Vision OCR → `PassportParser`/`InnParser`/`EgrnParser` → `status: :ocr_completed` → staff notification в `TELEGRAM_STAFF_CHAT_ID`
- DLP: filter_parameter_logging + `parsed_data_masked` helpers
- ENV: `YANDEX_AI_STUDIO_API_KEY` + `YANDEX_CLOUD_FOLDER_ID` + legacy aliases `YANDEX_VISION_*` (один SA-ключ обслуживает оба endpoint'а)

Smoke-test'ы прошли (synthetic OCR text + mocked Vision response). Известные tuning-issues
которые проявятся на реальных скан-фото:
- PassportParser regex может путать «Дата выдачи» с «Дата рождения» (берёт первый date pattern)
- FIO extraction чувствителен к OCR-форматированию

**Действие**: пришли тест-фото паспорта в `@anvictorybot` DM → tune regex под реальный output Yandex Vision.

## Артефакты и ссылки

- TZ для этой фазы (если есть): `TZ_VICTORY62_NEWS_CROSSLINK.md` в `/home/q/`
- TG dev/owner чат: `TELEGRAM_STAFF_CHAT_ID = -1003937910508` (можно слать тестовые артефакты)
- Прод: https://victory62.org
- repo-map.md: `.claude/repo-map.md` — пересборка через `rake repo:map` (см. `lib/tasks/repo_map.rake`)

## Delegation hints — когда делегировать в субагентов/скиллы

Полная routing-таблица: `.claude/docs/delegation-map.md` (single source of truth).
Быстрые правила для текущей фазы:

1. **TG-related работа** (`app/services/telegram/*`) → агент `telegram-staff-bot-dev`
2. **PDF design** (Prawn, audit_pdf, кириллица) → агент `pdf-report-designer`
3. **PDF delivery в TG** (markdown → PDF → group) → агент `pdf-telegram-dispatcher`
4. **Topnlab integration / migration** → агент `topnlab-api-expert` (читает `.claude/docs/topnlab/*` лениво)
5. **Любая SEO задача** → агент `seo-content-curator` + skill `victory-seo-checklist`

Когда есть сомнения между двумя агентами — открой `delegation-map.md` § "Domain conflicts".

**НЕ делегировать**: простые `git status`, тривиальные вопросы по коду, typo-фиксы, контекст уже в текущем разговоре.
