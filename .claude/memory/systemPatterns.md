# systemPatterns.md — конвенции кода

> Это правила, нарушение которых ломает консистентность проекта. Не редактируй без причины.

## Ruby / Rails

1. **Frozen string literals**: каждый `.rb` начинается с `# frozen_string_literal: true`.
2. **Single quotes** для строк — RuboCop-enforced.
3. **Service objects** в `app/services/`: plain Ruby класс с `initialize(...)` + `call`. Возвращает `Result`-hash (`{ ok:, value:, error: }`) или domain-объект. Вызов: `Service.new(...).call`.
4. **Enums**: всегда с `_prefix: true`; в комментариях рядом — русский перевод значений.
   ```ruby
   enum status: { draft: 0, pending: 1, active: 2, sold: 3, rented: 4, archived: 5, rejected: 6 }, _prefix: true
   ```
5. **Scopes**: lambda-синтаксис `-> { where(...) }`, chain-safe.
6. **Soft delete**: колонка `deleted_at` + `default_scope { not_deleted }`. Никакой `paranoia` gem. Доступ к удалённым — через `.unscoped` или явный `with_deleted` scope.
7. **Callbacks** минимальны. Логику — в сервисах/контроллерах явно.
8. **Localization**: пользовательские строки через `I18n.t()`, default locale `:ru`. Locale files: `config/locales/ru.yml`, `config/locales/devise.ru.yml`.
9. **Section headers** в моделях/сервисах — `# ===========================================` баннер-стиль (см. существующие модели).
10. **RuboCop**: target Ruby 3.2, max line 120, max method length 25. Plugins: `rubocop-rails`, `rubocop-rspec`, `rubocop-performance`.
11. **Price formatting**: всегда `record.price_formatted` (возвращает строку с `₽`). Никаких ручных `number_to_currency`.

## Controllers

- Базовые helpers — в `ApplicationController` (pagination `per_page`, breadcrumbs, UTM capture, device detection, JWT decoding).
- Используй `render_success` / `render_error` для JSON-ответов — консистентный формат.
- Authorization: `require_admin!`, `require_agent!` (Pundit пока отключен; политик нет).
- HTML + JSON через `respond_to do |format|`.

## JavaScript / Stimulus

- Controllers в `app/javascript/controllers/`.
- Stimulus-конвенции: `static targets`, `connect()`/`disconnect()`.
- В ERB — `data-controller`, `data-action`, `data-target`.
- Importmap (НЕ webpack/esbuild). Tailwind через `tailwindcss-rails`.

## Database

- PK — `bigint` (Rails default).
- Индексы на FKs, enum-колонках и часто фильтруемых полях.
- Money — `decimal`, **не** `float`.
- Гибкие настройки — `jsonb` (`notification_settings`, `preferences` на User).
- Гео-запросы — PostGIS `earth_distance` / `ll_to_earth` (raw SQL, не postgis-AR-адаптер).

## Дата/время в UI и сообщениях

**Везде европейский формат `dd.MM.yy`** — в коде, UI, командах, TG-сообщениях. Не ISO, не US.

(Источник: user feedback `feedback_date_format` в auto-memory.)

## Аутентификация (текущее состояние)

- Devise **отключен**. `current_user` → `nil`, `user_signed_in?` → `false`.
- Admin доступ — query-param token: `?token=$ADMIN_TOKEN` (Admin::Reviews, Admin::Articles).
- Не предполагай, что Devise работает. Перед включением — вернуть gem в Gemfile.

## Поиск / Ransack

- `PropertiesController#index` использует Ransack: `@q = Property.published.ransack(params[:q])`.
- Class methods `ransackable_attributes` / `ransackable_associations` / `ransackable_scopes` на `Property` контролируют, что доступно.
- Full-text: PgSearch с русским словарём по title/description/address/district.

## LLM cost discipline

При работе через `app/services/llm/*` и Omni — приоритет **бесплатным провайдерам**: цепочка free-first, paid только как last-resort. См. `feedback_llm_cost_economy` в auto-memory.

## Что НЕ делаем

- НЕ моки БД в integration-спеках без серьёзной причины.
- НЕ форматируем цены вручную (только `price_formatted`).
- НЕ добавляем `paranoia` / `discard` / другой soft-delete gem — у нас свой паттерн.
- НЕ комментим что делает код (имена должны говорить); только **почему**, если неочевидно.
