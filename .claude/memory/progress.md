# progress.md — что в проде, что выключено, что заглушка

> Что реально работает на https://victory62.org на момент написания. Обновляй по факту прод-релизов.

## Status: PRODUCTION — live at https://victory62.org

## Активно в проде

| Подсистема | Статус | Примечания |
|-----------|--------|-----------|
| Landing | ✅ active | `landing#index` корневой роут, full app layout с header/footer, news strip над featured properties |
| Properties (каталог) | ✅ active | TopNLab MLS-синхронизация, поиск/карта/сравнение |
| Investment Audit | ✅ active | audit-engine sidecar анализатор |
| Express valuation | ✅ active | гедонический + bootstrap CI; есть PDF + TG-нотификации |
| Mortgage Calculator | ✅ active | 22 банковские программы |
| News section | ✅ active | webhook-ingest из chat-host; embeddings; swipe-carousel; modal-preview; share/TG CTA |
| Reviews | ✅ active | admin-modеration |
| Chat-bot | ✅ active | с tools (см. `app/services/chat_tools/`) |
| Admin panels | ✅ active (token-guarded) | `Admin::Reviews`, `Admin::Articles` — `?token=$ADMIN_TOKEN` |
| Telegram inbox | ✅ active | приём входящих в site, async photo download |
| TG ↔ victory62 cross-link | ✅ Phase 8 deployed | bilateral notifications, QR codes на обоих отчётах |

## Отключено / заглушки

| Подсистема | Состояние | Когда вернётся |
|-----------|----------|----------------|
| **Devise** (user login) | отключен | future iteration; до этого admin через `?token=$ADMIN_TOKEN` |
| `current_user` | заглушка — всегда `nil` | вместе с Devise |
| `user_signed_in?` | заглушка — всегда `false` | вместе с Devise |
| **Sidekiq workers** | в Gemfile есть, частично активирован | для high-load очередей |
| **Pundit** policies | gem может быть, но политик нет; guards `require_admin!` / `require_agent!` живут в ApplicationController как stubs | при возврате Devise |

## Аспирационные роуты (без контроллеров)

`config/routes.rb` упоминает контроллеры, которые могут отсутствовать в реальности:
`BlogController`, `NewsController` (частично), `SitemapController`, `RobotsController`, `PwaController`, `HealthController`, `ErrorsController`, `ChatController`, `ChatbotController`, `SellController`, `ServicesController`, `FormsController`, `WebhooksController`.

> Проверяй наличие через `ls app/controllers/` перед предположением, что endpoint работает.

## Landing — особенность

`app/views/landing/index.html.erb` исторически был **self-contained** HTML (Tailwind с CDN, без application layout). Сейчас перешли на full app layout (см. activeContext). Если правишь — проверь, что не сломал layout-обёртку.

## Локаль

Всё пользовательское — на **русском**. Поддержка `en` номинальная.

## Известные продовые гарантии

- Ransack-параметры контролируются явным allowlist на `Property` (`ransackable_attributes` и т.д.) — не открывать произвольные поля.
- Soft delete: `User` и `Property` оба используют `deleted_at` + `default_scope { not_deleted }`. Доступ к удалённым — `.unscoped`.
- PostGIS-запросы — raw SQL через `earth_distance` / `ll_to_earth`; не переходим на postgis-AR-адаптер.

## Известные проблемы / tech debt

- **Тесты**: 5 spec файлов на 328 модулей. Покрытие минимальное — рефакторинг крупных файлов рискованный. Агент `test-bootstrapper` + skill `rspec-bootstrap` помогают добавлять coverage инкрементально.
- **Линтинг**: `.rubocop.yml` есть, но rubocop/brakeman/bundler-audit отсутствуют в Gemfile. Phase 3 — добавить.
- **Hot-spots по LOC**: `Property` модель ~710, `DashboardController` ~624, `PropertiesController` ~584. Кандидаты на декомпозицию через агента `rails-architect`.
- **Hedonic valuation overshoot**: ранее наблюдалось завышение (Дубровичи 25.2М ₽ вместо 7М). `property-valuation-expert` агент компенсирует через CMA-аналоги.
- **SEO gaps**: WebSite+SearchAction JSON-LD на главной отсутствует; Yandex.Metrika+GA4 ENV-vars в `.env.example` но не подключены в layout; lazy-loading images не систематический. Phase 2B — quick wins; агент `seo-content-curator` + skill `victory-seo-checklist` подключены.

## Strategic future migration

- **Topnlab → собственная CRM**: миграция стратегическая, инкрементальная (Phase 0-4). См. `futureCrm.md` + `.claude/docs/topnlab/migration-roadmap.md`. Агент `topnlab-api-expert` обслуживает текущую интеграцию + миграционные решения. TG staff bot уже играет роль CRM-канала через `app/services/telegram/work_bot/`.

## TG work-bot — audit history (Phase 9-14, 56 итераций, до 18.05.26)

Все 6 раундов аудита prod-ready и smoke-verified. HEAD ветки `claude/currency-converter-app-9Ljw6` — `2f7143a`.

| Phase | Итерации | Тема | Tag |
|---|---|---|---|
| 9 | 1-10 | Auth gaps, DLP regex, race conditions (TaskBatch/mark_completed/NC mkdir/share-links), idempotency (intake + voice), LLM cost cap, Topnlab retry, webhook dedup, async digest, observability | — |
| 10 | 11-20 | TG anti-spam, timezone confirmation, NC fallback path, HTML escape audit, TaskExtractor quality gate, owner sync collision | — |
| 11 | 21-30 | SLA stale assignee skip, lead reassignment DM previous, `/reassign`, `/reopen`, CriticalRecipients cascade, AlertThrottle 5min bucket, `/deactivate`, `/resume_batch`, AssignTo audit, `/admin/health` | — |
| 12 | 31-40 | `/promote+/link` sync role enum, `/demote`, TaskBatch partial dispatch alert, stale inline buttons after `/reassign`, `/stage` history audit, `/help` DM redirect in groups, JSON 401 for health, TopicRegistry drift surfacing, `metadata` pruning helper, TaskExtractor dedup | — |
| 13 | 41-50 | Director auth gate (`manager_or_director?`), `/assign` reject closed lead, voice batch concurrency guard, `LeadAssignment.with_lock` race, orphan tasks surface, TG 429 retry_after, `crm_sync_error_history`, AlertThrottle counters in health, CriticalRecipients tier visibility, Topnlab API in health | `phase-13-final` |
| 14 | 51-56 | `/stage` reject re-open closed, `BotCommandLog.error_message`, anchor edit lock (LeadStageTransition/SpamCallback/HashtagHandler), TelegramUser touch race, AdminTokenAuth Devise decoupling, voice batch one-click cancel | `phase-14-final` |
| 14 | 57 | `TelegramUser.resolve_identifier(token)` — `@username` ИЛИ `id:N` для staff без `tg_username` (Надежда unblock в voice-intake) | — |
| 14 | 58 | Native TG /-меню через `setMyCommands` + per-user `BotCommandScopeChat` (role-tier) + group-scope (pipeline subset). Source: `config/telegram_bot_commands.yml`. Bulk: `rake telegram:sync_commands`. Реактивно — в `touch_from_message!` (первый /start) + `/promote /demote /link /deactivate`. | — |
| 14 | 59 | **Director self-audit**: голос/текст в DM → query path вместо task_batch. `Telegram::WorkBot::VoiceIntentBranch` (LLM-classifier перед TaskExtractor) + `ChatTools::Staff::DirectorSelfAudit` (новый tool в Registry). Authorship: миграция `lead_events.assigned_by_id/routed_by_id` FK + `Task.created_by_tg/created_in` + `LeadEvent.assigned_by_tg/routed_by_tg/updated_in` scopes. /assign + /route fill originator (FK + metadata history). | — |
| 14 | 60 | **Photo disposition в DM**: manager+ шлёт фото → `WorkBot::PhotoIntakeProcessor` сохраняет `dm_pending_action` (jsonb на TelegramUser) + 3-кнопочный prompt. Callback `PhotoDispositionCallback` дальше: ☁️ облако → 3 цели (общая/лид/сотрудник) → Nextcloud upload + share-link. 📤 staff → text-continuation в `PhotoTaskContinuation` → `Task` с `attachments` jsonb + DM ассайни. TTL 10 мин. | — |

## TG work-bot — product layer (Phase 4 MVP, 18.05.26)

Переход от audit к функционалу. Phase 4 master-plan 8 sub-phases — 4 MVP сделаны (4A-4D), 4 в backlog (4E-4H).

| Sub-phase | Done | Содержание |
|---|---|---|
| 4A — DocumentRequirement foundation | ✅ | Model (16 kinds × 6 statuses), SLA_SECONDS, DEPENDS_ON graph, RU_LABELS, KIND_ALIASES (25), migration с 4 partial indices, polymorphic anchor (lead_event OR property) |
| 4B — /doc command + Manager | ✅ | Tokenizer (10 token forms RU+EN), Manager.apply (transaction lifecycle), format_status (HTML grouped по state + SLA countdown), authorization via assignee_or_manager? |
| 4C — Builder + TemplateRegistry | ✅ | 16 templates (deal_type × property_type + inquiry-driven flows), optional conditions с lambdas, idempotent через savepoint, DEPENDS_ON cascade, /doc init wired |
| 4D — Client TG-DM intake | ✅ | Llm::IntentClassifier (8 intents free-chain LLM), Lead::Intake::TgDmSource (full impl), Telegram::ClientBot::TextIntakeProcessor (rate-limit + spam-drop + soft-greeting), Inquiry attribution columns (client_tg_user_id/phone/email/source), recursion guard, returning-client detection |

**Tag:** `phase-4-mvp` → `8cf3f54`. Release notes: `.claude/docs/phase-4-mvp-release-notes.md`. Design doc: `.claude/docs/phase-4-design.md`.

## Phase 5 + Phase 6 — SHIPPED (18.05.26)

Tag `phase-5-6-complete`. Master-plan Phase 5 (Q&A) и Phase 6 (digests) — done.

**Phase 5 — Staff Q&A enhancements (7.5 уже был built, Phase 5 это polish):**

| Sub | Содержание |
|---|---|
| 5.1 | `ChatTools::Staff::DocumentChecklistStatus` — new staff chat_tool, connects Phase 4 ↔ Phase 5 (agent в qna спрашивает «сколько документов на лиде #145?») |
| 5.2 | Cross-topic @mention — QnaHandler.applies? расширен на любой supergroup topic (кроме quiet whitelist announcements/flood) |
| 5.3 | `Telegram::WorkBot::DmQnaHandler` — staff Q&A в DM. Trigger: private chat + known active staff + non-command text. Wired в InboundProcessor после Router |
| 5.4 | BotCommandLog audit для QnA — dual-track (StaffQuestion + BotCommandLog), args=JSON {question, used_tools, confidence, escalated} |

**Phase 6 — Digests:**

| Sub | Содержание |
|---|---|
| Morning digest (Mon-Fri 08:00) | Kpi::MorningDigest per-staff: greeting + overdue/due today/open leads/SLA warnings + вчерашний recap. Kpi::MorningDigestJob skips weekend. |
| Weekly report (Monday 10:00) | Kpi::WeeklyReport agency-level: header period, totals (tasks/leads/conversion + delta %), top-3 medals, bottom (overdue + suspicious), trend vs prev week. DM managers + directors. |

Existing digests (sохраняются): kpi_agency_digest (18:00 evening), pinned dispatcher_digest (any task mutation), kpi_staff_snapshot (23:55).

## Phase 4 — COMPLETE (8 / 8 sub-phases)

Tag `phase-4-complete` → `854b8c9`. Все 8 sub-phases shipped + smoke-verified
на проде. Release notes: `.claude/docs/phase-4-mvp-release-notes.md` (4A-4D)
+ `.claude/docs/phase-4-complete-release-notes.md` (4E/4F/4G/4H).

| Sub-phase | Done | Содержание |
|---|---|---|
| 4E — CRM webhook lead source | ✅ | Lead::Intake::CrmWebhookSource (replaces Phase 2 stub), TopnlabController idempotency (Redis SETNX) + last_webhook_at tracking, TopnlabCrmIntakeJob async (30s delay для consistency), TopnlabWebhookHealthJob daily silence detection (CriticalRecipients), /admin/health Phase 4 fields |
| 4F — SLA ramping reminders | ✅ | SlaAssessor pure-logic (tier 1/2/3 cadence — 1x/2x/3x SLA × 24h/24h/48h rewindow), ReminderSender (DM client/agent/cascade), DocumentReminderJob hourly cron (quiet hours skip + weekend skip + AlertThrottle dedup) |
| 4G — AI document auto-match | ✅ | AutoMatchToRequirement (KIND_MAP A6 doc_kind → DR.kind, confidence threshold 0.7, with_lock + reload idempotent), ParserJob wired (step 7 после notify_staff) |
| 4H — Multi-channel attribution | ✅ | ClientResolver match priority phone>tg>email (90d window), TgDmSource cross-channel match через ClientResolver, anchor metadata['client_history'] append для returning clients, SiteSource backfill client_phone_e164/email_norm/attribution_source |

**Артефакты:**
- Role handbook PDF (12-15 стр) доставлен в @nick4man DM 18.05.26 (message_id 13)
- `/admin/health.json` — operational status snapshot для monitoring (401 без token, JSON-only)
- Tags: `phase-13-final` (`0668472`), `phase-13-cleanup` (`4bd7352`), `phase-14-final` (`2f7143a`)
- Release notes: `.claude/docs/phase-13-release-notes.md`, `phase-14-release-notes.md`

## TG-активация — awareness backlog (#413f, ops, не код)

После #413f (commits 0e5e685..2495330) phone-only клиенты Topnlab больше
НЕ получают auto-SMS magic-link. Активация работает через 2 пути:
1. **Inbound trigger** — клиент сам пишет `@anvictorybot` → ActivationRequestProcessor → contact-share → match по phone → linked
2. **Admin-shared link** — агент в `/admin/users/:id` генерирует QR/URL и share через любой канал

**НО оба зависят от того что клиент УЗНАЁТ о боте.** Ops-backlog
awareness mechanisms (не код, ответственность маркетинга/sales):

- [ ] **Sales script для агентов**: post-договор / post-показа сказать:
      «Напишите @anvictorybot — поделитесь контактом, увидите кабинет с
      объектами и документами. Бесплатно, без SMS.»
- [ ] **Email-signature** всех агентов: строка «Личный кабинет → @anvictorybot»
      рядом с phone/email
- [ ] **QR-постер в офисе** агентства (печать из admin UI activation panel
      ИЛИ standalone PDF без user-specific token — bot обработает inbound
      flow с любого /start)
- [ ] **`/cabinet/login` landing**: добавить badge «Или через Telegram:
      @anvictorybot» рядом с email/phone форм (low-friction entry point)
- [ ] **Site footer + 404 page**: упоминание `@anvictorybot` как способа
      связи / кабинета
- [ ] **TG-кнопка на property show page**: «Спросить об объекте» → deep-link
      в бота (отдельный feature, пока не приоритет)

## Phase 15+ backlog (после Phase 14)

Phase 14 закрыл все 6 known bugs из Phase 13 Explore-агента. Текущий backlog:

| Item | Type | Notes |
|---|---|---|
| `BotCommandLog.error_message` populate в всех call-sites | MEDIUM | Iter 52 добавил column + CallbacksRouter; whoami/whoami_force/assign_to пока пишут error в args (backward compat). Refactor → дублировать в error_message для structured queries. |
| TaskBatch retry-dispatch | MEDIUM | Iter 33 persists dispatch_failures в parsed_payload — `/retry_dispatch <batch_id>` для re-DM failed assignees |
| Backfill stage_history initial entry для existing leads | LOW | Iter 35 добавил history append, но pre-existing leads имеют пустой `stage_history` |
| TopicRegistry persist record_discovery в YAML | LOW | Сейчас только Redis cache — restart теряет |

## Phase 14+ functionality (по master-plan'у, не аудит)

- **Phase 4** — `DocumentRequirement` + `/doc` команда + TG-DM источник лидов от клиентов + CRM-webhook intake — закрыть оставшиеся каналы intake
- **Phase 5** — `Llm::StaffChatResponder` + `chat_tools/staff/*` + `#ВОПРОС-ОТВЕТ` живой Q&A (NL запросы агентов к боту)
- **Phase 6** — Утренние/вечерние/недельные дайджесты в `#ОТЧЁТЫ ПО SLA` (operational rhythm)
