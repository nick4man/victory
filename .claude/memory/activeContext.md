# activeContext.md — что сейчас в работе

> Обновляй этот файл вручную или при смене фазы. Здесь — только «живое».

## Branch

- Активная ветка: `claude/currency-converter-app-9Ljw6`
- База: `main` (последний sync на момент создания: `02f8783`)
- Состояние: ~229 uncommitted/staged файлов на ветке (большой инкремент в работе)

## Текущая фаза

**Phase 8 — TG ↔ victory62 cross-link (Rails side)**

Последние коммиты по теме:
- `98c5477 Phase 8: cross-link TG ↔ victory62 — Rails side`
- `071563c Express PDF + TG notifier + QR codes on both reports`
- `b5f5640 Phase 7: News UX — embeddings, share/TG CTA, swipe carousel, modal preview`
- `3ac78a2 Fix: TG inbox photo download must be async`
- `832f06b Production: status PROD + TG inbox + deploy docs`

## Параллельные сессии Claude Code

Работают **на одной кодбазе** `/home/q/victory` (минимум три сессии в проекте):

- **session «victory»** — основная разработческая. Rails dev-сервер (порт 3000) уже поднят. chruby/rbenv с Ruby 3.2.2 активирован. Сюда — Edit/Write/RSpec/runner, миграции, рефакторинги, тесты.
- **session «chat»** — **site-chatbot разработка** + планирование, документы, TG-доставка. Системный Ruby 3.3 — `bin/rails runner` НЕ работает. Сюда — Plan, AskUser, curl к TG Bot API напрямую, prompt-engineering для `chat_responder.rb` + `chat_tools/*`.
- **session «seo»** — SEO-работа: meta-теги, JSON-LD, sitemap/robots, friendly_id, контент-SEO, lighthouse-аудиты. Эта сессия работает с тем же codebase; для Rails-изменений (helpers, view-partials, controllers) предпочитает hand-off в victory-сессию (там dev-server и тесты).

Координация: Memory-bank, `.mcp.json`, `.claude/agents/`, `.claude/skills/` проектные → все сессии видят одинаковую конфигурацию. Для одновременных правок одного файла — lock-file pattern (см. skill `session-coordination` и agent `session-coordinator`).

Session-domain split (рекомендуемый):
- Rails-код / migrations / specs → **victory**
- Site-chatbot tools / prompts / LLM chain → **chat**
- SEO meta / JSON-LD / sitemap / content-SEO → **seo** (Rails-side изменения — hand-off в victory)
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
