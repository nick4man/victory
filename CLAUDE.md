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

## Параллельные сессии Claude Code

Над этим репо работают две сессии:
- **victory** — Rails-сервер запущен, Ruby 3.2.2 активирован → сюда Edit/RSpec/runner.
- **chat** — системный Ruby 3.3 → сюда планирование/документы; TG через `curl`, **не** `bin/rails runner`.

См. `activeContext.md` для деталей.

## MCP-серверы (`.mcp.json`)

`serena` (LSP-навигация), `postgres` (read-only схема/SELECT), `github` (PR/issues), `rails-guides`.
Команда `/mcp` в Claude Code показывает статус. Установка: см. `.claude/memory/techContext.md`.

## Проектные субагенты (`.claude/agents/`)

- `property-valuation-expert` — CMA-валидация валюаций, защита от hedonic overshoot.
- `pdf-telegram-dispatcher` — markdown/plan → PDF → TG-группа через сайтового бота.
