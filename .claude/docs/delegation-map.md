# Delegation map — routing user requests → agent / skill

> **Single source of truth** для auto-delegation в victory62. CLAUDE.md и SessionStart hook ссылаются сюда. Меняешь routing — правишь этот файл.

Цель: ≥80% типичных domain-запросов авто-делегируются в правильный агент/скилл без явного `/agent <name>` от пользователя.

Стратегия — **Balanced**: явные match'ы → делегация; неопределённые → handle directly с упоминанием опции.

## 10 проектных агентов

| Trigger keywords / domain | Primary agent | Cross-refs / related |
|---|---|---|
| **Topnlab**, **МЛС sync**, листинги, телефония Asterisk, миграция CRM, своя CRM, webhooks/topnlab, mls_sync, `topnlab_*_job` | `topnlab-api-expert` | `telegram-staff-bot-dev` (CRM-канал TG), `rails-architect` (new domain model) |
| **TG staff bot**, work_bot, escalation, topic_registry, inbox saver, inbound_processor, lead_announcer, TELEGRAM_STAFF_CHAT_ID | `telegram-staff-bot-dev` | `pdf-telegram-dispatcher` (delivery), `session-coordinator` (chat-сессия) |
| **site chatbot**, чат-бот сайта, chat_responder, omni_client, chat_tools, free-first chain, tool_runner, scope_guard, page_greeting | `site-chatbot-dev` | `session-coordinator` (work in chat-сессии) |
| **SEO**, JSON-LD, meta-теги, sitemap, robots.txt, canonical, hreflang, OG/Twitter, Schema.org, Yandex Webmaster, Google Search Console, friendly_id | `seo-content-curator` | skill `victory-seo-checklist` (для нового view) |
| **property valuation**, оценка, экспресс-оценка, CMA, hedonic overshoot, аналоги Avito/Cian, /valuations submit | `property-valuation-expert` | `site-chatbot-dev` (если через chat_tool estimate_property_valuation) |
| **Prawn PDF**, audit_pdf, кириллица в PDF, theme.rb, layout PDF, графики в PDF, broken glyphs | `pdf-report-designer` | `pdf-telegram-dispatcher` (если просят отправить) |
| **markdown → PDF → TG**, отправь план в ТГ, оформить как PDF, доставить в группу через бота | `pdf-telegram-dispatcher` | `pdf-report-designer` (если просят дизайн отчёта) |
| **рефакторинг 500+ LOC**, fat model/controller, concerns, extract service, decomposition, AASM states, новый domain | `rails-architect` | `test-bootstrapper` (safety net перед refactor) |
| **RSpec**, добавить тесты, bootstrap rspec, factory нет, spec for service, тесты на legacy, coverage | `test-bootstrapper` | skill `rspec-bootstrap` |
| **parallel session**, lock-file, conflict в правках, hand-off victory↔chat↔seo, кто правит файл | `session-coordinator` | skill `session-coordination` |

## 5 проектных скиллов

| Trigger | Skill | Notes |
|---|---|---|
| Любой новый Ruby-код в проекте | `victory-rails-conventions` | enums `_prefix`, soft-delete `deleted_at`, frozen literals, single quotes, dd.MM.yy дат, service-object pattern |
| Parallel session работа, конфликты edit'ов | `session-coordination` | tmp/claude-locks/ pattern, victory↔chat↔seo rules |
| Bootstrap тестов под существующий код | `rspec-bootstrap` | FactoryBot + DatabaseCleaner + Faker(ru); request specs over controller specs |
| Новый view/route/контроллер | `victory-seo-checklist` | title/meta/OG/JSON-LD/canonical/hreflang/breadcrumb/alt/robots checklist |
| Figma frame → ERB+Tailwind | `figma-to-erb-handoff` | workflow с figma:figma-implement-design; mapping на partials |

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
