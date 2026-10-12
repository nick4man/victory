# АН «Виктори» — digital-платформа агентства недвижимости

> Русскоязычная платформа агентства недвижимости (Рязань): публичный сайт, JSON API,
> админка, два Telegram-бота и AI-функции.

**Production: https://victory62.org**

[![Ruby](https://img.shields.io/badge/Ruby-3.4.10-red.svg)](https://www.ruby-lang.org/)
[![Rails](https://img.shields.io/badge/Rails-8.1-red.svg)](https://rubyonrails.org/)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-15%20%2B%20PostGIS%20%2B%20pgvector-blue.svg)](https://www.postgresql.org/)

---

## О проекте

Rails-монолит с четырьмя входами:

| Вход | Где | Аутентификация |
|---|---|---|
| Публичный сайт | `landing#index` + `properties`, `news`, `valuations`, `cabinet` (`config/routes.rb`) | нет |
| JSON API | `namespace :api { namespace :v1 }` | JWT |
| Админка | `namespace :admin` | query-param `?token=$ADMIN_TOKEN` |
| Вебхуки | `app/controllers/webhooks/` (topnlab, telegram, yookassa, amocrm, news_ingest, zhk_ingest…) | секрет из ENV; **пустой ENV = отказ** |

Ключевые особенности архитектуры:

- **Каталог объектов — проекция внешней CRM Topnlab.** Источник правды — Topnlab;
  `Property` наполняется `TopnlabSyncJob` (каждые 30 минут) и соседними sync-джобами.
- **Доменная логика — в `app/services/`** (~69 каталогов: `llm/`, `telegram/`,
  `topnlab/`, `crm/`, `mortgage/`, `property_dossier/`, `audit_engine/`…),
  не в моделях и контроллерах. Plain-Ruby класс с `initialize` + `call`.
- **Два Telegram-бота из одного Rails**: `telegram/work_bot/` (сотрудники —
  фактический CRM-канал: команды, задачи, дайджесты, эскалации) и
  `telegram/client_bot/` (клиенты). Общий вход — `Telegram::InboundProcessor`;
  вебхук идёт через Cloudflare-релей `tg-webhook-relay/`.
- **LLM — free-first цепочка провайдеров** (`app/services/llm/omni_client.rb`,
  цепочки `LLM_CHAIN_CHAT/ANALYSIS/STAFF_ANALYSIS`, платные модели — последние).
- **Эмбеддинги** — pgvector + gem `neighbor`; гео-запросы — PostGIS сырым SQL.

## Функционал

### Публичный сайт

- **Каталог недвижимости** `/properties`: фильтры (Ransack + PgSearch, русский словарь),
  интерактивная карта (Яндекс.Карты), сравнение объектов, избранное, запись на показ,
  автокомплит, история цены, **досье объекта** (premium PDF, 5 страниц).
- **SEO-пирамида лендингов**: `/kupit/*`, `/snyat/*` (интент × тип × район × комнаты),
  страницы городов; EN-лендинг `/foreign` с инвест-аудитом.
- **Реестр ЖК** `/zhk` — жилые комплексы с привязкой объектов.
- **Оценка недвижимости** `/valuations`: экспресс-оценка и инвестиционный аудит
  (sidecar `audit-engine`, token-based страницы результатов).
- **Сервисы** `/services/*`: ипотечный калькулятор (банки, программы, заявки),
  депозитный калькулятор, «ипотека vs депозит», юридические и документные услуги,
  виртуальные туры.
- **Кабинет клиента** `/cabinet` (вход по magic-link): профиль, «мои объекты»,
  документы, избранное, цифровой агентский договор с публичной проверкой
  `/verify-contract/:token`.
- **AI-чат-бот** `/chatbot` и онлайн-чат `/chat` с операторами (ActionCable,
  tool-calling через `app/services/chat_tools/`).
- **Контент**: блог `/blog`, новости `/news`, кейсы `/cases`, отзывы `/reviews`,
  агенты `/agents/:slug`, FAQ, `/about/*`.
- **Партнёрский портал** `/partners` (magic-link) и чужие YRL-объявления
  `/external-listings/:id` с lead-capture.
- Техническое: sitemap-index, robots.txt, IndexNow, фиды `feeds/{yrl,cian,avito}.xml`,
  PWA (manifest, service worker, offline).

### JSON API v1 (JWT)

`auth/{login,logout,refresh}`, `properties` (+search/featured/recent/similar),
`profile`, `favorites`, `inquiries`, `saved_searches`, `mortgage_calculator/calculate`,
`property_evaluation`, `recommendations`, `stats`, `addresses/autocomplete`
(DaData-прокси). Полный список — `config/routes.rb`.

### Админка `/admin`

Дашборд, модерация отзывов, статьи (включая публикацию в Telegram), кейсы,
живое редактирование SEO-копирайта (`landing_contents`), справочник ЖК и расхождения,
управление объектами (force_publish/archive), статус Topnlab-синка, ставки банков,
партнёрские агентства, пользователи (QR-активация), реферальная программа.
Sidekiq::Web на `/sidekiq` под тем же токеном. Health-эндпоинты: `/health{,/database,/redis,/sidekiq}`.

### Telegram-боты

- **Work-bot** (`app/services/telegram/work_bot/`, ~45 файлов): команды, задачи и
  TaskBatch с SLA, дайджесты диспетчерской, director-dashboard, KPI, детектор аномалий,
  голосовой/фото-intake, отчёты показов.
- **Client-bot** (`telegram/client_bot/`): активация, привязка к кабинету, приём
  фото/текста.

### Фон и периодика

Sidekiq 7 + sidekiq-cron (`config/sidekiq_cron.yml`, ~21 активная задача, время MSK):
синк Topnlab (каталог, сотрудники, заявки, собственники), YRL-фиды конкурентов,
ставки банков, KPI-снапшоты и дайджесты, SLA-напоминания, детектор аномалий,
cleanup-задачи. Планировщик один — только этот файл (`config/schedule.rb` удалён,
гема `whenever` нет).

## Технологический стек

| Слой | Технология |
|---|---|
| Framework | Rails **8.1.3.1** (`load_defaults` пока 7.1) |
| Язык | Ruby **3.4.10** |
| БД | PostgreSQL 15 + **PostGIS 3.6** + **pgvector 0.8.6** (образ `Dockerfile.postgres`) |
| Server | Puma 7.2, порт 3000 в Docker |
| Фон | Sidekiq 7 + sidekiq-cron, Redis 7 |
| Frontend | Importmap + Stimulus + Turbo (Hotwire), Tailwind (`tailwindcss-rails`), ERB; сборщика JS нет |
| Поиск | Ransack + PgSearch + FriendlyId |
| LLM/HTTP | Faraday + Stoplight; самописные клиенты: `llm/omni_client.rb`, Tavily, Firecrawl, DaData, Yandex Vision, Google Embedding |
| PDF/медиа | Prawn + prawn-table, rqrcode, redcarpet, image_processing (libvips), Active Storage (`:local`) |
| Платежи | ЮKassa (вебхук `webhooks/yookassa`) |
| Мониторинг | Sentry (при заданном `SENTRY_DSN`, PII strip) |
| Тесты | RSpec, FactoryBot, Shoulda Matchers, WebMock, DatabaseCleaner; Playwright (visual regression); Python unittest |
| Качество | RuboCop, Brakeman, bundler-audit, CodeQL, GitGuardian |

Аутентификация: **Devise фактически отключён** (гем в Bundle, но не используется) —
вход в кабинет по magic-link, API по JWT, админка по `ADMIN_TOKEN`. Pundit отключён.

## `services/` — подсистемы вне Rails

Отдельные маленькие службы в одном репозитории (манифест — `SERVICE.md` в каждом
каталоге, правила проверяет `python3 bin/services-check`):

| Служба | Язык | Назначение |
|---|---|---|
| `audit-engine/` | Python (FastAPI) | инвестиционный аудит (EI / Монте-Карло / PDF), sidecar |
| `urgent-news-collector/` | Python | конвейер срочных новостей и ставок банков → `/webhooks/news_ingest` |
| `content-publisher/` | Python | Telegram-публикатор очереди новостей (@rznvictory) |
| `zhk-registry/` | Python | обход ЕРЗ/сайтов застройщиков → `/webhooks/zhk_ingest` |
| `chat-host-cron/` | bash | cron-обвязка (монтируется в контейнер `conveyor`) |
| `web-comparables/` | текст скилла | подбор аналогов (кода нет) |
| `tg-webhook-relay/` (корень) | Cloudflare Worker | релей Telegram-вебхуков → `victory62.org` |

## Установка и запуск (development)

Требования: Ruby 3.4.10, PostgreSQL 15 с PostGIS + pgvector (проще всего — образ
`Dockerfile.postgres`), Redis 7. Node.js нужен только для dev-инструментов
(Playwright, Figma Code Connect).

```bash
git clone git@github.com:nick4man/victory.git
cd victory
bundle install
cp .env.example .env          # заполнить обязательные переменные
bin/rails db:create db:migrate
bin/rails db:seed             # опционально
bin/rails server              # http://localhost:3000
bundle exec sidekiq -C config/sidekiq.yml   # фоновые задачи, отдельный терминал
```

На прод-хосте `victory` (Ruby только в контейнере) все Ruby-команды — через `bin/rb`:

```bash
bin/rb bundle install
bin/rb bin/rails db:migrate
```

Обязательные ENV: `DATABASE_*`, `REDIS_URL`, `SECRET_KEY_BASE`, `ADMIN_TOKEN`,
`JWT_SECRET_KEY`. Интеграции (по мере необходимости): `TELEGRAM_*`, `OMNIROUTE_*` /
`LLM_CHAIN_*`, `DADATA_*`, `YANDEX_MAPS_API_KEY`, `SMTP_*`, токены вебхуков
(`NEWS_INGEST_TOKEN`, `ZHK_INGEST_TOKEN`, …). Полный список — `.env.example`
(163 переменные; часть помечена как мёртвый груз — см. комментарии в файле).

## Тестирование

```bash
bundle exec rspec                              # полный прогон (~150 spec-файлов)
bundle exec rspec spec/models/property_spec.rb # файл / :строка

# На прод-хосте (поднимает PostGIS+pgvector образ):
bin/rb --db bundle exec rspec

# Качество и безопасность:
bundle exec rubocop --parallel
bundle exec brakeman --exit-on-warn --quiet
bundle exec bundle-audit update && bundle exec bundle-audit check

# Правила служб services/ (только python3):
python3 bin/services-check

# Python-юниты служб:
cd services/urgent-news-collector && python3 -m unittest discover -v

# Visual regression (Playwright, снапшоты коммитятся; нужен dev-сервер на :3000):
npm run vr:test    # проверка против базовых
npm run vr:update  # переснять базовые (ревью диффа обязателен)
```

Тестовая БД требует расширения `postgis`, `vector`, `pg_trgm`, `unaccent`
(`db/structure.sql`) — CI и `bin/rb` поднимают `Dockerfile.postgres`.

## CI/CD и деплой

- **`main` = production, direct push запрещён.** Работа — в `dev/<session>` /
  feature-ветках, путь в прод — только PR.
- На PR: RuboCop, Brakeman, bundler-audit, `services-check`, RSpec, сборка
  prod-образа + `zeitwerk:check` (`.github/workflows/lint.yml`, `build.yml`),
  CodeQL, GitGuardian. Code-review diff — обязательный этап каждого PR.
- **CD**: merge в `main` → `build.yml` собирает и пушит образы
  `ghcr.io/nick4man/victory-*:sha-<7>` (тег `<VERSION>` — при изменении файла VERSION)
  и автоматически выкатывает на staging.
- **Прод — ручная выкатка**: `bin/rollout <тег>` на прод-хосте
  (бэкап → pull → health → smoke). Runbook и откат — `docs/runbooks/release.md`.
- **Бэкап**: `bin/backup` + systemd-таймер (`deploy/systemd/`, пример конфига —
  `config/backup.env.example`).
- Контейнеры (`docker-compose.yml`): `db` (PostGIS+pgvector), `redis`, `web`,
  `sidekiq`, `zhk-registry`; профиль `conveyor` — `news-db`, `conveyor`, `publisher`;
  профиль `audit` — `docker-compose.audit.yml`.

## Структура проекта

```
victory/
├── app/
│   ├── controllers/      # сайт + api/v1 + admin + webhooks/
│   ├── models/           # AR-модели (soft delete через deleted_at)
│   ├── services/         # доменная логика (~69 каталогов: llm/, telegram/, topnlab/…)
│   ├── jobs/, mailers/, channels/, helpers/, javascript/, views/, assets/
├── bin/                  # ~24 скрипта: rb, rollout, backup, release, smoke…
├── config/               # routes.rb (~900 строк), sidekiq_cron.yml, database.yml…
├── db/                   # migrate/, seeds/, structure.sql
├── deploy/systemd/       # юниты бэкапа
├── docs/                 # runbooks/, регламенты, правила документации
├── lib/tasks/            # ~31 rake-задача
├── services/             # подсистемы вне Rails (Python/bash), SERVICE.md в каждой
├── spec/                 # RSpec: models, services (основная масса), requests, jobs, mailers
├── tests/visual/         # Playwright visual regression (снапшоты коммитятся)
├── tg-webhook-relay/     # Cloudflare Worker для Telegram-вебхуков
├── Dockerfile, Dockerfile.postgres, docker-compose*.yml
└── VERSION               # версия релизной линии (сейчас 1.0.0)
```

## Документация

- **`AGENTS.md`** — стартовая точка для AI-агентов и источник правды о проекте.
- **`.claude/memory/`** — memory-bank: `activeContext.md`, `systemPatterns.md`,
  `techContext.md`, `progress.md`, `strategicVector.md`.
- **`docs/runbooks/`** — эксплуатационные процедуры (release, staging, cutover…).
- **`services/*/SERVICE.md`** — манифесты подсистем.
- **`docs/documentation-rules.md`** — правила ведения документации.

⚠️ Корневые `*.md` (`STATUS.md`, `DEPLOYMENT*.md`, `ROADMAP.md` и др.) —
исторический шум, источником правды не являются.

## Участие в разработке

1. Ветка `dev/<session>` или `claude/<task>` от `main` — direct push в `main` запрещён.
2. Конвенции кода — `AGENTS.md` и `.claude/memory/systemPatterns.md`
   (soft delete через `deleted_at`, enums с `_prefix: true`, даты `dd.MM.yy`,
   single quotes, `# frozen_string_literal: true`).
3. CI должен быть зелёным; далее — обязательное code-review diff.
4. Зависимые слои (миграция → сервис → UI) или diff > ~500 строк — стек PR через
   `gh stack`.

## Статус проекта

**Версия:** 1.0.0 (релизная линия с 11.10.26)
**Статус:** active development, production — https://victory62.org
