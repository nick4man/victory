# activeContext.md — что сейчас в работе

> Обновляй этот файл вручную или при смене фазы. Здесь — только «живое».

> Актуальность верхних секций: **13.10.26** (cutover прода выполнен, фаза 3
> конвейера настроена и проверена end-to-end; дальше — первая CI-выкатка,
> окно B и фаза 4).
> Ниже по файлу — датированные исторические разборы, они не обновляются.

## Состояние на 12.10.26 (вечер) — cutover выполнен, конвейер замкнут

- **Прод на образах** (cutover 1.0, окно A, 11:49–11:52 MSK): web/sidekiq —
  `ghcr.io/nick4man/victory-web:sha-f613c87`, zhk-registry — `1.0.0`
  (`ZHK_TAG=1.0.0` в `.env.deploy`), db не тронута. Простой ≈1 мин.
  **`/home/q/victory` больше НЕ живой bind-mount** — это ops-каталог: правки
  файлов там на сайт не попадают. Откат — `bin/rollout <предыдущий тег>`.
  Записано в `docs/runbooks/cutover-1.0.md`.
- **Фаза 3 в main (#124) и настроена**: `deploy.yml` + `bin/prod-gate`.
  Environment `production` — required reviewers (владелец), секреты `PROD_SSH_KEY`
  + `ALERT_TG_*`, переменные `PROD_HOST`, `PROD_SSH_USER`; ключ `prod-ci` на
  victory с forced command, связка проверена боем. Victory снаружи по SSH
  недоступен — раннер ходит через bastion на vps1 (ключ `bastion-ci`,
  `permitopen="10.10.0.122:22",no-pty`) и дальше по WG. 13.10: bastion-ключ
  установлен на vps1, весь путь проверен боем (ProxyJump → `prod-gate` отвечает,
  невалидный тег отклонён). Выкатка: Actions → Deploy
  production → Approve. Runbook — `docs/runbooks/deploy-pipeline.md`.
- ⚠️ Урок дня: `rollout bogus` — **валидный** тег по regex gate; «тестовая»
  команда из runbook реально выкатила локально собранный образ (благополучно,
  перевыкатка на sha-тег сразу после). Пример в runbook исправлен.
- Осталось по плану конвейера (`docs/ci-cd-pipeline-plan.md`): первая реальная
  выкатка через Deploy production (прогон с Approve), окно B (переезд
  конвейера новостей с chat — отдельное окно), фаза 4 (гигиена:
  strong_migrations, спек обхода GET-маршрутов, crontab в репо, ADR «почему не
  Kamal», чистка корневых *.md).
- Баг-хвост P2 прежний, плюс новое: предупреждение prod-mark «в прод-чекауте N
  изменённых файлов» после cutover потеряло смысл (сайт работает из образа) —
  кандидат на уборку.

## Состояние на 11.10.26 — release 1.0 в main, конвейер поставки фазы 1+2 зелёный

**Код в main** (все PR прошли обязательное code-review; мержи #109–#121):
- **Release 1.0** (#109, + #112 P0-фиксы, + #113 P1-фиксы): единый `docker-compose.yml`,
  multi-stage production-образы (web/conveyor/publisher/zhk-registry), конвейер
  новостей перенесён в монорепу (`services/urgent-news-collector` + `content-publisher`),
  schema-SQL в git (`*.sql` был в `.gitignore` — добавлено исключение).
- **CI фаза 1** (#110): `build.yml` — сборка в GHCR на push в main (тег `sha-<7>`,
  релизный `<VERSION>` при bump), zeitwerk:check в production до push, prep-джоба
  по diff. Безопасность: `bin/release --from-ci` не перезаписывает VERSION-тег.
- **Фаза 2** (#111 + #117–#121): staging-стенд + автовыкатка + smoke/Playwright.

**Staging-стенд (работает, зелёный end-to-end):**
- Хост: **vps1** (`ssh deploy`, `vps1.victory62.org`, внешний `93.95.229.192`), НЕ victory.
  victory снаружи по SSH недоступен (внешний :22 роутера → vps1).
- Сеть: WireGuard, vps1 = `10.10.0.160` (интерфейс `sod`), victory = `10.10.0.122`.
  Web слушает `WEB_BIND=10.10.0.160:3002` **только** (публичный доступ закрыт).
- Traefik (vds): роутер `staging-victory` → `http://10.10.0.160:3002`, middleware
  `staging-basic-auth` (bcrypt, отдельный от `basic-auth`). Логин/пароль — в секрете
  репозитория `STAGING_BASIC_AUTH`.
- Автовыкатка: merge в main → build.yml → `deploy-gate` по SSH (forced command,
  ключ `staging-ci` умеет ТОЛЬКО `staging-rollout`, прод-кейс удалён) →
  `bin/staging-rollout` на vps1 → pull из GHCR → health → smoke; затем внешний
  smoke + Playwright (`tests/visual/staging-smoke.spec.ts`, 10/10).
- Данные: ключ `victory-dump-fetch` (forced `sftp-server -d /var/backups/victory/db`
  на victory) → дамп в `~/staging-dumps/db` на vps1 → `bin/staging-reset`
  (config `~/.staging-backup.env`, passphrase `~/.victory-backup-passphrase`).
  Санитизация `users.tg_user_id` — работает.
- Чекаут на vps1: `~/victory`, main; журнал выкатки `.env.staging-deploy`.

**Прод НЕ переведён на release 1.0** — cutover pending:
- Прод-стек по-прежнему на старой схеме; живой чекаут — **`chat:/opt/.openclaw/victory`**
  (не victory-хост!). Порядок — `docs/runbooks/cutover-1.0.md`: этап A (`bin/rollout`
  из GHCR + `bin/smoke`, минуты простоя), этап B (переезд конвейера: news-db из
  schema-SQL, перелив данных, критерий `[news_ingest] OK`).

**Баг-хвост (P2, не блокеры):** `bin/rollout` pull `--ignore-buildable` не тянет
образы служб; publisher scheduler — tz-баг + карточки согласования только на старте
+ Markdown-экранирование; build.yml StrictHostKeyChecking accept-new (P3: пин в секрет);
runbook `staging.md` местами говорит «хост victory»; `xuwenhao/kimi-code-action@v0`
не запинен на SHA.

**Kimi-бот в Actions**: `kimi.yml` (триггеры `@kimi` в issue/PR-комментариях и ревью)
работает, отвечает sticky-комментарием. Ветки бота — `kimi/*`. Без `PLAYWRIGHT_BASE_URL`
smoke-спек в `vr:test` пропускается.

**Токены**: `gh` (OAuth) имеет `repo, workflow, read:packages` — проверка образов в
GHCR через него. `GH_API_TOKEN` (fine-grained, в `~/.zshenv`) — полный доступ к репо,
но **Packages API ему закрыт архитектурно** (документированное ограничение GitHub).

## Стек — коротко

Rails **8.1.3.1**, Ruby **3.4.10** в worktree-сессиях (Ruby 3.3 EOL 31.03.27; прод-контейнеры получают 3.4.10 при пересборке образов).
`config.load_defaults` намеренно оставлен на **7.1** — подъём отложен, см.
`project_rails8_eol_phase2` в auto-memory. Подробности — `techContext.md`.

## Ветки и открытые PR

`main` = прод. Прямой push в `main` запрещён, только PR. CD: merge → сборка
образов в GHCR + автовыкатка на staging; прод — `bin/rollout` вручную.

| PR | Ветка | Что |
|---|---|---|
| #107 | `claude/crm-cards-12-qa-tail` | fix(crm_cards): хвост замечаний QA-прогона |
| #108 | `docs/claude-md-refresh` | docs: CLAUDE.md сверен с репозиторием |

(Релизный стек #109–#121 влит 11.10.26; актуальный список — `gh pr list`.)

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
| **victory** | `../victory-victory` | feature-ветки | Rails-код, миграции, RSpec, runner |
| **chat** | `../victory-chat` | `dev/chat` | site-chatbot, `chat_tools/*`, prompts |
| **seo** | `../victory-seo` | `dev/seo` | meta / JSON-LD / sitemap / Lighthouse |
| **upgrade** | `../victory-upgrade` | `dev/upgrade` | Rails/Ruby EOL, спеки, session-coord |

🚨 **main checkout** (корень, из которого выросли все worktree) — до 12.10.26 был
**живым прод-bind-mount**; после cutover это ops-каталог прода (compose/.env/bin),
правки файлов на сайт не попадают — код едет через образы. Всё равно не ветвись
и не коммить там без нужды: порядок — PR.

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

## Реестр новостроек Рязани — служба сбора данных (08.09.26)

Появилась `services/zhk-registry/` — питоновский сборщик открытых данных
о новостройках (ЕРЗ.РФ + сайт застройщика «Единство»), питающий уже
готовую Rails-сторону справочника ЖК (`ResidentialComplex`,
`Zhk::Ingest`, экран расхождений `/admin/zhk_discrepancies`). Служба
доступа к БД не имеет — единственный вход `POST
/webhooks/zhk_ingest[/summary]`, контракт описан в
`services/zhk-registry/README.md`.

- **Что делает:** раз в неделю обходит оба источника, шлёт наблюдения
  батчами (≤50), потом сводку прогона. `Zhk::RunSummary` на Rails-стороне
  сравнивает count с прошлым прогоном и алертит в Telegram
  (`TELEGRAM_STAFF_CHAT_ID`), если источник замолчал (кратное падение
  или устойчивый ноль).
- **Крон:** `services/zhk-registry/crontab.example`, ставится в
  пользовательский `crontab -e` на хосте прода из main-чекаута
  (main checkout), не из сессионного worktree.
- **Диагностика отказа:** `DRY_RUN=1 .venv/bin/python3 run.py` гоняет
  источники без единого похода на вебхук — первое, что запускать, если
  Telegram прислал «молчат: <источник>». Дальше — обновить фикстуру
  источника, починить CSS-селектор, прогнать `python3 -m unittest
  discover -v`. Подробный чек-лист — README службы, раздел «Первый
  запуск».
- **Расхождения источников** — `/admin/zhk_discrepancies?token=$ADMIN_TOKEN`:
  когда ЕРЗ и «Единство» не согласны по полю (например, застройщик),
  оба значения видны редактору со ссылкой на источник, поле в карточке
  ЖК остаётся пустым до ручного разрешения.
- **Сухой прогон 08.09.26** (задача 13, ветка `claude/zhk-registry`)
  прошёл целиком: 242 RSpec + 61 python-теста зелёные, вебхук проверен
  вручную на всех кодах ответа (503 пустой токен, 401 неверный/голый
  токен, 422 батч >50, `duplicate` на повторе), DRY_RUN на живых
  источниках нашёл 10 ЖК на ЕРЗ и 44 карточки домов на «Единстве» (это
  не 44 разных ЖК — несколько корпусов одного комплекса сводятся в одну
  карточку уже на Rails-стороне). Найдено и задокументировано (не
  чинилось — вне области задачи): на полностью пустом БД-volume
  `db:migrate` падает на `schema "tiger" already exists` (кастомный
  postgres-образ создаёт эти схемы сам, `db/structure.sql` — без `IF NOT
  EXISTS`) и отдельно на неверном порядке таймстампов миграций
  `client_documents` (`20260527000900` раньше `20260527020000`) —
  обходные пути в README `zhk-registry`.

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

- TZ для этой фазы (если есть): `TZ_VICTORY62_NEWS_CROSSLINK.md` — вне репозитория, на прод-хосте `/home/q/`
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

## Базовая линия показов (12.09.26)

Ветки стеком: `claude/show-delegation` (A: данные, сегмент, стадии) → `claude/show-reports`
(B: отчёт о показе, воронка, сводка) → `claude/show-routing` (C: фильтр, `/bargain`).
Worktree — `/home/q/victory-shows`. План и инструкция:
`docs/superpowers/plans/2026-09-11-show-delegation-telegram.md`,
`.claude/docs/reglament/SHOWS-BASELINE.md`.

Фаза: **сбор базовой линии, фильтр выключен** (`SHOW_ROUTING_ENABLED=false`). Две недели никто не меняет,
кто ездит на показы; включение фильтра — решение руководителя при ≥14 днях и ≥20 подтверждённых
`ShowReport`. Итоги снимать не раньше чем через две недели после деплоя A+B.
