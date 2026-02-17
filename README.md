# АН "Виктори" — Digital Platform

> Современная платформа для агентства недвижимости: каталог объектов, онлайн-оценка, ипотечный калькулятор, личный кабинет и REST API.

[![Ruby](https://img.shields.io/badge/Ruby-3.2.2-red.svg)](https://www.ruby-lang.org/)
[![Rails](https://img.shields.io/badge/Rails-7.1-red.svg)](https://rubyonrails.org/)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-15+-blue.svg)](https://www.postgresql.org/)

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

> Проект находится в активной разработке. Часть функциональности временно отключена.

### Что работает

| Компонент | Статус | Примечание |
|-----------|--------|------------|
| Landing page | **Активен** | `LandingController`, автономный шаблон без layout |
| Каталог недвижимости | **Активен** | CRUD, поиск через Ransack, фильтры, мягкое удаление |
| Онлайн-оценка | **Активен** | `PropertyValuationsController`, токен-доступ |
| Контактные формы | **Активен** | `ContactFormsController` |
| REST API v1 | **Частично** | Свойства и аутентификационный контроллер реализованы |
| Email-рассылка | **Активен** | InquiryMailer, PropertyValuationMailer, ViewingMailer, UserMailer |

### Что отключено

| Компонент | Причина |
|-----------|---------|
| Devise-аутентификация | Закомментирована; `current_user` всегда `nil`, `user_signed_in?` всегда `false` |
| ActiveAdmin | Отключён вместе с Devise |
| Sidekiq | Закомментирован; Active Job использует адаптер `:async` |
| Rack::Attack | Закомментирован |
| Pundit-авторизация | Stub-методы присутствуют, policy-объекты не созданы |

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
- AI-рекомендации на основе истории просмотров

### Для агентов и администраторов
- CRM-интеграция (AmoCRM webhook)
- Управление объявлениями с модерацией
- Аналитика просмотров и интереса
- Email-уведомления по заявкам и показам
- Управление пользователями и ролями

---

## Технологический стек

| Слой | Технология |
|------|-----------|
| Фреймворк | Rails 7.1, Ruby 3.2.2 |
| База данных | PostgreSQL 15+ |
| Сервер | Puma 6.x |
| CSS | Tailwind CSS (`tailwindcss-rails`) |
| JS | Importmap + Stimulus + Turbo (Hotwire) |
| Аутентификация | bcrypt (Devise — временно отключён) |
| Поиск | Ransack (фильтры) + PgSearch (полнотекстовый, рус. словарь) |
| Пагинация | Kaminari |
| Геокодирование | Geocoder |
| API | Rack::CORS + jbuilder |
| Фоновые задачи | Active Job (`:async`) — Sidekiq отключён |
| Файлы | Active Storage |
| WebSockets | Action Cable |
| Расписание | Whenever (cron) |
| Тесты | RSpec, FactoryBot, Shoulda Matchers, Capybara |
| Линтер | RuboCop (rubocop-rails, rubocop-rspec, rubocop-performance) |

---

## Требования

- Ruby 3.2.2
- PostgreSQL 15+
- (Опционально) Redis — для будущего Sidekiq

Node.js и Yarn **не требуются** — проект использует Importmap.

---

## Установка и запуск

Подробные инструкции — в [QUICKSTART.md](QUICKSTART.md).

```bash
# Установка гемов
bundle install

# Настройка базы данных (см. Переменные окружения)
bin/rails db:create db:migrate db:seed

# Запуск сервера на порту 5000
bin/rails server
```

Приложение доступно по адресу: `http://localhost:5000`

---

## Переменные окружения

Приложение конфигурируется через переменные окружения. Для локальной разработки достаточно минимального набора:

```env
# База данных
DATABASE_HOST=localhost
DATABASE_PORT=5432
DATABASE_USERNAME=postgres
DATABASE_PASSWORD=

# Или одной строкой:
DATABASE_URL=postgresql://postgres@localhost/viktory_realty_development
```

Полный список переменных:

| Переменная | Значение по умолчанию | Описание |
|------------|----------------------|----------|
| `DATABASE_URL` | — | Полный URL PostgreSQL (приоритет перед раздельными переменными) |
| `DATABASE_HOST` | `localhost` | Хост БД |
| `DATABASE_PORT` | `5432` | Порт БД |
| `DATABASE_USERNAME` | `postgres` | Пользователь БД |
| `DATABASE_PASSWORD` | `` | Пароль БД |
| `REDIS_URL` | `redis://localhost:6379/0` | URL Redis (нужен при включении Sidekiq) |
| `RAILS_MAX_THREADS` | `5` | Потоки Puma / пул соединений БД |
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
| `LOG_LEVEL` | `debug`/`info` | Уровень логирования |

---

## Структура проекта

```
victory/
├── app/
│   ├── controllers/
│   │   ├── application_controller.rb   # Базовый контроллер
│   │   ├── landing_controller.rb       # Главная страница
│   │   ├── properties_controller.rb    # Каталог (CRUD, поиск, карта)
│   │   ├── property_valuations_controller.rb
│   │   ├── contact_forms_controller.rb
│   │   ├── dashboard_controller.rb
│   │   └── api/v1/                     # JSON API
│   ├── models/
│   │   ├── property.rb                 # Основная модель (enums, scopes, FTS)
│   │   ├── user.rb                     # Пользователь (роли, soft delete)
│   │   ├── inquiry.rb                  # Заявки клиентов
│   │   ├── favorite.rb
│   │   ├── saved_search.rb
│   │   ├── message.rb
│   │   ├── viewing_schedule.rb
│   │   ├── property_valuation.rb
│   │   └── price_history.rb
│   ├── services/
│   │   ├── property_evaluation_service.rb  # Расчёт рыночной стоимости
│   │   ├── recommendation_service.rb       # AI-рекомендации
│   │   └── pdf_generator_service.rb
│   ├── mailers/
│   │   ├── application_mailer.rb       # Базовый mailer (logo, tracking)
│   │   ├── inquiry_mailer.rb
│   │   ├── property_valuation_mailer.rb
│   │   ├── viewing_mailer.rb
│   │   └── user_mailer.rb              # Приветственное письмо
│   ├── jobs/                           # Active Job задачи
│   ├── channels/
│   │   └── chat_channel.rb             # Action Cable
│   ├── javascript/controllers/         # Stimulus-контроллеры
│   │   ├── app_controller.js
│   │   ├── mortgage_calculator_controller.js
│   │   ├── yandex_map_controller.js
│   │   ├── favorite_controller.js
│   │   └── chat_controller.js
│   └── views/
│       ├── layouts/                    # application, dashboard, mailer
│       ├── landing/index.html.erb      # Автономная посадочная страница
│       ├── properties/
│       └── shared/
├── config/
│   ├── routes.rb                       # Полная таблица маршрутов
│   ├── application.rb                  # Таймзона Москва, locale: ru
│   ├── puma.rb                         # Порт 5000, 0.0.0.0
│   └── environments/
│       └── development.rb              # config.hosts.clear (Replit)
├── db/migrate/                         # 13 миграций
├── spec/                               # RSpec-тесты
└── Gemfile
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

```bash
# Линтинг
bundle exec rubocop

# Автоисправление
bundle exec rubocop -a
```

---

## Роадмап

Полный план развития — в [ROADMAP.md](ROADMAP.md).

**Краткое резюме:**
- **Фаза 1 (ближайшая):** включение аутентификации Devise и ActiveAdmin
- **Фаза 2:** Sidekiq, полнотекстовый поиск, Pundit-авторизация, интеграции
- **Фаза 3:** мобильное приложение, расширенная аналитика, ИИ-ассистент

---

**АН "Виктори" © 2025**
