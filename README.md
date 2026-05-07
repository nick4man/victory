# АН "Виктори" — Digital Platform

> Современная платформа для агентства недвижимости: каталог объектов, онлайн-оценка, ипотечный калькулятор, личный кабинет и REST API.

[![Ruby](https://img.shields.io/badge/Ruby-3.3.6-red.svg)](https://www.ruby-lang.org/)
[![Rails](https://img.shields.io/badge/Rails-7.1-red.svg)](https://rubyonrails.org/)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-16-blue.svg)](https://www.postgresql.org/)
[![Sidekiq](https://img.shields.io/badge/Sidekiq-7.3-brightgreen.svg)](https://sidekiq.org/)
[![Redis](https://img.shields.io/badge/Redis-7.0-red.svg)](https://redis.io/)

---

## Оглавление

- [О проекте](#о-проекте)
- [Текущее состояние](#текущее-состояние)
- [Возможности](#возможности)
- [Технологический стек](#технологический-стек)
- [Требования](#требования)
- [Установка и запуск](#установка-и-запуск)
- [Переменные окружения](#переменные-окружения)
- [Структура проекта](#структура-проекта)
- [Фоновые задачи](#фоновые-задачи)
- [API](#api)
- [Тестирование](#тестирование)
- [Соглашения по коду](#соглашения-по-коду)
- [Роадмап](#роадмап)

---

## О проекте

**АН "Виктори"** — Rails 7.1 платформа для российского агентства недвижимости. Решает задачи онлайн-публикации объектов, поиска с фильтрами, онлайн-оценки и коммуникации с клиентами.

- **Язык интерфейса:** русский (`locale: ru`)
- **Модуль приложения:** `ViktoryRealty`
- **Таймзона:** Москва (`Europe/Moscow`)
- **Порт:** 5000 (настроен под Replit, см. `config/puma.rb`)

---

## Текущее состояние

| Компонент | Статус | Примечание |
|-----------|--------|------------|
| Landing page | **Активен** | `LandingController`, автономный шаблон без layout |
| Каталог недвижимости | **Активен** | CRUD, Ransack, PgSearch, мягкое удаление, FriendlyId |
| Онлайн-оценка | **Активен** | `PropertyValuationsController`, токен-доступ, PDF |
| Контактные формы | **Активен** | `ContactFormsController` |
| Devise-аутентификация | **Активен** | Регистрация, вход, подтверждение, OAuth Google |
| ActiveAdmin | **Активен** | `/admin` — доступ только для `role: :admin` |
| Sidekiq | **Активен** | Redis 7.0, 5 очередей, sidekiq-cron расписание |
| Фоновые задачи | **Активны** | 7 jobs: уведомления, статистика, дайджест |
| Email-рассылка | **Активна** | InquiryMailer, PropertyValuationMailer, ViewingMailer, UserMailer |
| REST API v1 | **Частично** | Свойства, аутентификация, избранное, заявки, рекомендации |
| Pundit-авторизация | **Активна** | Политики для Property, Inquiry, User |
| Rack::Attack | **Активен** | Redis-бэкенд, правила в `config/initializers/rack_attack.rb` |

---

## Возможности

### Для клиентов
- Поиск и фильтрация объектов (тип, цена, площадь, район, метро)
- Интерактивная карта объектов (Яндекс.Карты)
- Детальные карточки с фотографиями и историей цены
- Онлайн-оценка стоимости недвижимости
- Ипотечный калькулятор
- Личный кабинет: избранное, история просмотров, заявки, сохранённые поиски
- Онлайн-запись на показ
- Еженедельный дайджест новых объектов на email

### Для агентов и собственников
- Публикация объявлений с фото, описанием, адресом, условиями
- Управление статусами объявлений (черновик → модерация → активен → продан)
- Просмотр заявок от клиентов
- Аналитика просмотров и интереса

### Для администраторов
- Панель ActiveAdmin (`/admin`) — пользователи, объявления, заявки
- Мониторинг очередей Sidekiq (`/sidekiq`)
- CRM-интеграция (AmoCRM webhook)
- Email-уведомления по заявкам и показам

---

## Технологический стек

| Слой | Технология |
|------|-----------|
| Фреймворк | Rails 7.1, Ruby 3.3.6 |
| База данных | PostgreSQL 16 |
| Сервер | Puma 6.x |
| CSS | Tailwind CSS (`tailwindcss-rails`) |
| JS | Importmap + Stimulus + Turbo (Hotwire) |
| Аутентификация | Devise 5.0 + OmniAuth (Google) |
| Авторизация | Pundit 2.3 |
| Поиск | Ransack (фильтры) + PgSearch (полнотекстовый, рус. словарь) |
| Пагинация | Kaminari |
| Геокодирование | Geocoder |
| API | Rack::CORS + jbuilder |
| Фоновые задачи | Sidekiq 7.3 + sidekiq-cron |
| Redis | Redis 7.0 (очереди + кэш) |
| Файлы | Active Storage |
| WebSockets | Action Cable |
| Расписание | sidekiq-cron (встроено в Sidekiq) |
| Тесты | RSpec, FactoryBot, Shoulda Matchers, Capybara |
| Линтер | RuboCop (rubocop-rails, rubocop-rspec, rubocop-performance) |
| Админка | ActiveAdmin 3.5 |

---

## Требования

- Ruby 3.3.6 (через rbenv)
- PostgreSQL 16+
- Redis 7.0+

Node.js и Yarn **не требуются** — проект использует Importmap.

---

## Установка и запуск

### 1. Установка зависимостей

```bash
bundle install
```

### 2. База данных

```bash
bin/rails db:create db:migrate db:seed
```

### 3. Redis

```bash
# Запуск Redis (если не запущен)
redis-server --daemonize yes

# Проверка
redis-cli ping   # -> PONG
```

### 4. Rails-сервер

```bash
bin/rails server -p 5000 -b 0.0.0.0
```

Приложение доступно по адресу: `http://localhost:5000`

### 5. Sidekiq (фоновые задачи)

```bash
bundle exec sidekiq -C config/sidekiq.yml -e development
```

Веб-интерфейс Sidekiq: `http://localhost:5000/sidekiq` (только для `role: :admin`)

### 6. Тестовые аккаунты (после db:seed)

| Email | Пароль | Роль |
|-------|--------|------|
| `admin@victory.ru` | `Password123!` | Администратор |
| `agent@victory.ru` | `Password123!` | Агент |
| `client@victory.ru` | `Password123!` | Клиент |

---

## Переменные окружения

Для локальной разработки создайте `.env` в корне проекта (или задайте переменные в оболочке):

```env
# База данных
DATABASE_HOST=localhost
DATABASE_PORT=5432
DATABASE_USERNAME=postgres
DATABASE_PASSWORD=

# Redis
REDIS_URL=redis://localhost:6379/0

# Приложение
APP_HOST=localhost
PORT=5000
APP_URL=http://localhost:5000
```

Полный список переменных:

| Переменная | Значение по умолчанию | Описание |
|------------|----------------------|----------|
| `DATABASE_URL` | — | Полный URL PostgreSQL (приоритет) |
| `DATABASE_HOST` | `localhost` | Хост БД |
| `DATABASE_PORT` | `5432` | Порт БД |
| `DATABASE_USERNAME` | `postgres` | Пользователь БД |
| `DATABASE_PASSWORD` | `` | Пароль БД |
| `REDIS_URL` | `redis://localhost:6379/0` | URL Redis |
| `RAILS_MAX_THREADS` | `5` | Потоки Puma / пул соединений |
| `WEB_CONCURRENCY` | `1` | Воркеры Puma |
| `PORT` | `5000` | Порт сервера |
| `APP_HOST` | `localhost` | Хост приложения |
| `APP_PROTOCOL` | `http` | Протокол |
| `APP_URL` | `http://localhost:5000` | Базовый URL (для email-ссылок) |
| `JWT_SECRET_KEY` | (credentials) | Ключ подписи JWT |
| `CORS_ORIGINS` | `*` | Разрешённые CORS-источники |
| `DEFAULT_FROM_EMAIL` | `noreply@viktory-realty.ru` | Отправитель писем |
| `ADMIN_EMAIL` | `admin@viktory-realty.ru` | Email администратора |
| `CONTACT_PHONE` | `+7 (999) 123-45-67` | Контактный телефон |
| `GOOGLE_CLIENT_ID` | — | OAuth Google Client ID |
| `GOOGLE_CLIENT_SECRET` | — | OAuth Google Client Secret |
| `LOG_LEVEL` | `debug`/`info` | Уровень логирования |

---

## Структура проекта

```
victory/
├── app/
│   ├── admin/                          # ActiveAdmin ресурсы
│   │   ├── dashboard.rb                # Дашборд с живой статистикой
│   │   ├── users.rb
│   │   ├── properties.rb
│   │   └── inquiries.rb
│   ├── controllers/
│   │   ├── application_controller.rb   # Базовый контроллер
│   │   ├── landing_controller.rb       # Главная страница
│   │   ├── properties_controller.rb    # Каталог (CRUD, поиск, карта)
│   │   ├── property_valuations_controller.rb
│   │   ├── contact_forms_controller.rb
│   │   ├── dashboard/                  # Личный кабинет
│   │   │   ├── home_controller.rb
│   │   │   ├── favorites_controller.rb
│   │   │   └── ...
│   │   └── api/v1/                     # JSON API
│   ├── models/
│   │   ├── property.rb                 # Основная модель (enums, AASM, scopes)
│   │   ├── user.rb                     # Devise + роли + soft delete
│   │   ├── inquiry.rb
│   │   ├── favorite.rb
│   │   ├── saved_search.rb
│   │   ├── message.rb
│   │   ├── viewing_schedule.rb
│   │   ├── property_valuation.rb
│   │   └── price_history.rb
│   ├── policies/                       # Pundit политики
│   │   ├── application_policy.rb
│   │   ├── property_policy.rb
│   │   ├── inquiry_policy.rb
│   │   └── user_policy.rb
│   ├── services/
│   │   ├── property_evaluation_service.rb
│   │   ├── recommendation_service.rb
│   │   └── pdf_generator_service.rb
│   ├── mailers/
│   │   ├── application_mailer.rb
│   │   ├── inquiry_mailer.rb
│   │   ├── property_valuation_mailer.rb
│   │   ├── viewing_mailer.rb
│   │   └── user_mailer.rb
│   ├── jobs/                           # Sidekiq-задачи
│   │   ├── application_job.rb          # Базовый job (retry, logging)
│   │   ├── inquiry_notification_job.rb
│   │   ├── viewing_notification_job.rb
│   │   ├── property_valuation_completed_job.rb
│   │   ├── property_valuation_follow_up_job.rb
│   │   ├── send_viewing_reminders_job.rb
│   │   ├── update_property_statistics_job.rb
│   │   ├── user_digest_job.rb
│   │   └── market_analytics_update_job.rb
│   ├── channels/
│   │   └── chat_channel.rb             # Action Cable
│   ├── javascript/controllers/         # Stimulus-контроллеры
│   └── views/
│       ├── layouts/                    # application, dashboard, devise, mailer
│       ├── landing/index.html.erb
│       ├── properties/
│       └── shared/
├── config/
│   ├── routes.rb
│   ├── application.rb                  # queue_adapter: :sidekiq, locale: ru
│   ├── sidekiq.yml                     # 5 очередей, concurrency: 5
│   ├── sidekiq_schedule.yml            # Расписание recurring jobs (sidekiq-cron)
│   ├── schedule.rb                     # Whenever (для справки)
│   ├── puma.rb                         # Порт 5000
│   └── environments/
│       ├── development.rb              # Почта в tmp/mails/, hosts.clear
│       ├── test.rb
│       └── production.rb              # Sidekiq, Redis cache, SMTP
├── db/migrate/                         # 15+ миграций
├── spec/                               # RSpec-тесты
└── Gemfile
```

---

## Фоновые задачи

Все задачи наследуются от `ApplicationJob` (auto-retry × 3 с экспоненциальной задержкой).

### Очереди (приоритет)

| Очередь | Назначение |
|---------|-----------|
| `critical` | Критические операции (резерв) |
| `mailers` | Email-уведомления |
| `default` | Общие задачи |
| `scheduled` | Задачи по расписанию |
| `low_priority` | Статистика, аналитика, дайджест |

### Jobs

| Job | Очередь | Описание |
|-----|---------|---------|
| `InquiryNotificationJob` | `mailers` | Уведомления о новых заявках |
| `ViewingNotificationJob` | `mailers` | Уведомления о показах (запрос/подтверждение/напоминание) |
| `PropertyValuationCompletedJob` | `mailers` | Письмо о готовности оценки |
| `PropertyValuationFollowUpJob` | `low_priority` | Follow-up через 3 дня |
| `SendViewingRemindersJob` | `scheduled` | Напоминания о завтрашних показах |
| `UpdatePropertyStatisticsJob` | `low_priority` | Пересчёт счётчиков просмотров/заявок/избранного |
| `UserDigestJob` | `low_priority` | Еженедельный дайджест для подписчиков |
| `MarketAnalyticsUpdateJob` | `low_priority` | Обновление рыночной статистики цен |

### Расписание (sidekiq-cron)

Файл: `config/sidekiq_schedule.yml`

| Задача | Cron | Время |
|--------|------|-------|
| `SendViewingRemindersJob` | `0 * * * *` | Каждый час |
| `UpdatePropertyStatisticsJob` | `0 3 * * *` | Ежедневно в 03:00 |
| `PropertyValuationFollowUpJob` | `0 10 * * *` | Ежедневно в 10:00 |
| `UserDigestJob` | `0 9 * * 0` | Воскресенье в 09:00 |
| `MarketAnalyticsUpdateJob` | `0 5 * * *` | Ежедневно в 05:00 |

### Запуск задач вручную

```bash
# В rails console
UpdatePropertyStatisticsJob.perform_later
MarketAnalyticsUpdateJob.perform_now   # синхронно (для отладки)

# Или через Sidekiq Web UI
# http://localhost:5000/sidekiq  (admin only)
```

---

## API

REST JSON API доступен по адресу `/api/v1/`. Аутентификация через JWT-токен в заголовке `Authorization: Bearer <token>`.

### Основные эндпоинты

```
POST   /api/v1/auth/login              — получить JWT-токен
GET    /api/v1/properties              — список объектов (фильтры, пагинация)
GET    /api/v1/properties/:id          — карточка объекта
GET    /api/v1/properties/featured     — рекомендуемые объекты
GET    /api/v1/properties/:id/similar  — похожие объекты

GET    /api/v1/favorites               — список избранного
POST   /api/v1/favorites               — добавить в избранное
DELETE /api/v1/favorites/:id           — удалить из избранного

GET    /api/v1/inquiries               — список заявок
POST   /api/v1/inquiries               — создать заявку

POST   /api/v1/mortgage_calculator/calculate — расчёт ипотеки
GET    /api/v1/recommendations         — персональные рекомендации
```

---

## Тестирование

```bash
# Запуск всех тестов
bundle exec rspec

# Конкретный файл
bundle exec rspec spec/models/property_spec.rb

# С форматом документации
bundle exec rspec --format documentation
```

Конфигурация тестов:
- Стратегия очистки: `DatabaseCleaner` (transaction / truncation для JS)
- Локаль фикстур: `ru` (Faker::Config.locale = 'ru')
- JS-тесты: Capybara + `selenium_chrome_headless`

---

## Соглашения по коду

1. **Frozen string literals** — каждый `.rb` файл начинается с `# frozen_string_literal: true`
2. **Одинарные кавычки** — RuboCop принудительно (исключение: интерполяция)
3. **Сервис-объекты** — `app/services/`, вызов через `.call` или `#call`
4. **Enums** — всегда с `_prefix: true`, русские названия в комментариях
5. **Scope-лямбды** — всегда `-> { }`, никогда не блок
6. **Мягкое удаление** — `deleted_at` + `default_scope { not_deleted }`
7. **Локализация** — все строки интерфейса через `I18n.t()`, locale `:ru`
8. **Комментарии-баннеры** — разделители секций в стиле `# ====...====`
9. **Jobs** — наследуются от `ApplicationJob`, `queue_as :имя_очереди`, обработка через `deliver_now` внутри job

```bash
# Линтинг
bundle exec rubocop

# Автоисправление
bundle exec rubocop -a
```

---

## Роадмап

- **Выполнено:** Devise + OmniAuth, ActiveAdmin, Pundit, Sidekiq + sidekiq-cron, все базовые CRUD
- **В работе:** Action Cable (чат), Webhooks (AmoCRM, Telegram), PWA
- **Планируется:** мобильное приложение, расширенная аналитика, ИИ-ассистент на Claude API

---

**АН "Виктори" © 2025**
