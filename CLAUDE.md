# CLAUDE.md — АН «Виктори» Real Estate Platform

Rails 7.1 / Ruby 3.2.2 / PostgreSQL 15+ + PostGIS + pgvector. Russian-language real estate platform. **PRODUCTION** at https://victory62.org.

## Где брать контекст (memory-bank)

Этот файл — тонкий хаб. Содержательное — рядом, читай по теме:

- `.claude/memory/activeContext.md` — текущая ветка, фаза, что в фокусе сейчас (обновляется неделями).
- `.claude/memory/systemPatterns.md` — конвенции (enums `_prefix`, soft-delete `deleted_at`, frozen literals, single quotes, dd.MM.yy даты, service-object pattern).
- `.claude/memory/techContext.md` — стек, ENV vars, команды (`rspec`, `rubocop`, миграции, Sidekiq, cron).
- `.claude/memory/progress.md` — что в проде, что отключено (Devise off!), что заглушка, аспирационные роуты, известный tech-debt.
- `.claude/repo-index.md` — компактный индекс «файл → классы» (~5k токенов, читай первым).
- `.claude/repo-map.md` — полный сигнатурный дамп (~190k токенов, on-demand для глубокого ныряния).
- Обновить оба: `bundle exec rake repo:map`.

## 3 жёстких правила (не нарушай, не спрашивая)

1. **Soft delete**: `deleted_at` + `default_scope { not_deleted }`. Никакого `paranoia` gem. Доступ к удалённым — `.unscoped`.
2. **Enums** — всегда с `_prefix: true`. Русский перевод значений — в комментарии рядом.
3. **Даты в коде/UI/сообщениях** — европейский `dd.MM.yy`. Не ISO, не US.

## Главное про auth

**Devise отключен**. `current_user` → `nil`, `user_signed_in?` → `false`. Admin-доступ — query-param `?token=$ADMIN_TOKEN`. Не предполагай, что юзер залогинен.

## Стратегический вектор (24 мес)

`.claude/memory/strategicVector.md` (короткое propagating-резюме) + `.claude/plans/splendid-imagining-lerdorf.md` (мастер-документ). Все решения прогоняй через 3 пиллара: **frictionless concierge / deep expertise / AI×human**. Усиливает 2+ — делаем; ослабляет хотя бы один — переформулируем.

## Параллельные сессии Claude Code

Над этим репо работают две сессии:
- **victory** — Rails-сервер запущен, Ruby 3.2.2 активирован → сюда Edit/RSpec/runner.
- **chat** — системный Ruby 3.3 → сюда планирование/документы; TG через `curl`, **не** `bin/rails runner`.

См. `activeContext.md` для деталей.

## MCP-серверы (`.mcp.json`)

`serena` (LSP-навигация), `postgres` (read-only схема/SELECT), `github` (PR/issues), `rails-guides`.
Команда `/mcp` в Claude Code показывает статус. Установка: см. `.claude/memory/techContext.md`.

## Routing & delegation — авто-выбор агента/скилла

Полная routing-таблица: `.claude/docs/delegation-map.md`. **Quick reference:**

| Domain (RU + EN keywords) | → Agent / Skill |
|---|---|
| **topnlab**, МЛС sync, listings, телефония Asterisk, миграция CRM, webhooks/topnlab | `topnlab-api-expert` |
| **TG staff bot**, work_bot, escalation, topic_registry, inbox, lead_announcer | `telegram-staff-bot-dev` |
| **site chatbot**, чат-бот сайта, chat_responder, omni_client, chat_tools, free-first chain | `site-chatbot-dev` |
| **SEO**, JSON-LD, sitemap, robots, canonical, hreflang, OG, friendly_id, Schema.org | `seo-content-curator` + skill `victory-seo-checklist` |
| **property valuation**, оценка, CMA, hedonic, аналоги Avito/Cian | `property-valuation-expert` |
| **Prawn PDF**, audit_pdf, кириллица, theme, layout PDF | `pdf-report-designer` |
| **markdown → PDF → TG**, отправь в TG, оформить как PDF | `pdf-telegram-dispatcher` |
| **рефакторинг** 500+ LOC, fat model/controller, concerns, extract service, AASM | `rails-architect` |
| **RSpec**, добавить тесты, factory нет, spec for, тесты legacy | `test-bootstrapper` + skill `rspec-bootstrap` |
| **parallel session**, lock, conflict в правках, hand-off victory↔chat↔seo | `session-coordinator` + skill `session-coordination` |
| **client document intake** — паспорт/ИНН/выписка через TG → OCR + DLP | `client-onboarding-bot` |
| **еженедельный обзор рынка**, market analytics для TG/blog/landing | `market-analytics-publisher` |
| **post-deal кейс**, case study PDF/landing/видео-сценарий | `case-study-writer` |
| **VDS Traefik/CrowdSec** — роутеры, middlewares, bouncer, cscli (`ssh vds`) | `traefik-vds-ops` + skills `traefik-config-authoring` / `crowdsec-policy-management` |
| **Nextcloud / rclone (`nxt:`)** — дозсье в облако, share-link, шаблоны, банковские программы из Офис/НЕДВИЖИМОСТЬ | `nextcloud-rclone-ops` + skill `rclone-nextcloud-patterns` |
| Новый Ruby-код | skill `victory-rails-conventions` |
| Figma frame → ERB+Tailwind | skill `figma-to-erb-handoff` |
| Любой user-facing русский копирайт (landing/meta/TG/email/PDF) | skill `russian-real-estate-copywriting` |

### Когда НЕ делегировать

- Простой вопрос по коду («что такое X?») → direct через serena/repo-index
- Trivial fix (typo, переименование) → direct
- Ambiguous без domain-signal → попросить уточнение, не делегировать наугад
- Контекст уже в conversation → продолжай напрямую
- Read-only diagnostics (git status, ls) → direct

### Domain conflicts

- Topnlab API + TG staff bot → `topnlab-api-expert` (источник правды по API)
- chat_responder + parallel session → `session-coordinator` first (locks), потом `site-chatbot-dev`
- PDF design vs delivery → дизайн = `pdf-report-designer`; готовый PDF в TG = `pdf-telegram-dispatcher`
- Refactor + tests missing → `test-bootstrapper` сначала (safety net), потом `rails-architect`
