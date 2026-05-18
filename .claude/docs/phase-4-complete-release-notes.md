# Phase 4 COMPLETE release notes — 18.05.26

**Tag:** `phase-4-complete` = commit `854b8c9`
**Branch:** `claude/currency-converter-app-9Ljw6`
**Scope:** 8 / 8 sub-phases (4A-4D MVP + 4G + 4F + 4H + 4E)

## TL;DR

Phase 4 закрывает **весь product layer** master-plan'а Phase 4: документы (per-deal checklist + automation), все 3 канала intake (site + TG-DM + CRM webhook), AI auto-match A6 OCR → DR, ramping SLA reminders, cross-channel client attribution. Combined с Phase 9-14 audit (56 iter) — **64 governance/product iterations** на TG work-bot ветке.

## Дополнительные подсистемы (после Phase 4 MVP)

### 4G — AI document auto-match (commit `550b681`)
Client фотографирует passport/ИНН/ЕГРН → A6 OCR + parse → AutoMatchToRequirement → DR auto-mark `status='received'` без manual `/doc passport+`.

**Components:**
- `DocumentChecklist::AutoMatchToRequirement` service
  - KIND_MAP: `passport → passport_main, inn → inn, egrn → egrn_excerpt, contract → contract_sale, other → skip`
  - Lead resolution: ClientDocument.inquiry → LeadEvent OR ClientDocument.property → recent Inquiry → LeadEvent
  - Search scope: DR.status IN [not_requested, requested] — NEVER override verified/approved (human review preserved)
  - Confidence routing (threshold 0.7):
    - `>= 0.7` → auto-link via `with_lock + reload + idempotent guard`, DM agent «✅ автопривязан»
    - `< 0.7` → DM agent «❓ требует ручной привязки» + suggested `/doc <alias>+` command
- `DocumentIntake::ParserJob#process` — explicit call после notify_staff (step 7), logged для observability, soft-fail
- Result struct {status, requirement, lead_event, reason} с `success?` predicate

### 4F — SLA ramping reminders (commit `bde21a2`)

**Components:**
- `DocumentChecklist::SlaAssessor` (pure-logic, no side-effects)
  - Tier ladder: Tier 1 (client_gentle) >= 1.0 SLA, Tier 2 (manager_dm) >= 2.0, Tier 3 (director_cascade) >= 3.0
  - Re-window per-tier: 24h / 24h / 48h
  - Skips: final statuses, missing requested_at, weekend (Sat/Sun), rewindow cooldown
- `DocumentChecklist::ReminderSender`
  - Tier 1 → client DM via `Inquiry.client_tg_user_id` (= dm_chat_id для private TG chats)
  - Tier 2 → assigned agent DM («просрочка SLA × N»)
  - Tier 3 → CriticalRecipients cascade (Phase 11 Iter 25 reuse — directors → admins → managers + tier_note)
  - AlertThrottle key per (lead_id, dr_id, tier) — fail-safe re-window
  - post-send: `with_lock` update `last_reminder_at` + `reminder_count` + metadata
- `DocumentReminderJob` ApplicationJob
  - Pre-filter: status IN [requested, received] AND requested_at < 24h ago
  - BATCH_LIMIT=200 safety cap
  - Quiet hours 21-07 MSK → `:quiet_hours_skip` early-return
  - Stats hash logged
- Cron `document_reminder` hourly :00 Moscow

### 4H — Multi-channel attribution (commit `7d01ee1`)
До 4H: client писал site form → потом писал в TG-DM с тем же phone → создавался DUPLICATE Inquiry + новый LeadEvent. Agent видел «новый лид» вместо follow-up.

**Components:**
- `Lead::Intake::ClientResolver` service
  - Match priority (confidence-graded):
    - phone E.164 exact: 0.95
    - tg_user_id exact: 0.90
    - email norm exact: 0.70
  - 90-day window, excludes spam/cancelled
  - Class utilities: `normalize_phone` (10/11-digit Russian with 8→7), `normalize_email` (strip + downcase + RFC valid)
- `TgDmSource#call` — ClientResolver.find заменил inline tg-only lookup
  - matched? → append к LeadEvent.metadata['client_history'] + DM assignee «💬 Сообщение от клиента»
  - не matched → create new Inquiry с все client_* колонки заполнены
- `SiteSource#fallback_inquiry` — backfill client_phone_e164/email_norm/attribution_source. Cross-channel match works в обе стороны.

### 4E — CRM webhook lead source (commit `854b8c9`)
Agent создаёт order в Topnlab UI напрямую → бот получает webhook → создаёт LeadEvent в #ДИСПЕТЧЕРСКОЙ → SLA timer запускается. Closes последний intake channel.

**Components:**
- `Lead::Intake::CrmWebhookSource` (replaced Phase 2 stub)
  - Lookup `BuyerOrder.find_by(crm_id:)` после async sync
  - Phase 4H ClientResolver — cross-channel match (limited by Topnlab masked phone — full PII stays там)
  - Create Inquiry attribution_source='crm_webhook' с budget/area/stage из BuyerOrder
  - Matched → append client_history; не matched → new lead via Lead::Intake.call
- `Webhooks::TopnlabController#create` extended:
  - Idempotency: Redis SETNX EX 5min `topnlab:webhook:<type>:<id>` — handles Topnlab retry storm
  - `mark_webhook_seen!` — `topnlab:last_webhook_at` updated on every successful webhook
  - For type='order': existing TopnlabOrdersSyncJob + NEW `TopnlabCrmIntakeJob` (30s delayed для consistency)
- `TopnlabCrmIntakeJob` async (self-requeue с 30s wait для BuyerOrder eventual sync)
- `TopnlabWebhookHealthJob` daily 08:00 cron:
  - Reads `topnlab:last_webhook_at`
  - > 24h ago → CriticalRecipients cascade alert «🔇 silent webhook»
  - AlertThrottle key `topnlab_webhook_silent` предотвращает spam
- `/admin/health.json` operational counters extended (Phase 4 visibility):
  - `documents_open` — DR.status IN [requested, received]
  - `documents_overdue` — DR.overdue scope
  - `tg_dm_inquiries_24h`
  - `topnlab_webhook_last_seen` (ISO8601 OR nil)
- Inquiry `PHONE_OPTIONAL_SOURCES = %w[tg_dm crm_webhook]` — both legitimately могут иметь nil OR masked phone, validators skip both `presence` и `phone_format`

## Smoke verification

Все 4 sub-phases verified изолированными smoke battery (8-13 tests each).

**Cumulative pipeline test:** Client photo через DM → A6 PhotoIntake → ParserJob OCR → 4G AutoMatch → DR status=received → 4F SlaAssessor (factor=0, no tier needed). Phase 4 end-to-end working.

**Health regression:**
- `/admin/health.json` → `status: "ok"`, all 4 checks (db/redis/sidekiq/topnlab) green
- New Phase 4 fields visible: `documents_open`, `documents_overdue`, `tg_dm_inquiries_24h`, `topnlab_webhook_last_seen`

## Innovation layer (vs original design doc)

10 innovations из design doc — sub-phase tracking:

| Innovation | Status | Sub-phase |
|---|---|---|
| Document dependency graph | ✅ | 4A (DEPENDS_ON cascade) |
| Per-template optional conditions | ✅ | 4C (TemplateRegistry lambdas) |
| AI intent classification (single LLM call) | ✅ | 4D (Llm::IntentClassifier) |
| Returning-client detection | ✅ basic→full | 4D basic / 4H full priority |
| Rate-limited + spam-filtered intake | ✅ | 4D (TextIntakeProcessor) |
| Webhook event replay endpoint | ⏳ Phase 5+ | 4E has hook (Redis buffer pre-stage) |
| Webhook health watcher | ✅ | 4E (TopnlabWebhookHealthJob) |
| Bi-directional reconciliation cron | ⏳ Phase 5+ | future enhancement |
| Smart SLA weekend skip | ✅ | 4F (SlaAssessor) |
| LLM-generated reminder text | ⏳ Phase 5+ | 4F has templated text MVP |
| OCR-extracted data verification (auto-verify leap) | ⏳ Phase 5+ | 4G stops at received |
| Composite document recognition (multi-page passport) | ⏳ Phase 5+ | currently 1 photo = 1 doc |
| Anchor card history block | ✅ | 4H (metadata['client_history']) |
| Family-phone disambiguation | ⏳ Phase 5+ | confidence 0.95 phone auto-merge |

Все critical innovations реализованы. Polish + LLM-generated copy + composite docs — Phase 5+ enhancements.

## Cumulative state across all phases

| Tag | Commit | Phase |
|---|---|---|
| `phase-13-final` | `0668472` | Audit iter 1-50 |
| `phase-13-cleanup` | `4bd7352` | Post-audit cleanup |
| `phase-14-final` | `2f7143a` | Audit iter 51-56 |
| `phase-4-mvp` | `8cf3f54` | Phase 4 MVP (4A-4D) |
| `phase-4-complete` | `854b8c9` | Phase 4 ALL (4A-4H) |

**Branch:** `claude/currency-converter-app-9Ljw6` HEAD = `854b8c9`. Continuous-deploy track продолжается.

## Phase 5+ functionality (master-plan следующее)

- **Phase 5** — `Llm::StaffChatResponder` + `chat_tools/staff/*` + `#ВОПРОС-ОТВЕТ` живой Q&A (NL запросы агентов к боту)
- **Phase 6** — Утренние/вечерние/недельные дайджесты (operational rhythm)
- **Phase 4 polish** — LLM-generated reminder text, composite document recognition, full-phone encrypted sync для CRM cross-channel match
