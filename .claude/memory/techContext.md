# techContext.md — стек и инфра

## Стек

| Слой | Технология |
|------|-----------|
| Web framework | Rails **8.1.3.1** (в проде с 08.08.26; `load_defaults` пока 7.1) |
| Language | Ruby **3.3.6** — только в контейнере, через `bin/rb`. На хосте менеджера версий нет (ни chruby, ни rbenv, ни mise), системный ruby 3.3.8 не совпадает с пином Gemfile, поэтому `bundle`/`rspec`/`bin/rails` напрямую в worktree не работают |
| Database | PostgreSQL 15+ (с PostGIS + pgvector) |
| Server | Puma 6.x, порт **3000** в Docker (reverse-proxy → 443 в проде) |
| CSS | Tailwind CSS (`tailwindcss-rails`) |
| JS bundling | Importmap + Stimulus + Turbo (Hotwire) |
| Auth | Devise (**отключен**) |
| Search | PgSearch (full-text, Russian dictionary) |
| Pagination | Kaminari |
| Background jobs | Sidekiq 7 + sidekiq-cron — **активны в проде** (контейнер `victory-sidekiq-1`), расписание в `config/sidekiq_cron.yml` |
| API | Rack::CORS, jbuilder, JWT (для `/api/v1/`) |
| Geocoding | Geocoder gem |
| Scheduling | Whenever (cron) |
| WebSockets | Action Cable |
| File uploads | Active Storage |
| Testing | RSpec, FactoryBot, Shoulda Matchers, DatabaseCleaner, Capybara (selenium_chrome_headless для JS-спеков) |

## Module name

`ViktoryRealty` — главный модуль (см. `config/application.rb`).

## Локализация / TZ

- `Faker::Config.locale = 'ru'` для тестов.
- Default locale: `:ru`. Locale files: `config/locales/ru.yml`, `config/locales/devise.ru.yml`.
- Timezone: Moscow (`config.time_zone = 'Moscow'`).

## ENV vars

| Variable | Default | Описание |
|----------|---------|---------|
| `RAILS_ENV` | `development` | окружение |
| `PORT` | `5000` (старое) / `3000` (Docker) | порт сервера |
| `DATABASE_URL` | — | полный PG URL (production) |
| `DATABASE_HOST` | `localhost` | DB host |
| `DATABASE_PORT` | `5432` | DB port |
| `DATABASE_USERNAME` | `postgres` | DB user |
| `DATABASE_PASSWORD` | `''` | DB password |
| `REDIS_URL` | `redis://localhost:6379/0` | Redis (Sidekiq + cache) |
| `RAILS_MAX_THREADS` | `5` | thread count / DB pool |
| `WEB_CONCURRENCY` | `1` | Puma workers |
| `ACTION_CABLE_URL` | `ws://localhost:3000/cable` | WS endpoint |
| `CORS_ORIGINS` | `*` | allowed origins (CSV) |
| `APP_HOST` | `localhost` | hostname |
| `APP_PROTOCOL` | `http` | scheme |
| `JWT_SECRET_KEY` | (credentials) | JWT signing |
| `ASSET_HOST` | — | CDN |
| `LOG_LEVEL` | `debug`/`info` | logger verbosity |
| `SESSION_TIMEOUT` | `1800` | session expiry (sec) |
| `ADMIN_TOKEN` | — | query-param admin guard (Admin::Reviews, Admin::Articles) |
| `TELEGRAM_BOT_TOKEN` | — | основной TG-бот сайта (`@anvictorybot`) |
| `TELEGRAM_STAFF_CHAT_ID` | `-1003937910508` (dev+owner) | куда уходят отчёты/уведомления |
| `TOPNLAB_API_KEY` | — | ключ CRM; без него `Topnlab::Client` кидает `Error` на init |
| `TOPNLAB_BASE_URL` | — | база API (`agencies-p.topnlab.ru`); тоже обязательна |
| `YANDEX_AI_STUDIO_API_KEY` + `YANDEX_CLOUD_FOLDER_ID` | — | Vision OCR для document intake |
| `YANDEX_WEBMASTER_TOKEN` + `YANDEX_WEBMASTER_USER_ID` | — | Webmaster API (digest, recrawl) |

## DB и миграции

- DB-имена: `viktory_realty_development`, `viktory_realty_test`, `viktory_realty_production`.
- Расширения: `postgis`, `vector` (pgvector), `pg_trgm`, `unaccent`.
- ~13 базовых миграций; новые — по фазам.

## Команды

### Сервер
```bash
bundle exec rails server -p 5000 -b 0.0.0.0  # legacy
bin/rails server                              # Docker prod: :3000
```

### БД
```bash
bin/rails db:create
bin/rails db:migrate
bin/rails db:seed
bin/rails db:reset    # drop + create + migrate + seed
```

### Тесты
```bash
bundle exec rspec
bundle exec rspec spec/models/property_spec.rb
bundle exec rspec --format documentation
```

### Lint
```bash
bundle exec rubocop
bundle exec rubocop -a    # safe autocorrect
bundle exec rubocop -A    # unsafe autocorrect
```

### Sidekiq (когда нужно)
```bash
bundle exec sidekiq -C config/sidekiq.yml
```
Очереди по приоритету: `critical` → `mailers` → `default` → `scheduled` → `low_priority`.

### Cron (Whenever)
```bash
bundle exec whenever --update-crontab
bundle exec whenever --clear-crontab
```
Расписание:
- ежечасно: `SendViewingRemindersJob`
- 03:00: `UpdatePropertyStatisticsJob`
- 10:00: `PropertyValuationFollowUpJob`

## Replit-специфика

`config.hosts.clear` в development разрешает все хосты. Порт 5000 жёстко прибит под Replit proxy. Не удалять — нужно для dev-окружения.

## MCP / Claude Code инфра (Phase 1)

- `.mcp.json` в корне — конфиг 4 MCP-серверов: `serena`, `postgres`, `github`, `rails-guides`.
  MCP `postgres` поднимается контейнером `node:20-alpine` в docker-сети `victory_default`
  — по одному на сессию, безымянные, накапливаются после ребутов.
- `.claude/memory/` — этот memory-bank.
- `.claude/repo-index.md` — компактный индекс «файл → классы» (~5k токенов, читать первым).
- `.claude/repo-map.md` — полный сигнатурный дамп (~190k, on-demand). Оба: `rake repo:map`.
- `.claude/agents/` — проектные субагенты; routing-таблица — `.claude/docs/delegation-map.md`.
- `~/.claude-shared/` — межсессионный обмен: `inbox/`, `events/`, `locks/`.
- `.remember/logs/` — дневной журнал remember-плагина (лежит в main checkout).

Установленные плагины (user-level, не в репо): superpowers, context7, ruby-lsp, pyright-lsp, remember, code-review, feature-dev, telegram, vercel, figma, firecrawl, и др. См. `/home/q/.claude/plugins/installed_plugins.json`.
