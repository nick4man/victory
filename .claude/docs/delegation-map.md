# Delegation map — routing user requests → agent / skill

> **Single source of truth** для auto-delegation в victory62. CLAUDE.md и SessionStart hook ссылаются сюда. Меняешь routing — правишь этот файл.

Цель: ≥80% типичных domain-запросов авто-делегируются в правильный агент/скилл без явного `/agent <name>` от пользователя.

Стратегия — **Balanced**: явные match'ы → делегация; неопределённые → handle directly с упоминанием опции.

## 17 проектных агентов

| Trigger keywords / domain | Primary agent | Cross-refs / related |
|---|---|---|
| **Topnlab**, **МЛС sync**, листинги, телефония Asterisk, миграция CRM, своя CRM, webhooks/topnlab, mls_sync, `topnlab_*_job` | `topnlab-api-expert` | `telegram-staff-bot-dev` (CRM-канал TG), `rails-architect` (new domain model) |
| **TG staff bot**, work_bot, escalation, topic_registry, inbox saver, inbound_processor, lead_announcer, TELEGRAM_STAFF_CHAT_ID | `telegram-staff-bot-dev` | `pdf-telegram-dispatcher` (delivery), `session-coordinator` (chat-сессия) |
| **site chatbot**, чат-бот сайта, chat_responder, omni_client, chat_tools, free-first chain, tool_runner, scope_guard, page_greeting | `site-chatbot-dev` | `session-coordinator` (work in chat-сессии) |
| **SEO**, JSON-LD, meta-теги, sitemap, robots.txt, canonical, hreflang, OG/Twitter, Schema.org, Yandex Webmaster, Google Search Console, friendly_id | `seo-content-curator` | skill `victory-seo-checklist` (для нового view), skill `russian-real-estate-copywriting` (для финального текста) |
| **property valuation**, оценка, экспресс-оценка, CMA, hedonic overshoot, аналоги Avito/Cian, /valuations submit | `property-valuation-expert` | `site-chatbot-dev` (если через chat_tool estimate_property_valuation), `market-analytics-publisher` (если нужен market context) |
| **Prawn PDF**, audit_pdf, кириллица в PDF, theme.rb, layout PDF, графики в PDF, broken glyphs | `pdf-report-designer` | `pdf-telegram-dispatcher` (если просят отправить) |
| **markdown → PDF → TG**, отправь план в ТГ, оформить как PDF, доставить в группу через бота | `pdf-telegram-dispatcher` | `pdf-report-designer` (если просят дизайн отчёта) |
| **рефакторинг 500+ LOC**, fat model/controller, concerns, extract service, decomposition, AASM states, новый domain | `rails-architect` | `test-bootstrapper` (safety net перед refactor), `code-reviewer` (review post-refactor diff) |
| **код-ревью**, review the diff, audit changes, before merge, PR review, before commit, проверь мой код, safety review, посмотри что наделал | `code-reviewer` | `test-bootstrapper` (safety net для untested paths), domain-agents (Topnlab/Yandex/SEO/TG/site-chatbot — для deep API contract review), `session-coordinator` (cross-session diff review) |
| **RSpec**, добавить тесты, bootstrap rspec, factory нет, spec for service, тесты на legacy, coverage | `test-bootstrapper` | skill `rspec-bootstrap` |
| **parallel session**, lock-file, conflict в правках, hand-off victory↔chat↔seo, кто правит файл | `session-coordinator` | skill `session-coordination` |
| **кто чем занят сейчас**, не делает ли это уже другая сессия, дублирование работы, спор о локах и очереди в main, сверка с вектором | `session-observer` (живёт в victory) | doc `.claude/docs/session-authority.md` (полномочия ролей), `bin/session-status`, `session-coordinator` (механика worktree/локов) |
| **client document intake** — паспорт/ИНН/выписка/ЕГРН через TG client-bot, OCR (Yandex Vision), DLP, валидация checksums | `client-onboarding-bot` | `telegram-staff-bot-dev` (НЕ путать — там staff inbox), `rails-architect` (Document model design) |
| **рыночная аналитика контент**, weekly market digest, district analytics block, разбор ЖК, market intel | `market-analytics-publisher` | skill `russian-real-estate-copywriting` (для финального tone), `property-valuation-expert` (для CMA single objects) |
| **post-deal кейс**, case study, /cases landing, видео-сценарий, success story, анонимизированный кейс | `case-study-writer` | `pdf-report-designer` (PDF dossier вёрстка), `seo-content-curator` (landing publish), skill `russian-real-estate-copywriting` (tone), `market-analytics-publisher` (market context within case) |
| **VDS Traefik/CrowdSec ops** — роутеры, middlewares, services, TLS, bouncer, AppSec, cscli decisions, через `ssh vds` (sodix.org) | `traefik-vds-ops` | skill `traefik-config-authoring` (router/middleware/service patterns + safety workflow), skill `crowdsec-policy-management` (bouncer + cscli + AppSec), doc `.claude/docs/vds-infra-cheatsheet.md` (paths + inventory) |
| **Nextcloud (rclone `nxt:`)** — Офис/НЕДВИЖИМОСТЬ загрузка дозсье, share link клиенту, читать шаблоны договоров + банковские программы, deep-scan структуры | `nextcloud-rclone-ops` | skill `rclone-nextcloud-patterns` (commands + safety + share-link workflow), doc `.claude/docs/nextcloud-cheatsheet.md` (полная taxonomy + save-routing matrix). HARD-EXCLUDE `Офис/Обмен`. |
| **Yandex Webmaster API v4** — SEO digest (SQI/queries/sitemap), opportunity detection (low CTR + mid position + impressions ≥ 50), recrawl trigger с quota discipline, диагностика, query history tracking | `yandex-webmaster-seo-ops` | skill `yandex-webmaster-api-patterns` (verified endpoint catalogue с quirks, opportunity thresholds, recrawl quota safety, privacy для search-query data), service objects `Yandex::Webmaster*Service`, OAuth setup `.claude/docs/yandex-webmaster-oauth-setup.md` |

## 11 проектных скиллов

| Trigger | Skill | Notes |
|---|---|---|
| Любой новый Ruby-код в проекте | `victory-rails-conventions` | enums `_prefix`, soft-delete `deleted_at`, frozen literals, single quotes, dd.MM.yy дат, service-object pattern |
| Parallel session работа, конфликты edit'ов | `session-coordination` | tmp/claude-locks/ pattern, victory↔chat↔seo rules |
| Bootstrap тестов под существующий код | `rspec-bootstrap` | FactoryBot + DatabaseCleaner + Faker(ru); request specs over controller specs |
| Новый view/route/контроллер | `victory-seo-checklist` | title/meta/OG/JSON-LD/canonical/hreflang/breadcrumb/alt/robots checklist |
| Figma frame → ERB+Tailwind | `figma-to-erb-handoff` | workflow с figma:figma-implement-design; mapping на partials |
| Любой user-facing русский копирайт (landing/meta/TG/email/PDF/video) | `russian-real-estate-copywriting` | tone-of-voice (экспертный + тёплый + действие-ориентированный), anti-patterns, segment-specific (premium/foreign/средний), CTA library |
| Hand-off контекста между сессиями (inbox/structured) | `session-handoff-protocol` | replaces informal `.remember/now.md`; uses `bin/claude-inbox` + frontmatter format + priority levels |
| Traefik dynamic config edit на VDS — routers/middlewares/services/TLS + safety workflow | `traefik-config-authoring` | obligatory 7-step backup→edit→verify→rollback; cert resolver matrix (cloudflare DNS-01 vs letsencrypt HTTP-01); existing middleware library |
| CrowdSec policy на VDS — bouncer params, cscli decisions, AppSec, scenarios, profiles | `crowdsec-policy-management` | sidecar engine + Traefik plugin (v1.3.3); whitelist patterns (immediate vs persistent); AppSec test→block workflow |
| Nextcloud rclone — taxonomy, deal-folder naming, save-routing matrix, share-link OCS workflow, backup-before-overwrite, Cyrillic quoting | `rclone-nextcloud-patterns` | single remote `nxt:`, WebDAV, рабочий каталог `Офис`. EXCLUDED: `Офис/Обмен`. Cheatsheet: `.claude/docs/nextcloud-cheatsheet.md` |
| Yandex.Webmaster API v4 — verified endpoint paths (recrawl/quota НЕ под queue/, diagnostics returns problems hash), opportunity thresholds (impressions≥50, CTR<3%, pos 4-15), recrawl quota safety, privacy для search-query | `yandex-webmaster-api-patterns` | service entry: `Yandex::WebmasterSummaryService`. Daily quota 150 recrawls. OAuth doc: `.claude/docs/yandex-webmaster-oauth-setup.md` |

## Когда НЕ делегировать (anti-patterns)

1. **Простые вопросы по коду** — «что такое X в Property?», «где определён Y?» → direct через serena/repo-index, агент-overhead не нужен.
2. **Trivial fixes** — typo, переименование переменной, one-liner edit → direct.
3. **Ambiguous без domain-signal** — «помоги», «исправь» без контекста → попросить уточнение, не делегировать наугад.
4. **Многошаговые комплексные задачи** — сначала `/plan` (Plan agent), потом делегация subagent'ам внутри плана.
5. **Tasks где контекст уже в conversation** — Claude уже изучал X в текущей беседе → продолжай напрямую, не вызывай агента «для делегации».
6. **Read-only diagnostics** — git status, file existence checks, simple grep → direct.

## Domain conflicts — кто кого приоритетнее

| Если запрос про | И про | Primary |
|---|---|---|
| Topnlab API | TG staff bot | `topnlab-api-expert` (источник правды по API) |
| chat_responder.rb | parallel session conflict | `session-coordinator` (locks first), then `site-chatbot-dev` |
| PDF design | TG delivery | если про **дизайн** → `pdf-report-designer`; если про **отправку готового** → `pdf-telegram-dispatcher` |
| SEO meta | новый view | оба useful: `seo-content-curator` агент + skill `victory-seo-checklist` |
| refactor | tests missing | сначала `test-bootstrapper` (safety net), потом `rails-architect` |
| refactor design | review the result | сначала `rails-architect` (plan + diff), потом `code-reviewer` (severity-ordered findings on final diff). НЕ инверсия. |
| domain change (Topnlab/Yandex/SEO) | safety pass before merge | domain-agent делает changes; `code-reviewer` финально pass (general conventions + 3 hard rules + delegation hints) |
| TG inbox для **сотрудников** | TG bot для **клиентов** (паспорт/выписка) | staff = `telegram-staff-bot-dev`; client = `client-onboarding-bot` (НЕ путать — разные модули `work_bot/` vs `client_bot/`) |
| market analytics | single-object valuation | если **аналитика для контента** (TG/blog/landing) → `market-analytics-publisher`; если **оценка конкретного объекта** → `property-valuation-expert` |
| post-deal artifact | market data inside | `case-study-writer` primary, может звать `market-analytics-publisher` для market context |
| копирайт user-facing | SEO checklist | оба useful: skill `russian-real-estate-copywriting` (tone) + `seo-content-curator` агент (мета/JSON-LD) |

## Skill vs Agent — когда что

- **Skill** = инструкции/чек-лист/паттерн (CLAUDE читает, применяет напрямую). Лёгкий, инлайн.
- **Agent** = отдельная сессия subagent'а с собственным контекстом. Тяжелее, но автономно работает над задачей. Используй когда задача комплексная (требует много шагов + чтения).

Эвристика: если запрос укладывается в «применить чек-лист» — skill. Если требует исследования + реализации многих файлов — agent.

## Verification

Тестовый набор после Phase 4 push (рестарт Claude Code):

| Test prompt | Expected delegation |
|---|---|
| «Бот сжигает кредитов больше чем должен» | `site-chatbot-dev` |
| «Property model 720 LOC, что выделить в concerns?» | `rails-architect` |
| «Куда escalates лид при таймауте?» | `telegram-staff-bot-dev` |
| «Чек-лист SEO для новой /landings/dachi?» | `seo-content-curator` + skill `victory-seo-checklist` |
| «Как получить список МЛС объектов из Topnlab?» | `topnlab-api-expert` |
| «Bootstrap RSpec для PropertyEvaluationService» | `test-bootstrapper` + skill `rspec-bootstrap` |
| «В chat-сессии правлю chat_responder.rb, как избежать конфликта с victory?» | `session-coordinator` (+ ref `site-chatbot-dev`) |
| «PDF с кириллицей криво» | `pdf-report-designer` |
| «Отправь этот план в ТГ как PDF» | `pdf-telegram-dispatcher` |
| «Расскажи как работает enum для Property?» | direct (анти-паттерн) |
| «Сколько uncommitted файлов?» | direct (git query) |

Если success rate < 80% — итерация на конкретных description / routing rules.
