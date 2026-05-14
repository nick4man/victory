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
