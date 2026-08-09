# activeContext.md — что сейчас в работе

> Обновляй этот файл вручную или при смене фазы. Здесь — только «живое».

> Актуальность верхних секций: **09.08.26**. Ниже по файлу — датированные
> исторические разборы, они не обновляются.

## Стек — коротко

Rails **8.1.3.1**, Ruby **3.3.6** во всех сессиях (EOL Phase 2 в проде с 08.08.26).
`config.load_defaults` намеренно оставлен на **7.1** — подъём отложен, см.
`project_rails8_eol_phase2` в auto-memory. Подробности — `techContext.md`.

## Ветки и открытые PR

`main` = прод, деплой автоматический. Прямой push в `main` запрещён, только PR.

| PR | Ветка | Что |
|---|---|---|
| #10 | `fix/topnlab-get-ids-nonarray-guard` | get-ids non-array 200 → fetch error, защита каталога от ложного archive |
| #11 | `dev/seo` | A2 Фаза 1 — справочник ЖК, слой данных под лендинги `/zhk` |
| #12 | `fix/seeds-phone-format` | формат телефона в `db/seeds.rb` |

## Текущая фаза

Единой «фазы» нет — сессии идут параллельно по своим направлениям:

- **victory** — надёжность Topnlab-синка и каталога (PR #10), прод-инфра.
- **seo** — Phase A2 programmatic SEO: справочник ЖК → лендинги `/zhk`.
- **upgrade** — EOL закрыт; сейчас долг по спекам и инфра координации сессий.
- **chat** — site-chatbot, мелкие фиксы кодовой базы.

## Параллельные сессии Claude Code

**4 сессии, у каждой свой git worktree** (не общая кодбаза — это изменилось
08.08.26). Идентичность — из marker-файла `.claude-session` в корне worktree,
override через `export CLAUDE_SESSION`.

| Session | Worktree | Ветка | Назначение |
|---|---|---|---|
| **victory** | `/home/q/victory-victory` | feature-ветки | Rails-код, миграции, RSpec, runner |
| **chat** | `/home/q/victory-chat` | `dev/chat` | site-chatbot, `chat_tools/*`, prompts |
| **seo** | `/home/q/victory-seo` | `dev/seo` | meta / JSON-LD / sitemap / Lighthouse |
| **upgrade** | `/home/q/victory-upgrade` | `dev/upgrade` | Rails/Ruby EOL, спеки, session-coord |

🚨 `/home/q/victory` — main checkout и **живой прод-bind-mount** (`victory-web-1`
→ `/app`, code-reload). Правка там уходит на сайт мгновенно. Только deploy/merge.

Границы: write/edit/git — **только внутри своего worktree**. Чужие worktree и
main checkout — read-only диагностика.

Координация: inbox и локи в `~/.claude-shared/` (`inbox/`, `events/`, `locks/`),
`bin/session-status`. См. skill `session-coordination` + agent `session-coordinator`.

## Что сейчас «в фокусе» при работе

1. **Topnlab-синк и целостность каталога**: `app/services/topnlab/`,
   `app/services/mls_sync/`, `app/jobs/topnlab_*`. Инвариант — при неполном
   sweep archive пропускается (`status=partial`), каталог не схлопывается.
2. **Programmatic SEO / ЖК**: `app/models/residential_complex.rb` (dev/seo),
   лендинги `/zhk`, JSON-LD партиалы.
3. **Прод-инфра**: CT 122 на NVMe с 09.08.26; конфликт подсетей sing-box ↔ docker
   устранён (`tun0` → `10.255.255.1/30`). См. auto-memory
   `project_subnet_conflict_singbox_docker`.

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
