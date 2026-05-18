# Phase 4 — Design Document

> "The TG bot becomes the single conversational entry-point for the entire customer journey — replacing the CRM-UI, email, and phone calls as primary touchpoints."

## Vision

Phase 9-14 закрыли **operational gaps**: race conditions, governance, observability. Phase 4 закрывает **product gaps** — три самых важных входных канала, которые сейчас работают наполовину или вручную:

1. **Документы** — каждая сделка требует 10-20 документов (паспорт, СНИЛС, ЕГРН, договоры, согласия). Сейчас агент держит этот checklist в голове / Excel / напоминалках. Это #1 источник просрочек.
2. **Клиент → бот → агент** — клиенты пытаются написать боту напрямую (вместо формы), бот их игнорирует или routes в inbox. Мы теряем 30-40% «тёплых» обращений.
3. **CRM → бот** — агент создаёт order в Topnlab UI напрямую (старая привычка), бот не знает. Лид в CRM есть, в нашей системе — нет. Двойная работа + ошибки.

## Design philosophy

**«Stateful conversation, stateless commands»** — бот это memory-слой между человеческими диалогами и каноническим CRM. Клиент не заполняет форму; клиент пишет. Агент не вводит данные; агент подтверждает структурированный extract.

Это позиционирует бот как **LLM-mediated translation layer** между natural-language и database. Не просто notification system — primary input/output surface для бизнеса.

## Best-practice survey (мировой контекст)

### Document fulfillment (sub-area 1)

**Изученные системы:**
- **Compass / Compass One** — persistent task-list в client portal, per-deal templates, status: not-started → started → submitted → reviewed → approved. SLA: 5 дней по умолчанию, escalate to lead agent.
- **Glide** (acquired by Compass) — mobile-first photo capture, OCR + auto-detect document type, intelligent prefill from prior deals. Innovation: «smart packets» — composite documents (passport_main + registration + selfie = «ID package»).
- **DocuSign Rooms for Real Estate** — integrates с esignature + audit trail per document version.
- **Российский контекст (Циан/ДомКлик/Этажи)** — embedded в CRM, без отдельного клиент-portal. Документы по email или мессенджер ad-hoc — нет structured tracking.

**Принципы которые берём:**
1. **Per-deal checklist** (не generic) — deal_type (sale/rent/mortgage) × property_type (квартира/дом/коммерция) → template
2. **6-state lifecycle:** `not_requested → requested → received → verified → approved → rejected` (verified ≠ approved — receipt vs legal review)
3. **Per-document SLA** (паспорт мгновенно; ЕГРН — 5 дней; адвокат-review — 14 дней)
4. **Escalating reminders** (24h gentle → 72h firm → 7d director)
5. **Versioning** для документов которые могут переоформляться (договор vAmd1, vAmd2)

**Наши innovations:**
- **Document dependency graph** — `passport_main` → triggers `passport_registration` request automatically. `egrn_excerpt` → `cadastral_passport` (parallel). `contract_sale` requires both ЕГРН + spousal_consent (если flagged).
- **Composite document recognition** — клиент пришёл фото паспорта (3 страницы pages 2-3, 4-5, 14-15) → AI распознаёт как 3 части single document и связывает.
- **Per-client document reuse** — если client уже сделал ID-package на прошлой сделке (в нашей системе) → бот предлагает «использовать прошлые документы?» вместо повторного запроса.

### Client conversational intake (sub-area 2)

**Изученные системы:**
- **Houwzer / Redfin** — chat widget на сайте, conversational lead capture (no form). LLM-driven intent recognition.
- **PropertyGuru** — WhatsApp bot для inquiry routing + qualification.
- **Asana / Linear** — структурированный async inbox: первое сообщение от unknown → triage queue, manager assigns.

**Принципы которые берём:**
1. **Multi-modal intake** (text + photo + voice — Phase 7 voice infra reuse)
2. **Intent classification** перед routing (buy/sell/rent/inquiry/spam) — LLM single call
3. **Soft qualification** (budget range, area, urgency) до lead-announce — но НЕ блокирует, мягко спрашивает
4. **Privacy by default:** PII-redaction в transcript (Phase 7.7 reuse), full PII только в БД с filter_parameter_logging

**Наши innovations:**
- **Persistent client identity** — клиент `tg_user_id=X` → бот помнит его прошлые conversations через `Inquiry.client_tg_user_id` index. Returning client → reply «👋 С возвращением, Анна. По прошлому inquiry #142 (Канищево, 2-комн) — есть новости?»
- **Anchor card threading** — first message = create Inquiry + LeadEvent + anchor. Subsequent messages от того же tg_user_id = append to anchor `metadata['client_history']` + DM assigned agent с новым сообщением.
- **Graylist для anti-spam** — новый tg_user_id → 24h в graylist, AI-intent classifier (spam/genuine), manager approves → whitelist. Spam → silently dropped + counter в `/admin/health.operational.client_intake_spam_24h`.
- **Voice intake parity** — клиент может присылать voice сообщение, не только текст. Reuse Phase 7 transcription. Director-only voice intake остаётся для распределения задач (другой path).

### CRM webhook reverse-sync (sub-area 3)

**Изученные системы:**
- **Twilio webhooks** — HMAC signature, retry queue, idempotency keys.
- **Salesforce Platform Events** — event-driven CDC с replay capability.
- **Stripe webhooks** — signed payload, dedupe by `event.id`, replay endpoint в dashboard.
- **Topnlab specific** — webhooks НЕ signed, доставка без retry-guarantee (per `.claude/docs/topnlab/`).

**Принципы которые берём:**
1. **IP allowlist + shared secret** (since Topnlab doesn't sign) — header `X-Topnlab-Secret`
2. **Idempotency:** dedupe by Topnlab order_id + event_type + 24h Redis SET NX EX
3. **Async processing:** ACK сразу (200 OK), enqueue Sidekiq job

**Наши innovations:**
- **Event replay endpoint** — `/admin/webhook_replay?event_id=...` — admin может перепроиграть пропущенное событие из Redis buffer (24h retention).
- **Webhook health monitoring** — `LastWebhookSeen` tracker; если последний Topnlab webhook > 4ч назад → alert директору (Iter 25 cascade). Detect silent webhook failure без выяснения via API polling.
- **Bi-directional reconciliation cron** — раз в час `TopnlabReconciliationJob` сравнивает `Property.where(created_at > 24h.ago)` (наши) vs Topnlab `get_ids(action: 'sale')` (CRM source-of-truth). Mismatch → alert + auto-import missing.

### Multi-channel attribution (sub-area 4 — innovation)

Это **новая capability**, не в исходном master-plan'е. Но critical для unified customer journey.

**Изученные системы:**
- **Segment.com** — identity resolution graph (anonymous_id → user_id → email → phone)
- **Salesforce Customer 360** — golden record per customer across orgs
- **Российский HubSpot-clone (АmoCRM)** — phone-based dedup, manual merge UI

**Наши innovations:**
- **Match priority:** phone (E.164) > tg_user_id > email > name+address fuzzy
- **`Inquiry#find_client_continuation`** — при новом intake ищет existing inquiry за 90d по match priority
- **Anchor card history block** — если returning client → новое сообщение добавляется в `metadata['client_history']` в existing anchor card вместо создания нового LeadEvent. Agent видит full context в одной карточке.
- **Confidence-aware merge** — exact phone match = auto-merge; fuzzy name = suggest merge to manager
- **«Client Memory» в boot** — при first inbound от tg_user_id, bot greets: «Привет, Анна. Помню тебя — прошлая сделка по ул. Лесная 12 (закрыта в марте). По чему сейчас?» (если есть history)

## Sub-iterations (8 phases)

### 4A — DocumentRequirement foundation
**Files:**
- `db/migrate/_create_document_requirements.rb`
- `app/models/document_requirement.rb`
- `lib/document_requirement/template.rb` (per-deal-type checklists)

**Model:**
```ruby
class DocumentRequirement < ApplicationRecord
  belongs_to :lead_event, optional: true
  belongs_to :property, optional: true     # alternative anchor
  belongs_to :requested_by, class_name: 'TelegramUser', optional: true
  belongs_to :verified_by, class_name: 'TelegramUser', optional: true
  belongs_to :received_via_client_document,
             class_name: 'ClientDocument', optional: true # Phase 4G link

  enum :kind, { 
    passport_main, passport_registration, snils, inn,
    egrn_excerpt, cadastral_passport, contract_sale, mortgage_approval,
    spousal_consent, power_of_attorney, marriage_certificate,
    appraisal_report, insurance_policy, marital_status, other
  }, prefix: true # 15 kinds

  enum :status, {
    not_requested, requested, received, verified, approved, rejected
  }, prefix: true

  # SLA в секундах per-kind — different docs have different urgency:
  SLA_SECONDS = {
    'passport_main' => 1.day, 'passport_registration' => 2.days,
    'snils' => 2.days, 'inn' => 2.days,
    'egrn_excerpt' => 5.days, 'cadastral_passport' => 5.days,
    'contract_sale' => 14.days, 'mortgage_approval' => 14.days,
    'spousal_consent' => 5.days, 'appraisal_report' => 7.days
  }
  
  # Dependency graph: kind → required prerequisites
  DEPENDS_ON = {
    'passport_registration' => ['passport_main'],
    'contract_sale' => ['egrn_excerpt', 'passport_main'],
    'spousal_consent' => ['marriage_certificate']
  }
  
  scope :open, -> { where(status: %w[not_requested requested received]) }
  scope :overdue, -> { open.where('requested_at < ?', Time.current - 24.hours) }
  
  # soft-delete + composite unique index (lead_event_id, kind, deleted_at)
end
```

**Innovations:**
- `kind` enum с 15 values — comprehensive РФ-real-estate document taxonomy
- `SLA_SECONDS` per-kind — different urgency tiers
- `DEPENDS_ON` graph — auto-trigger cascade
- Polymorphic anchor (lead_event OR property) — для cases когда property без active lead но требует appraisal

### 4B — `/doc` command + DocumentChecklist service
**Files:**
- `app/services/telegram/work_bot/commands/doc.rb`
- `app/services/document_checklist/manager.rb`

**Usage patterns:**
```
/doc                              # show full checklist для текущего лида
/doc passport+                    # отметить passport_main received
/doc passport-                    # mark missing (revert)
/doc snils? @ivan                 # request snils из client + DM @ivan (assignee)
/doc contract+verified            # mark verified (status leap from requested→verified, agent attested)
/doc egrn=approved                # admin/lawyer override to approved
/doc bulk passport+ snils+ inn+   # batch mark several
```

**Parser:**
- `<kind>` `+` = received, `-` = not_requested, `?` = requested, `=approved` = verified→approved leap, `+verified` = received+verified, `@user` = assign requested_by
- Aliases: `pass` → `passport_main`, `egrn` → `egrn_excerpt`, etc. (russian shorthand registry)

**Output (`/doc` без args):**
```
📋 Документы по лиду #145 (Анна, Канищево)

✅ ПОЛУЧЕНЫ:
  • Паспорт (основной) — verified by @ivan, 18.05 14:32
  • СНИЛС — received 17.05

⏳ ЗАПРОШЕНЫ:
  • ЕГРН-выписка — запрошен 16.05 (SLA: до 21.05) ⚠️ просрочка 12ч
  • Договор купли-продажи — запрошен 17.05 (SLA: до 31.05)

❓ НЕ ЗАПРОШЕНЫ:
  • Согласие супруга (если требуется)

Прогресс: 2/5 received, готовность сделки: 40%
```

### 4C — Auto-instantiate checklist from deal context
**Files:**
- `app/services/document_checklist/builder.rb`
- `lib/document_checklist/templates/*.yml`

**Templates (YAML):**
```yaml
# lib/document_checklist/templates/apartment_sale.yml
required:
  - passport_main
  - snils
  - egrn_excerpt
  - contract_sale
  - inn
optional:
  - spousal_consent     # если client.metadata['married'] == true
  - power_of_attorney   # если есть proxy
```

**Builder logic:**
1. Read `lead.lead_ref.property_type` + `deal_type` (sale/rent)
2. Load template `apartment_sale.yml`
3. For each `required` → create DocumentRequirement(status='not_requested')
4. For each `optional` → check trigger condition в `lead.metadata` (e.g., married → spousal_consent)
5. Auto-instantiated checklist готов

**Innovation:**
- **Dependency cascade trigger:** когда `passport_main.status='received'` → auto-create `passport_registration` (DEPENDS_ON inverse)
- **Per-client memory:** если client уже had `passport_main verified` в Inquiry за прошлый год → suggest auto-import (manager confirms)

### 4D — Client TG-DM intake flow
**Files:**
- `app/services/lead/intake/tg_dm_source.rb` (NEW)
- `app/services/llm/intent_classifier.rb` (NEW — single LLM call)
- `app/services/telegram/inbound_processor.rb` (extend)
- `app/services/telegram/work_bot/client_anchor_threader.rb` (NEW)

**Flow:**
1. Inbound DM message, `tg_user_id` НЕ в `TelegramUser` (не staff)
2. `ClientAnchorThreader.lookup(tg_user_id)` — есть ли активный `LeadEvent` за 90d с client_tg_user_id?
3a. **Yes (returning):** append to anchor metadata, DM agent с new message context
3b. **No (new):** graylist check (24h newcomer counter), `IntentClassifier.call(text)` → if spam/abuse, drop; иначе create Inquiry + Lead::Intake → anchor в #ДИСПЕТЧЕРСКОЙ

**Anti-spam:**
- Rate-limit: > 5 messages in first 10 min from new user → flag, hold for manager review
- IntentClassifier prompt: classify as `inquiry|spam|abuse|test|unclear`. Free LLM chain (Phase 9 Iter 6 cheap-first).
- Spam → BotCommandLog row + counter в health endpoint

**Innovation:**
- **Conversational qualification:** перед announce LeadEvent, бот может задать 1-2 уточняющих вопроса (LLM-driven): «Покупать или арендовать?», «Какой бюджет ориентировочно?». Только если confidence < 0.6, иначе announce immediately.
- **Persistent client identity:** Inquiry.client_tg_user_id index — все DM от того же tg_user_id linked. `metadata['inquiry_thread']` — array of inquiry_ids across time.

### 4E — CRM webhook lead source
**Files:**
- `app/controllers/webhooks/topnlab_controller.rb` (extend)
- `app/services/lead/intake/crm_webhook_source.rb` (NEW)
- `app/jobs/topnlab/event_replay_job.rb` (NEW)

**Endpoint:**
- `POST /webhooks/topnlab/events` — body `{event_id, event_type, payload: {order_id, ...}}`
- Auth: `X-Topnlab-Secret` header check vs `ENV['TOPNLAB_WEBHOOK_SECRET']` (mutual config с Topnlab side)
- Dedupe: Redis SET NX EX `topnlab:event:#{event_id}` TTL 24h
- ACK 200 immediately, async via Sidekiq

**Events handled (MVP):**
- `order_created` → Lead::Intake::CrmWebhookSource → новый LeadEvent
- `order_stage_changed` → LeadStageTransition (mirror в наш state)
- `order_status_closed` → /close logic
- `note_added_external` → Notification + anchor card update

**Innovation:**
- **Event replay buffer:** все events за 24h в Redis ZSET `topnlab:events:buffer`. `/admin/webhook_replay?event_id=...` — admin replay. Test endpoint `/admin/webhook_test` — synthesize event для verification.
- **Webhook health watcher:** cron каждый час, если `LastWebhookSeen.last > 4h.ago` → CriticalRecipients alert (Iter 25 cascade). Surface в `/admin/health.operational.topnlab_webhook_silent_since`.

### 4F — SLA ramping reminders
**Files:**
- `app/jobs/document_reminder_job.rb` (NEW)
- `app/services/document_checklist/sla_assessor.rb` (NEW)

**Cron:** каждый час (hourly), не каждые 5 min (документы — slower SLA than leads).

**Logic:**
1. `DocumentRequirement.open.where('requested_at < ?', 24.hours.ago)` — base set
2. Per-record, compute `overdue_factor = (now - requested_at) / SLA_SECONDS[kind]`
3. Cadence:
   - `overdue_factor >= 1.0 && last_reminder_at NULL OR > 24h ago` → gentle DM client (если есть `client_tg_user_id`)
   - `overdue_factor >= 2.0 && last_reminder_at > 24h ago` → manager DM (assignee)
   - `overdue_factor >= 3.0 && last_reminder_at > 48h ago` → director DM (CriticalRecipients cascade)
4. Update `last_reminder_at` + `reminder_count` per DocumentRequirement

**Quiet hours:** 21:00-07:00 MSK — defer to next 07:00 via Sidekiq scheduled (Phase 3 pattern reuse).

**Innovation:**
- **Smart skip:** если DocumentRequirement.requested_at в weekend → SLA pauses (no reminders weekend, weekend doesn't count toward SLA).
- **Context-aware reminder text:** LLM-generated reminder message based on document type + client_history. Не template-spam.

### 4G — AI document classification (link to A6)
**Files:**
- `app/services/document_intake/auto_match_to_requirement.rb` (NEW)
- `app/services/document_intake/parser_job.rb` (extend — call AutoMatch on success)

**Pre-existing infra (A6 — already deployed):**
- ClientDocument intake via TG photo → Yandex Vision OCR → LLM-parse → `parsed_data`
- `ClientDocument.document_kind` enum (already includes passport, snils, inn, egrn etc.)

**New layer:**
1. `ClientDocument.after_classified` callback → `AutoMatchToRequirement.call(client_document)`
2. Match strategy:
   - `client_document.tg_chat_id` → `Inquiry.client_tg_user_id` → `LeadEvent` → `DocumentRequirement.where(kind: matched_kind, status: ['not_requested', 'requested'])`
   - confidence > 0.8 → auto-link, set status='received', received_via_client_document_id
   - 0.5-0.8 → propose to assignee DM «❓ Похоже на passport — привязать к лиду #145?»
   - < 0.5 → manager review queue

**Innovation:**
- **OCR-extracted document data** уже в `parsed_data` — auto-verify (passport_main number matches CRM `client.passport`?). If yes → leap to `status='verified'`.
- **Multi-page detection:** клиент send'ит 5 фото подряд от того же tg_user_id за 60 сек — heuristic: «passport pages», group as composite. AutoMatch создаёт один passport_main с multi-page reference.

### 4H — Multi-channel attribution
**Files:**
- `db/migrate/_add_client_attribution_to_inquiries.rb` (NEW)
- `app/services/lead/intake.rb` (extend — find_or_create_inquiry with dedupe priority)
- `app/models/inquiry.rb` (add client_tg_user_id, client_phone_e164 indices)

**New Inquiry columns:**
- `client_tg_user_id:bigint` (nullable, indexed)
- `client_phone_e164:string` (normalized phone, indexed)
- `client_email:string` (normalized lower, indexed)
- `attribution_source:string` (enum: 'site_form', 'tg_dm', 'manual', 'crm_webhook')

**Deduplication priority:**
```ruby
def find_or_create_inquiry(phone:, tg_user_id:, email:, source:)
  match = Inquiry.where('created_at > ?', 90.days.ago)
                 .where('client_phone_e164 = :p OR client_tg_user_id = :t OR LOWER(client_email) = :e',
                        p: normalize_phone(phone), t: tg_user_id, e: email&.downcase)
                 .order(created_at: :desc)
                 .first

  if match
    # Returning client — append to existing
    augment_existing(match, source: source, ...)
  else
    # New client
    Inquiry.create!(...)
  end
end
```

**Innovation:**
- **Anchor card history block:** when returning client message arrives, instead of new LeadEvent — append to existing anchor's `metadata['client_history']`. Agent sees continuous conversation thread в одной карточке.
- **Confidence-aware merge:** phone exact match = auto-merge. Email match + different phone = suggest merge to manager (rare but happens: clients changing phones).
- **Family phone disambiguation:** если same phone matches 2+ active inquiries (rare — family member sharing phone) → flag for manager «📞 Phone +7 999 conflicts with @ivan_petrov's lead #142, also yours — confirm same client?»

## Risk analysis

| Risk | Mitigation |
|---|---|
| **Spam от unknown TG users** | Graylist 24h + AI intent classifier + manager whitelist |
| **AI document false positives** | Confidence thresholds + manager review queue для unsure |
| **Topnlab webhook auth (no native signing)** | IP allowlist + shared secret header + rate-limit |
| **Multi-channel false merge** (same phone = different people) | Confidence levels — exact phone auto, fuzzy manual |
| **PII exposure в chat history** | Privacy::TranscriptRedactor (Phase 7.7 reuse) на все intake paths |
| **Checklist completeness drift** (template outdated) | Template-version field, audit log on changes, gradual migration |
| **Document SLA gaming** (agent marks received before actually verifying) | suspicious_flag + agent_time_to_receive < 60s → review |
| **Hot-path performance** (every DM message → DB lookup) | Redis cache for `client_tg_user_id → lead_event_id` mapping |

## Sequencing recommendation

```
4A foundation (model + migration)        ← block-free, can start NOW
↓
4B /doc command (uses 4A)
↓
4C auto-instantiate (uses 4A + 4B)
↓
4D client DM intake ─┐
4E CRM webhook   ──┼─── parallel after 4A
4F SLA reminders ──┘
↓
4G AI classification (uses 4A + A6 existing + 4D)
↓
4H attribution (uses 4D — needs Inquiry columns)
```

Recommend **start sequential 4A → 4B → 4C → then parallel 4D/4E**. Skip 4F (low priority) until 4A-4C live. 4G uses existing A6 — can be deferred. 4H is incremental enhancement.

## Phase 4 MVP scope (this round)

**Must-have (4A + 4B + 4C):** Document tracking working end-to-end. /doc command, checklist auto-create.
**Should-have (4D + 4E):** Client DM intake + CRM webhook — new lead channels.
**Could-have (4F + 4G + 4H):** Polish + AI + attribution — can ship incrementally after MVP.

**Out of scope (Phase 5+):**
- eSignature integration (DocuSign-equivalent)
- Lawyer approval workflow
- Document versioning (vAmd1, vAmd2)
- Document embedding search

## Innovation summary (what's uniquely ours)

1. **Document dependency graph** (DEPENDS_ON) — auto-cascade requirements
2. **Per-client document reuse** across deals (using past Inquiry history)
3. **Composite document recognition** (multi-page passport)
4. **Conversational qualification** для client intake (LLM-driven вопросы)
5. **Anchor card history block** — returning client appends to existing card
6. **Event replay endpoint** + webhook health watcher
7. **Bi-directional reconciliation cron** Topnlab↔ours
8. **Smart SLA skip** weekend + LLM-generated reminder text
9. **OCR-extracted data verification** auto-jump к status='verified'
10. **Confidence-aware merge** для multi-channel attribution

These together position TG bot как **AI-mediated single source of truth** для customer journey — превосходит CRM-UI в скорости + reduces handle time для агентов в 2-3 раза.
