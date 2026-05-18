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

## TG work-bot — audit history (Phase 9-13, 50 итераций, до 18.05.26)

Все 5 раундов аудита prod-ready и smoke-verified. HEAD ветки `claude/currency-converter-app-9Ljw6` — `0668472`.

| Phase | Итерации | Тема |
|---|---|---|
| 9 | 1-10 | Auth gaps, DLP regex, race conditions (TaskBatch/mark_completed/NC mkdir/share-links), idempotency (intake + voice), LLM cost cap, Topnlab retry, webhook dedup, async digest, observability |
| 10 | 11-20 | TG anti-spam, timezone confirmation, NC fallback path, HTML escape audit, TaskExtractor quality gate, owner sync collision |
| 11 | 21-30 | SLA stale assignee skip, lead reassignment DM previous, `/reassign`, `/reopen`, CriticalRecipients cascade, AlertThrottle 5min bucket, `/deactivate`, `/resume_batch`, AssignTo audit, `/admin/health` |
| 12 | 31-40 | `/promote+/link` sync role enum, `/demote`, TaskBatch partial dispatch alert, stale inline buttons after `/reassign`, `/stage` history audit, `/help` DM redirect in groups, JSON 401 for health, TopicRegistry drift surfacing, `metadata` pruning helper, TaskExtractor dedup |
| 13 | 41-50 | Director auth gate (`manager_or_director?`), `/assign` reject closed lead, voice batch concurrency guard, `LeadAssignment.with_lock` race, orphan tasks surface, TG 429 retry_after, `crm_sync_error_history`, AlertThrottle counters in health, CriticalRecipients tier visibility, Topnlab API in health |

**Артефакты:**
- Role handbook PDF (12-15 стр) доставлен в @nick4man DM 18.05.26 (message_id 13)
- `/admin/health.json` — operational status snapshot для monitoring (401 без token, JSON-only)

## Phase 14 backlog (после Phase 13, не закрытые adjacent bugs)

Surface'ил Explore-агент Phase 13. Priority sorted:

| Bug | Severity | Где | Notes |
|---|---|---|---|
| `/stage` из closed_won → not-closed (re-open lead) не блокируется | MEDIUM | `lead_stage_transition.rb` | Iter 42 TODO. Полная симметрия с /assign guard. |
| `BotCommandLog` нет `error_message` column — debugging blind | MEDIUM | `models/bot_command_log.rb` + migration | `result='error'` + `error_class` есть, full message нет |
| Multiple managers concurrent `edit_message_text` на одном anchor → last-write-wins | LOW | `lead_assignment.rb` + `lead_stage_transition.rb` | Iter 44 (with_lock) частично mitigates; нужен per-anchor lock |
| `TelegramUser#touch_from_message!` `update_columns` без lock — username/dm_chat_id race | LOW | `telegram_user.rb` | Низкая частота |
| `AdminTokenAuth` хрупкий `respond_to?(:current_user)` — Devise coupling | LOW (cosmetic) | `concerns/admin_token_auth.rb` | Devise off, но guard остался для future |
| Auto-cancel previous voice batch (Iter 43 — reject-only MVP) | LOW (UX) | `voice_intake_processor.rb` | Trade-off; Phase 14 может предложить explicit `[✖️ Отменить предыдущий]` |

## Phase 14+ functionality (по master-plan'у, не аудит)

- **Phase 4** — `DocumentRequirement` + `/doc` команда + TG-DM источник лидов от клиентов + CRM-webhook intake — закрыть оставшиеся каналы intake
- **Phase 5** — `Llm::StaffChatResponder` + `chat_tools/staff/*` + `#ВОПРОС-ОТВЕТ` живой Q&A (NL запросы агентов к боту)
- **Phase 6** — Утренние/вечерние/недельные дайджесты в `#ОТЧЁТЫ ПО SLA` (operational rhythm)
