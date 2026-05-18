# Phase 4 MVP release notes — 18.05.26

**Tag:** `phase-4-mvp` = commit `8cf3f54` (4D final)
**Branch:** `claude/currency-converter-app-9Ljw6`
**Cumulative:** Phase 9-14 audit (56 iter) + Phase 4 MVP (4 sub-phases)

## TL;DR

Phase 4 переходит от operational audit (Phase 9-14) к product layer. Закрывает 2 из 3 master-plan gaps: **document tracking** + **client TG-DM intake**. Каждая сделка теперь имеет per-deal checklist (16 kinds × 6 lifecycle states × dependency graph), и клиенты могут писать боту в DM напрямую → AI classifier → Inquiry → anchor в #ДИСПЕТЧЕРСКОЙ. Remaining 4 sub-phases (4E webhooks, 4F SLA, 4G AI doc match, 4H multi-channel attribution) перенесены в Phase 4.5 backlog.

## Что сделано (4A-4D)

### 4A — DocumentRequirement foundation
- 16 РФ-real-estate document kinds (паспорт/registration, СНИЛС, ИНН, ЕГРН, кадастр, договор, ипотека, согласие супруга, ППА, свидетельства, оценка, страховка, marital_status, other)
- 6-state lifecycle: `not_requested → requested → received → verified → approved | rejected` с lifecycle helpers (`request!/receive!/verify!/approve!/reject!`)
- Per-kind `SLA_SECONDS` (passport=1d, EGRN=5d, contract=14d) + `overdue_factor` SLA assessor
- `DEPENDS_ON` graph для cascade (contract_sale → egrn + passport_main; mortgage → passport + snils + inn; passport_registration → passport_main; spousal_consent → marriage_certificate)
- `RU_LABELS` (16) + `KIND_ALIASES` (25 RU+EN short-forms)
- Polymorphic anchor (lead_event OR property)
- Phase 4G hook: `received_via_client_document_id` для auto-match A6 OCR'd photos
- Migration с 4 partial indices (unique constraints + SLA assessor hot path)

### 4B — `/doc` command + DocumentChecklist::Manager
- `Tokenizer` — shorthand parser: `passport+` / `passport?` / `contract+verified` / `poa@reject:no_notary` / `=approved`
- 25 aliases (pass, egrn, ипотека, выписка, доверенность, страховка) — RU+EN
- `Manager.apply(tokens)` — atomic transaction с lifecycle transitions
- `Manager.format_status` — HTML group view: ✅ ГОТОВЫ / 📥 ПОЛУЧЕНЫ / ⏳ ЗАПРОШЕНЫ (с SLA countdown) / ❓ НЕ ЗАПРОШЕНЫ / 🚫 ОТКЛОНЕНЫ + progress %
- Authorization: assignee_or_manager? (Phase 13 Iter 41 — manager_or_director? expanded gate)

### 4C — DocumentChecklist::Builder + TemplateRegistry
- 16 templates (flat/room/house/land/commerce/garage × sale/rent + mortgage/evaluation inquiry-flow + default_sale fallback)
- Each template = `{required: [...], optional: {kind => condition_lambda}}`
- Resolve key: `property_type.slug + deal_type` → e.g. `flat_sale`; fallback to `inquiry_type` → `mortgage`/`evaluation`; finally `default_sale`
- `build_context` from `lead.metadata` + `inquiry.metadata` — feeds optional conditions (married → spousal_consent, has_proxy → power_of_attorney, has_mortgage → mortgage_approval cascade)
- Idempotent через savepoint (requires_new: true) — RecordNotUnique caught без abort outer transaction
- DEPENDS_ON cascade: при создании contract_sale → ensure egrn_excerpt + passport_main также созданы
- Wired in `/doc init` команда

### 4D — Client TG-DM intake flow
- `Llm::IntentClassifier` — single LLM call (free-chain :staff_analysis: gpt-oss → qwen → glm → Claude haiku) classifies 8 intents (inquiry/question/appointment/complaint/spam/abuse/test/unclear) с confidence
- `Lead::Intake::TgDmSource` (full impl, заменил Phase 2 stub)
  - Creates Inquiry с `source='tg_dm'`, `client_tg_user_id`, `attribution_source='tg_dm'`
  - Returning-client detection (tg_user_id match за 90d → existing Inquiry)
  - Recursion guard `Thread.current[:skip_workbot_push]` (mirror SiteSource pattern)
- `Telegram::ClientBot::TextIntakeProcessor` orchestrator
  - applies?: private chat + not staff + text not /command + not bot
  - Rate-limit Redis sliding 10 msg/hour per tg_user_id
  - Branching: spam/abuse → silent drop + counter; test/low-confidence → soft greeting; actionable → Lead::Intake → confirm reply
  - Privacy::TranscriptRedactor применяется ДО persist (Phase 7.7 reuse)
- InboundProcessor wired — branch после photo intake, перед voice/QnA
- Migrations: `client_tg_user_id` + `client_phone_e164` + `client_email_norm` + `attribution_source` + 4 partial indices; phone NOT NULL relaxed (Inquiry validation conditional skip для tg_dm source)

## Smoke verification (18.05.26)

**Static + dynamic checks:** все 4 sub-phases ✅
- 4A: 16 kinds, 6 statuses, SLA/DEPENDS_ON/aliases tables populated, lifecycle helpers работают, unique constraint enforced
- 4B: Tokenizer parses 10 token formats (RU+EN), Manager.apply 3-batch transactions, format_status groups by state с SLA suffixes
- 4C: 16 templates available, Builder идемпотентен (re-run = 0 created), optional conditions evaluate via context, DEPENDS_ON cascade triggers prerequisites
- 4D: applies? logic — 5 cases (staff/client/cmd/bot/group); IntentClassifier real-text → intent=inquiry conf=0.9 model=llama-3.3-70b; TgDmSource create + returning-client detection (same Inquiry across calls)

**Health regression:**
- `/admin/health.json` → `status: "ok"`, checks {db, redis, sidekiq, topnlab} = all true

## Phase 4.5 backlog (deferred sub-phases)

| Item | Severity | Notes |
|---|---|---|
| **4E — CRM webhook lead source** | MEDIUM | Webhooks::TopnlabController endpoint, idempotency через Redis event_id 24h dedupe, event replay buffer, webhook health watcher (alert при silent > 4h) |
| **4F — SLA ramping reminders** | MEDIUM | DocumentReminderJob hourly cron, ramping cadence (24h gentle client DM → 72h manager → 7d director), quiet hours respected (Phase 3 pattern), LLM-generated reminder text |
| **4G — AI document classification (A6 link)** | MEDIUM | ClientDocument#after_classified → AutoMatchToRequirement → DocumentRequirement (kind match + confidence threshold + manager-review fallback) |
| **4H — Multi-channel attribution** | LOW | Full match priority (phone E.164 > tg_user_id > email > fuzzy name), confidence-aware merge, anchor card history block for returning client (append vs new LeadEvent) |

Plus Phase 5-6 functionality (StaffChatResponder, daily digests) per master-plan.

## Innovation layer (from design doc)

Из 10 innovations design-doc'а Phase 4 MVP реализовал:
- ✅ Document dependency graph (4A)
- ✅ Per-template optional conditions evaluating against context (4C)
- ✅ AI intent classification single-call (4D)
- ✅ Returning-client detection (basic — 4D, full в 4H)
- ✅ Rate-limited + spam-filtered client intake (4D)

Deferred:
- 4E: Event replay endpoint, webhook health watcher, bi-directional reconciliation cron
- 4F: Smart SLA skip (weekend), LLM-generated reminder text
- 4G: OCR-extracted data verification, composite document recognition (multi-page passport)
- 4H: Anchor card history block, family-phone disambiguation

## Branch hygiene

Branch продолжает continuous-deploy workflow. Tags:
- `phase-13-final` → `0668472`
- `phase-13-cleanup` → `4bd7352`
- `phase-14-final` → `2f7143a`
- `phase-4-mvp` → `8cf3f54`

## Files added/modified

**New (10 files):**
- `app/models/document_requirement.rb`
- `app/services/document_checklist/manager.rb`
- `app/services/document_checklist/tokenizer.rb`
- `app/services/document_checklist/builder.rb`
- `app/services/document_checklist/template_registry.rb`
- `app/services/llm/intent_classifier.rb`
- `app/services/telegram/work_bot/commands/doc.rb`
- `app/services/telegram/client_bot/text_intake_processor.rb`
- `.claude/docs/phase-4-design.md` (~600 lines design doc)
- `.claude/docs/phase-4-mvp-release-notes.md` (this)

**Modified:**
- `app/models/inquiry.rb` (conditional phone validation)
- `app/services/lead/intake/tg_dm_source.rb` (full impl, заменил stub)
- `app/services/telegram/inbound_processor.rb` (Phase 4D branch)
- `app/services/telegram/work_bot/router.rb` (/doc registered)
- `app/services/telegram/work_bot/commands/help.rb` (/doc help entry)

**Migrations (3):**
- `20260528006000_create_document_requirements.rb`
- `20260528007000_add_client_attribution_to_inquiries.rb`
- `20260528008000_relax_inquiry_phone_not_null.rb`
