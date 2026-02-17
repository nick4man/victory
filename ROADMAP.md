# Roadmap — АН "Виктори"

> Дорожная карта развития платформы. Отражает реальное текущее состояние кода и приоритеты развития.

**Последнее обновление:** февраль 2026
**Версия кодовой базы:** Rails 7.1 / Ruby 3.2.2

---

## Текущее состояние

### Что реализовано и работает

#### Ядро приложения
- [x] Rails 7.1 + PostgreSQL, структура проекта, конфигурация окружений
- [x] Модель `Property` — полный CRUD, enums, мягкое удаление (`deleted_at`), FriendlyId-слаги, геокодирование
- [x] `PropertiesController` — список с фильтрами (Ransack), карточка, карта, сравнение объектов
- [x] Онлайн-оценка недвижимости (`PropertyValuationController` + `PropertyEvaluationService`)
- [x] Контактные формы (`ContactFormsController`)
- [x] Landing page — автономный HTML-шаблон с Tailwind CDN

#### Модели данных (миграции применены)
- [x] `users` — с ролями (client / agent / admin), soft delete, JSONB-настройки
- [x] `properties` — основная модель, все поля и индексы
- [x] `property_types` — справочник типов недвижимости
- [x] `inquiries` — заявки клиентов
- [x] `favorites` — избранные объекты
- [x] `saved_searches` — сохранённые поисковые запросы
- [x] `messages` — сообщения между пользователями
- [x] `property_views` — история просмотров
- [x] `reviews` — отзывы
- [x] `documents` — документы объектов
- [x] `viewing_schedules` — расписание показов
- [x] `price_histories` — история цен
- [x] `property_valuations` — результаты оценки

#### Сервисы и бизнес-логика
- [x] `PropertyEvaluationService` — расчёт рыночной стоимости
- [x] `RecommendationService` — AI-рекомендации на основе истории просмотров
- [x] `PdfGeneratorService` — генерация PDF-отчётов (заготовка)

#### Email-уведомления
- [x] `ApplicationMailer` — база с логотипом, трекингом, логированием
- [x] `InquiryMailer` — 6 типов писем по заявкам
- [x] `PropertyValuationMailer` — уведомления об оценке
- [x] `ViewingMailer` — подтверждения и напоминания о показах
- [x] `UserMailer` — приветственное письмо при регистрации

#### Фоновые задачи (Active Job, адаптер :async)
- [x] `SendViewingRemindersJob`
- [x] `UpdatePropertyStatisticsJob`
- [x] `InquiryNotificationJob`
- [x] `ViewingNotificationJob`
- [x] `PropertyValuationCompletedJob`
- [x] `PropertyValuationFollowUpJob`

#### API v1
- [x] `Api::V1::BaseController` — JWT-аутентификация
- [x] `Api::V1::AuthenticationController` — login / logout / refresh
- [x] `Api::V1::PropertiesController` — index, show, search, featured, similar

#### Frontend (Stimulus + Turbo)
- [x] `app_controller.js` — мобильное меню, скролл
- [x] `mortgage_calculator_controller.js` — ипотечный калькулятор
- [x] `yandex_map_controller.js` — карта объектов
- [x] `favorite_controller.js` — добавление в избранное
- [x] `chat_controller.js` — чат (Action Cable)

#### Тестирование
- [x] RSpec + FactoryBot + DatabaseCleaner настроены
- [x] Shared examples и request helpers

### Что отключено (закомментировано)

| Компонент | Файл | Примечание |
|-----------|------|------------|
| Devise-аутентификация | `Gemfile`, `application_controller.rb` | `current_user` → `nil` |
| ActiveAdmin | `Gemfile` | Зависит от Devise |
| Sidekiq | `Gemfile`, `config/sidekiq.yml` | Jobs работают через `:async` |
| Rack::Attack | `Gemfile` | Rate limiting отсутствует |
| Pundit | `Gemfile`, `application_controller.rb` | Stub-методы есть, policy-объектов нет |

### Контроллеры-заглушки (маршруты есть, контроллеров нет)

Маршруты в `config/routes.rb` определены, но реализующие контроллеры ещё не созданы:
`BlogController`, `NewsController`, `SitemapController`, `RobotsController`, `PwaController`,
`HealthController`, `ErrorsController`, `ChatController`, `ChatbotController`, `SellController`,
`ServicesController`, `FormsController`, `WebhooksController`.

---

## Фаза 1 — Стабилизация (приоритет: высокий)

Цель: привести приложение в рабочее состояние с полноценной аутентификацией.

### 1.1 Включение аутентификации
- [ ] Добавить `devise` в `Gemfile` и запустить `bundle install`
- [ ] Убрать комментарии в `Gemfile` и `application_controller.rb`
- [ ] Добавить `pundit` в `Gemfile`, создать базовые policy-объекты
- [ ] Написать миграцию для колонок Devise (или раскомментировать существующую)
- [ ] Настроить Devise для локали `ru` (уже есть `config/locales/devise.ru.yml`)
- [ ] Заменить stub-методы `user_signed_in?` и `current_user` на реальные Devise-хелперы
- [ ] Включить Google и Yandex OAuth (`omniauth-google-oauth2`, `omniauth-yandex`)

### 1.2 Включение ActiveAdmin
- [ ] Добавить `activeadmin` в `Gemfile`
- [ ] Запустить `rails generate active_admin:install`
- [ ] Создать ресурсы: `Property`, `User`, `Inquiry`

### 1.3 Заполнение тестового каталога
- [ ] Написать `db/seeds.rb` с реалистичными данными (10–50 объектов, 3–5 пользователей)
- [ ] Добавить фабрики FactoryBot для всех ключевых моделей

### 1.4 Реализация недостающих контроллеров
- [ ] `HealthController` — `/health`, `/health/database`
- [ ] `ErrorsController` — страницы 404, 422, 500
- [ ] `SitemapController`, `RobotsController` — SEO-файлы

### 1.5 Покрытие тестами
- [ ] Тесты модели `Property` (scopes, validations, methods)
- [ ] Тесты модели `User`
- [ ] Request-тесты `PropertiesController`
- [ ] Тесты `PropertyEvaluationService`

---

## Фаза 2 — Полнотекстовый поиск и интеграции (приоритет: средний)

Цель: полноценный поиск, фоновые задачи и внешние сервисы.

### 2.1 Включение Sidekiq
- [ ] Добавить `sidekiq` в `Gemfile`
- [ ] Изменить `config.active_job.queue_adapter` с `:async` на `:sidekiq`
- [ ] Настроить очереди в `config/sidekiq.yml` (critical, mailers, default, scheduled, low_priority)
- [ ] Запустить cron через Whenever: `bundle exec whenever --update-crontab`

### 2.2 PgSearch (полнотекстовый поиск)
- [ ] Добавить `pg_search` в `Gemfile`
- [ ] Раскомментировать `PgSearch::Multisearch` в модели `Property`
- [ ] Создать индексы GIN для полнотекстового поиска (русский словарь `russian`)
- [ ] Подключить поиск в `PropertiesController`

### 2.3 Дополнение REST API
- [ ] `Api::V1::FavoritesController`
- [ ] `Api::V1::InquiriesController`
- [ ] `Api::V1::SavedSearchesController`
- [ ] `Api::V1::RecommendationsController`
- [ ] `Api::V1::MortgageCalculatorController`

### 2.4 Интеграция Яндекс.Карт
- [ ] Подключить API-ключ через `ENV['YANDEX_MAPS_API_KEY']`
- [ ] Геокодирование объектов при создании/обновлении (Geocoder)
- [ ] Кластеризация маркеров на странице `/properties/map`

### 2.5 Включение Rack::Attack
- [ ] Добавить `rack-attack` в `Gemfile`
- [ ] Настроить лимиты: API — 60 запросов/мин, формы — 10 запросов/мин
- [ ] Whitelist для локального окружения

### 2.6 Webhooks
- [ ] `WebhooksController#amocrm` — синхронизация заявок с AmoCRM
- [ ] `WebhooksController#telegram` — уведомления агентам через Telegram-бота
- [ ] `WebhooksController#yookassa` — обработка платежей

---

## Фаза 3 — Личный кабинет и UX (приоритет: средний)

Цель: завершить пользовательские сценарии.

### 3.1 Личный кабинет (DashboardController)
- [ ] Профиль пользователя с редактированием
- [ ] Список избранных объектов с удалением
- [ ] История просмотров
- [ ] Мои заявки с фильтром по статусу
- [ ] Сохранённые поиски и уведомления о новых объектах
- [ ] Внутренние сообщения (Message + Action Cable)
- [ ] Настройки уведомлений (JSONB-поле `notification_settings`)

### 3.2 Личный кабинет агента
- [ ] Список назначенных объектов
- [ ] Управление расписанием показов
- [ ] Статистика: просмотры, заявки, конверсия

### 3.3 Чат и коммуникации
- [ ] `ChatController` + `ChatChannel` (Action Cable) — реал-тайм чат
- [ ] `ChatbotController` — AI-чат-бот для быстрых ответов на FAQ
- [ ] Push-уведомления через Action Cable

### 3.4 Раздел для продавцов
- [ ] `SellController#evaluation` — форма онлайн-оценки
- [ ] `SellController#listings` — управление своими объявлениями
- [ ] Пошаговая форма создания объявления

### 3.5 Виртуальные туры
- [ ] Интеграция 3D-тура (iframe или собственный просмотрщик)
- [ ] Галерея с высоким разрешением (Active Storage + вариации)

---

## Фаза 4 — Производительность и SEO (приоритет: низкий)

### 4.1 Кэширование
- [ ] Подключить Redis для кэша (`config.cache_store = :redis_cache_store`)
- [ ] Fragment caching для карточек объектов
- [ ] HTTP-кэширование (ETags, Last-Modified)

### 4.2 SEO
- [ ] `SitemapController` — динамический `sitemap.xml`
- [ ] `RobotsController` — `robots.txt`
- [ ] Мета-теги для каждого объекта (Open Graph, Twitter Card)
- [ ] FriendlyId-слаги для всех объектов

### 4.3 PWA
- [ ] `PwaController` — `manifest.json`, `service-worker.js`, страница offline
- [ ] Кэширование ресурсов в Service Worker

### 4.4 Мониторинг
- [ ] Интеграция Sentry (ошибки)
- [ ] Метрики производительности (Scout APM или аналог)
- [ ] Health-check эндпоинты с реальными проверками БД и Redis

### 4.5 Блог и контент
- [ ] `BlogController` — статьи по тематике недвижимости
- [ ] `NewsController` — новости рынка
- [ ] Admin-интерфейс для управления контентом

---

## Фаза 5 — Расширенные возможности (долгосрочно)

### 5.1 Расширенная аналитика
- [ ] Внутренняя аналитика просмотров (Ahoy Matey или собственная)
- [ ] Яндекс.Метрика + Google Analytics
- [ ] Тепловые карты интереса по районам

### 5.2 AI-функции
- [ ] Улучшенные рекомендации на основе машинного обучения
- [ ] Автоматическая оценка стоимости по рыночным данным
- [ ] AI-генерация описаний объектов

### 5.3 Мобильное приложение
- [ ] REST API v2 с полной документацией (OpenAPI/Swagger)
- [ ] React Native или Flutter клиент
- [ ] Push-уведомления (FCM)

### 5.4 Ипотечный брокер
- [ ] Интеграция с несколькими банками
- [ ] Онлайн-подача заявки на ипотеку
- [ ] Трекинг статуса одобрения

---

## Технический долг

Задачи по качеству кода, которые нужно решить параллельно с разработкой:

- [ ] Написать тесты для всех моделей (target: 80%+ coverage)
- [ ] Покрыть request-тестами все публичные контроллеры
- [ ] Убрать оставшиеся `rescue StandardError` без логирования
- [ ] Реализовать Analytics-hook в `Property#track_creation` (сейчас пустой)
- [ ] Добавить индексы `GIN` для JSONB-колонок (`notification_settings`, `preferences`)
- [ ] Заменить `raise NotImplementedError` на реальные реализации в API-контроллерах
- [ ] Провести аудит безопасности: SQL-инъекции, XSS, CSRF

---

## Принципы приоритизации

1. **Стабильность > новые функции** — сначала включить отключённые компоненты
2. **Аутентификация блокирует всё остальное** — без неё нельзя завершить dashboard, admin, API
3. **Тесты пишутся параллельно** — не после реализации, а в процессе
4. **Реальные данные важнее заглушек** — stub-методы нужно заменять в порядке приоритета

---

*Для предложений и изменений в роадмапе — создайте issue или обратитесь к команде.*
