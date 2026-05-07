# RUNBOOK — АН "Виктори" : развёртывание и диагностика

> Этот документ предназначен для AI-ассистентов и инженеров, выполняющих первичную установку, обновление или диагностику проекта. Читайте линейно — каждый шаг зависит от предыдущего.

---

## Оглавление

1. [Требования](#1-требования)
2. [Docker (рекомендуемый способ)](#2-docker-рекомендуемый-способ)
3. [Первичная установка без Docker (development)](#3-первичная-установка-без-docker-development)
4. [Переменные окружения](#4-переменные-окружения)
5. [Запуск сервисов](#5-запуск-сервисов)
6. [Проверка работоспособности](#6-проверка-работоспособности)
7. [Развёртывание в production](#7-развёртывание-в-production)
8. [Частые ошибки и их решения](#8-частые-ошибки-и-их-решения)
9. [Диагностические команды](#9-диагностические-команды)

---

## 1. Требования

| Компонент | Версия | Зачем |
|-----------|--------|-------|
| Ruby | **3.2.x – 3.3.x** | Рантайм. Проверено на 3.3.6. |
| Rails | **7.1.x** | Фреймворк |
| PostgreSQL | **15 или 16** | Основная БД (JSONB, PgSearch, earth_distance) |
| Redis | **6.2 или 7.0** | Сессии, кэш, Sidekiq, Rack::Attack |
| Bundler | **2.4+** | Управление гемами |
| Node.js | **не нужен** | Проект использует Importmap, не Webpack |

Установка Ruby через rbenv:
```bash
rbenv install 3.3.6
rbenv local 3.3.6
ruby -v   # -> ruby 3.3.6
```

---

## 2. Docker (рекомендуемый способ)

### Структура файлов

| Файл | Назначение |
|------|-----------|
| `Dockerfile` | Многоэтапный образ (build → final). Ruby 3.2.2-slim. |
| `docker-compose.yml` | Production-стек: db, redis, web, sidekiq, migrate |
| `docker-compose.override.yml` | Development-переопределения: монтирование кода, tailwind watch |
| `.dockerignore` | Исключения из контекста сборки |
| `bin/docker-entrypoint` | Entrypoint: очистка PID, создание каталогов, опциональные миграции |

### Быстрый старт (production-режим)

```bash
# 1. Создать .env из примера и заполнить обязательные переменные
cp .env.example .env
# Минимум: DATABASE_PASSWORD, SECRET_KEY_BASE, JWT_SECRET_KEY

# 2. Собрать образ и поднять стек
docker compose up --build -d

# 3. Запустить миграции (один раз, при первом деплое и после каждого обновления)
docker compose run --rm migrate

# 4. Проверить здоровье
docker compose ps
curl http://localhost:5000/health
```

### Быстрый старт (development-режим)

В dev-режиме `docker-compose.override.yml` подгружается автоматически.
Исходный код монтируется в контейнер — изменения видны без пересборки.

```bash
cp .env.example .env
# DATABASE_HOST=db, REDIS_URL=redis://redis:6379/0 уже заданы в override

docker compose up --build
# Открыть http://localhost:5000
# Tailwind пересобирается автоматически через сервис `tailwind`
```

### Ключевые команды

```bash
# Статус контейнеров
docker compose ps

# Логи в реальном времени
docker compose logs -f web
docker compose logs -f sidekiq

# Открыть Rails console
docker compose exec web bundle exec rails console

# Открыть bash в контейнере
docker compose exec web bash

# Запустить миграции
docker compose run --rm migrate

# Пересобрать только образ приложения
docker compose build web

# Остановить всё (данные сохраняются в volumes)
docker compose down

# Остановить и удалить volumes (УДАЛИТ ДАННЫЕ БД!)
docker compose down -v
```

### Сервисы и порты

| Сервис | Образ | Внешний порт | Назначение |
|--------|-------|-------------|-----------|
| `db` | `postgres:16-alpine` | `127.0.0.1:5432` | PostgreSQL |
| `redis` | `redis:7-alpine` | `127.0.0.1:6379` | Кэш, очереди, Rack::Attack |
| `web` | `victory:latest` | `0.0.0.0:5000` | Rails / Puma |
| `sidekiq` | `victory:latest` | — | Фоновые задачи |
| `migrate` | `victory:latest` | — | One-off миграции |

В production `db` и `redis` не открываются наружу (bind `127.0.0.1`).
В development override — bind `0.0.0.0` для удобства.

### Переменные окружения для Docker

В production `docker-compose.yml` передаёт эти переменные автоматически:

```env
DATABASE_HOST=db        # имя Docker-сервиса, не localhost
DATABASE_PORT=5432
REDIS_URL=redis://redis:6379/0
```

Остальные (пароли, ключи) берутся из `.env` через `env_file: .env`.

### ARM (Apple M1/M2, aarch64 серверы)

Lockfile содержит платформу `x86_64-linux` для `tailwindcss-ruby`. Для ARM:

```bash
bundle lock --add-platform aarch64-linux
docker compose build
```

### Обновление приложения

```bash
git pull
docker compose build web sidekiq
docker compose run --rm migrate
docker compose up -d web sidekiq
```

### Частые ошибки Docker

**`DATABASE_PASSWORD is required`**
`.env` не создан или переменная пуста. Заполните `.env` из `.env.example`.

**`standard_init_linux.go: exec user process caused: permission denied`**
Entrypoint не исполняемый. Исправьте: `chmod +x bin/docker-entrypoint`

**`Could not find gem 'xyz' in locally installed gems`**
В dev-режиме `bundle_cache` volume устарел. Пересоберите: `docker compose build --no-cache web`

**`Rack::Attack блокирует все запросы` (429)**
Redis недоступен. Проверьте: `docker compose ps redis` — статус должен быть `healthy`.

**`ActiveRecord::NoDatabaseError`**
Миграции не запущены. Выполните: `docker compose run --rm migrate`

**Tailwind CSS не обновляется (development)**
Убедитесь, что сервис `tailwind` запущен: `docker compose ps tailwind`.
Или перезапустите: `docker compose restart tailwind`.

---

## 3. Первичная установка без Docker (development)

### 2.1 Клонирование и гемы

```bash
git clone <repo_url> victory
cd victory
bundle install
```

Если `bundle install` зависает или падает с ошибкой компиляции нативных расширений:
```bash
# pg — нужны заголовки libpq
sudo apt-get install libpq-dev   # Ubuntu/Debian
brew install libpq                # macOS
bundle config set --local build.pg "--with-pg-config=$(which pg_config)"
bundle install
```

### 2.2 Переменные окружения

```bash
cp .env.example .env
# Откройте .env и заполните минимальный набор (см. раздел 3)
```

### 2.3 База данных

```bash
bin/rails db:create
bin/rails db:migrate
bin/rails db:seed          # тестовые пользователи + образцы объявлений
```

Если нужна чистая переустановка:
```bash
bin/rails db:drop db:create db:migrate db:seed
```

### 2.4 Tailwind CSS

Tailwind собирается автоматически при старте сервера через `tailwindcss-rails`. Принудительная пересборка:
```bash
bin/rails tailwindcss:build
```

Для режима watch (пересборка при изменении файлов):
```bash
bin/rails tailwindcss:watch
```

### 2.5 Запуск

```bash
bin/rails server -p 5000 -b 0.0.0.0
```

Приложение: `http://localhost:5000`

---

## 4. Переменные окружения

### Обязательные (приложение не запустится без них)

| Переменная | Пример | Описание |
|------------|--------|----------|
| `DATABASE_HOST` | `localhost` | Хост PostgreSQL |
| `DATABASE_PORT` | `5432` | Порт PostgreSQL |
| `DATABASE_USERNAME` | `postgres` | Пользователь PostgreSQL |
| `DATABASE_PASSWORD` | `secret` | Пароль PostgreSQL |
| `REDIS_URL` | `redis://localhost:6379/0` | URL Redis (Sidekiq + Rack::Attack) |
| `SECRET_KEY_BASE` | `bin/rails secret` | Ключ сессий Rails (для production) |
| `JWT_SECRET_KEY` | `bin/rails secret` | Подписание JWT для API |

Генерация ключей:
```bash
bin/rails secret   # вывести случайную строку
```

### Важные (функционал недоступен без них)

| Переменная | Описание |
|------------|----------|
| `GOOGLE_CLIENT_ID` + `GOOGLE_CLIENT_SECRET` | OAuth «Войти через Google». Без них кнопка не появляется. |
| `SMTP_ADDRESS` + `SMTP_USERNAME` + `SMTP_PASSWORD` | Исходящая почта. Без них `deliver_later` будет молча завершаться. |
| `YANDEX_MAPS_API_KEY` | Интерактивные карты на страницах объектов и контактов. |
| `AMOCRM_WEBHOOK_SECRET` + `TELEGRAM_WEBHOOK_SECRET` | Подпись входящих вебхуков. Без них `/webhooks/*` возвращает 401. |

### Опциональные

| Переменная | Назначение |
|------------|-----------|
| `YANDEX_METRIKA_ID` | Метрика (аналитика) |
| `GOOGLE_ANALYTICS_ID` | Google Analytics |
| `SENTRY_DSN` | Трекинг ошибок |
| `AWS_*` | S3 для Active Storage в production |
| `COMPANY_PHONE`, `COMPANY_EMAIL`, `COMPANY_ADDRESS` | Отображаются на странице контактов |

### Переменные development (обычно не нужны)

В режиме `development`:
- Почта сохраняется в `tmp/mails/` (letter_opener_web), SMTP не нужен
- `config.hosts.clear` отключён — любой хост разрешён (для Replit/ngrok)
- `LOG_LEVEL=debug` по умолчанию

---

## 5. Запуск сервисов

### PostgreSQL

```bash
# Ubuntu/Debian
sudo systemctl start postgresql
sudo systemctl enable postgresql

# macOS (Homebrew)
brew services start postgresql@16
```

### Redis

```bash
# Ubuntu/Debian
sudo systemctl start redis-server

# macOS
brew services start redis

# Проверка
redis-cli ping   # -> PONG
```

### Rails-сервер

```bash
bin/rails server -p 5000 -b 0.0.0.0
```

### Sidekiq (фоновые задачи)

```bash
bundle exec sidekiq -C config/sidekiq.yml -e development
```

Веб-интерфейс: `http://localhost:5000/sidekiq` (только `role: :admin`)

### Запуск всего одной командой (Foreman)

Если установлен `foreman`:
```bash
# Создайте Procfile.dev если его нет:
cat > Procfile.dev <<'EOF'
web: bin/rails server -p 5000 -b 0.0.0.0
worker: bundle exec sidekiq -C config/sidekiq.yml -e development
css: bin/rails tailwindcss:watch
EOF

foreman start -f Procfile.dev
```

---

## 6. Проверка работоспособности

После запуска пройдитесь по этим URL:

| URL | Ожидаемый ответ |
|-----|-----------------|
| `http://localhost:5000/` | Лендинг «АН Виктори» |
| `http://localhost:5000/properties` | Каталог недвижимости |
| `http://localhost:5000/health` | `{"status":"ok","timestamp":"..."}` |
| `http://localhost:5000/health/database` | `{"status":"ok","database":"connected"}` (только с localhost) |
| `http://localhost:5000/users/sign_in` | Страница входа Devise |
| `http://localhost:5000/admin` | ActiveAdmin (нужен admin-аккаунт) |

Тестовые аккаунты (после `db:seed`):

| Email | Пароль | Роль |
|-------|--------|------|
| `admin@victory.ru` | `Password123!` | Администратор |
| `agent@victory.ru` | `Password123!` | Агент |
| `client@victory.ru` | `Password123!` | Клиент |

Проверка Rails в консоли:
```bash
bin/rails runner "puts 'OK: ' + Rails.version"
# -> OK: 7.1.6

bin/rails runner "puts ActiveRecord::Base.connection.execute('SELECT 1').first.inspect"
# -> {"?column?"=>1}

bin/rails runner "puts Rack::Attack.throttles.keys.join(', ')"
# -> global, login, signup, api, contact, valuations
```

---

## 7. Развёртывание в production

### 6.1 Переменные окружения

Убедитесь, что заданы все обязательные переменные (раздел 3). Дополнительно для production:

```env
RAILS_ENV=production
FORCE_SSL=true
ASSET_HOST=https://cdn.example.com    # если используется CDN
DATABASE_URL=postgresql://user:pass@host:5432/viktory_realty_production
REDIS_URL=redis://:password@host:6379/0
SECRET_KEY_BASE=<сгенерируйте: rails secret>
JWT_SECRET_KEY=<сгенерируйте: rails secret>
RAILS_LOG_TO_STDOUT=true
WEB_CONCURRENCY=2
RAILS_MAX_THREADS=5
```

### 6.2 Деплой

```bash
# Установить гемы без development/test групп
bundle install --without development test

# Собрать ассеты
RAILS_ENV=production bin/rails assets:precompile
bin/rails tailwindcss:build

# Запустить миграции
RAILS_ENV=production bin/rails db:migrate

# Запустить сервер
RAILS_ENV=production bin/rails server -p 5000 -b 0.0.0.0

# Запустить Sidekiq
RAILS_ENV=production bundle exec sidekiq -C config/sidekiq.yml
```

### 6.3 Active Storage в production

Для хранения файлов в S3 задайте в `.env`:
```env
ACTIVE_STORAGE_SERVICE=amazon
AWS_ACCESS_KEY_ID=...
AWS_SECRET_ACCESS_KEY=...
AWS_REGION=eu-central-1
AWS_S3_BUCKET=viktory-realty-uploads
```

И в `config/storage.yml` убедитесь, что секция `amazon:` заполнена.

---

## 8. Частые ошибки и их решения

### PG::ConnectionBad: could not connect to server

**Симптом:**
```
ActiveRecord::DatabaseConnectionError: There is an issue connecting to your database
PG::ConnectionBad: could not connect to server: Connection refused
```
**Причина:** PostgreSQL не запущен, или неверные `DATABASE_HOST`/`DATABASE_PORT`.

**Решение:**
```bash
# Проверить статус
pg_lsclusters        # Ubuntu
brew services list   # macOS

# Запустить
sudo systemctl start postgresql

# Проверить подключение
psql -h $DATABASE_HOST -U $DATABASE_USERNAME -c '\l'
```

---

### Redis::CannotConnectError

**Симптом:**
```
Redis::CannotConnectError: Error connecting to Redis on localhost:6379 (Errno::ECONNREFUSED)
```
**Причина:** Redis не запущен.

**Решение:**
```bash
redis-server --daemonize yes
redis-cli ping   # -> PONG
```

Rack::Attack и Sidekiq оба требуют Redis. Если Redis недоступен, запросы будут блокироваться с ошибкой 500.

---

### Rack::Attack блокирует все запросы

**Симптом:** Все запросы возвращают 429 Too Many Requests.

**Причина:** Redis недоступен, и Rack::Attack не может читать счётчики — при некоторых конфигурациях `fail open` не работает.

**Диагностика:**
```bash
redis-cli ping
```

**Быстрое отключение Rack::Attack (для диагностики):**
```ruby
# config/initializers/rack_attack.rb — добавить в начало:
Rack::Attack.enabled = false
```
Перезапустите сервер после изменения.

**Полное отключение в application.rb:**
```ruby
# config/application.rb — закомментировать:
# config.middleware.use Rack::Attack
```

---

### Миграции зависают / ActiveRecord::PendingMigrationError

**Симптом:**
```
Migrations are pending. To resolve this issue, run: bin/rails db:migrate RAILS_ENV=development
```
**Решение:**
```bash
bin/rails db:migrate
bin/rails db:migrate:status   # посмотреть статус каждой миграции
```

Если миграция упала на полпути (broken state):
```bash
bin/rails db:migrate:down VERSION=<timestamp>
# исправить миграцию
bin/rails db:migrate
```

---

### Devise: Confirmation instructions не доходят

**Симптом:** Пользователь регистрируется, письмо не приходит, аккаунт не подтверждается.

**Причина в development:** Письма сохраняются в `tmp/mails/`, не отправляются.

**Решение (development):**
```bash
# Посмотреть последние письма
ls -lt tmp/mails/ | head

# Или использовать letter_opener_web
# http://localhost:5000/letter_opener
```

**Причина в production:** Неверные SMTP-настройки.

**Диагностика:**
```bash
bin/rails runner "UserMailer.welcome_email(User.first).deliver_now"
# Посмотреть log/production.log на ошибки SMTP
```

---

### JWT::DecodeError: Signature verification failed

**Симптом:** API возвращает `401 Unauthorized: Invalid token`.

**Причина:** `JWT_SECRET_KEY` изменился после выдачи токенов, или переменная не задана.

**Решение:**
```bash
# Убедиться, что переменная задана
echo $JWT_SECRET_KEY

# Сгенерировать новый ключ и обновить .env
bin/rails secret
```

После смены ключа все существующие токены станут недействительными.

---

### OmniAuth: Google OAuth не работает / кнопка отсутствует

**Симптом:** Кнопка «Войти через Google» не отображается на странице входа.

**Причина:** Переменные `GOOGLE_CLIENT_ID` и/или `GOOGLE_CLIENT_SECRET` не заданы.

**Решение:**
```bash
echo $GOOGLE_CLIENT_ID      # не пусто?
echo $GOOGLE_CLIENT_SECRET  # не пусто?
```

Кнопка не отображается намеренно, если credentials отсутствуют (защита от dummy-credential OAuth).

Для настройки Google OAuth:
1. Откройте [console.cloud.google.com](https://console.cloud.google.com/)
2. Создайте OAuth 2.0 credentials
3. Разрешённые redirect URI: `http://localhost:5000/users/auth/google_oauth2/callback`
4. Запишите Client ID и Client Secret в `.env`

---

### Webhook 401: Unauthorized

**Симптом:** POST на `/webhooks/amocrm` или `/webhooks/telegram` → 401.

**Причина:** Переменные `AMOCRM_WEBHOOK_SECRET` / `TELEGRAM_WEBHOOK_SECRET` не заданы.

**Решение:**
```bash
export AMOCRM_WEBHOOK_SECRET="your_secret_here"
# Или добавить в .env и перезапустить сервер
```

---

### NoMethodError: undefined method 'authenticate_api_user!'

**Симптом:** 500 при обращении к `/api/v1/*`.

**Причина:** Контроллер наследует не от `Api::V1::BaseController`.

**Решение:** убедитесь, что все контроллеры в `app/controllers/api/v1/` наследуют от `Api::V1::BaseController`:
```ruby
class Api::V1::MyController < Api::V1::BaseController
```

---

### Sidekiq: jobs не выполняются

**Симптом:** Задачи ставятся в очередь, но никогда не выполняются.

**Диагностика:**
```bash
# Sidekiq запущен?
ps aux | grep sidekiq

# Redis доступен?
redis-cli ping

# Очереди в Sidekiq
redis-cli LLEN queue:default
redis-cli LLEN queue:mailers
```

**Решение:**
```bash
# Запустить Sidekiq вручную
bundle exec sidekiq -C config/sidekiq.yml -e development

# Или выполнить job синхронно для отладки
bin/rails runner "UpdatePropertyStatisticsJob.perform_now"
```

---

### ActionController::InvalidAuthenticityToken (CSRF)

**Симптом:** 422 при отправке форм.

**Причина:** CSRF-токен не передаётся или устарел (например, после смены сессии).

**Решение для AJAX-форм:**
```javascript
// Добавить заголовок X-CSRF-Token в запрос:
headers: { 'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]').content }
```

Для API-эндпоинтов CSRF не нужен — они используют JWT и наследуют от `Api::V1::BaseController < ActionController::API`.

---

### PgSearch: ошибка при поиске (unrecognized configuration parameter)

**Симптом:**
```
PG::UndefinedObject: ERROR: text search configuration "russian" does not exist
```
**Причина:** PostgreSQL не имеет Russian text search dictionary.

**Решение:**
```sql
-- В psql
CREATE TEXT SEARCH CONFIGURATION russian (COPY = pg_catalog.russian);
-- Или использовать 'simple' вместо 'russian' в PgSearch конфигурации
```

---

### Assets не загружаются (404 на CSS/JS)

**Симптом:** Страница открывается без стилей, 404 на `/assets/tailwind-*.css`.

**Причина:** Tailwind CSS не скомпилирован.

**Решение:**
```bash
bin/rails tailwindcss:build

# В development — запустить в watch-режиме в отдельном терминале:
bin/rails tailwindcss:watch
```

---

### Переменная окружения не читается

**Симптом:** `ENV['MY_VAR']` возвращает `nil` несмотря на то, что переменная задана в `.env`.

**Причина:** Гем `dotenv-rails` не загружает `.env` автоматически в ряде конфигураций, или переменная задана после старта сервера.

**Решение:**
```bash
# Убедиться, что dotenv-rails в Gemfile (группа development):
grep dotenv Gemfile

# Перезапустить сервер после изменения .env
# Или задать переменную явно:
MY_VAR=value bin/rails server
```

---

## 9. Диагностические команды

### Общее состояние

```bash
# Версия Rails и Ruby
bin/rails --version && ruby -v

# Миграции
bin/rails db:migrate:status

# Роуты (поиск по имени)
bin/rails routes | grep properties

# Загрузка приложения без сервера
bin/rails runner "puts Rails.env"
```

### База данных

```bash
# Подключение
bin/rails dbconsole

# Количество записей в основных таблицах
bin/rails runner "
  [Property, User, Inquiry, Favorite, PropertyView, SavedSearch].each do |m|
    puts \"#{m}: #{m.unscoped.count}\"
  end
"

# Проверка индексов (важно для PgSearch)
bin/rails runner "puts ActiveRecord::Base.connection.indexes(:properties).map(&:name)"
```

### Redis и Rack::Attack

```bash
# Список активных throttle-ключей
redis-cli KEYS "rack::attack:*" | head -20

# Сброс всех лимитов (для теста)
redis-cli FLUSHDB   # ОСТОРОЖНО: очистит весь Redis!

# Сколько запросов с IP сделано за последний час
redis-cli GET "rack::attack:3600:api:127.0.0.1"
```

### Sidekiq

```bash
# Статистика очередей
bin/rails runner "
  require 'sidekiq/api'
  puts Sidekiq::Stats.new.inspect
  Sidekiq::Queue.all.each { |q| puts \"#{q.name}: #{q.size} jobs\" }
"

# Очистить все очереди (ОСТОРОЖНО)
bin/rails runner "Sidekiq::Queue.all.each(&:clear)"

# Посмотреть retry-список
bin/rails runner "
  require 'sidekiq/api'
  Sidekiq::RetrySet.new.each { |j| puts j.klass + ': ' + j.error_message.to_s }
"
```

### Логи

```bash
# Последние 100 строк development-лога
tail -100 log/development.log

# Только ошибки
grep -i "error\|exception\|failed" log/development.log | tail -50

# Логи Sidekiq (если запущен отдельно)
tail -f log/sidekiq.log
```

### Тесты

```bash
# Все тесты
bundle exec rspec

# Только модели
bundle exec rspec spec/models/

# Конкретный файл
bundle exec rspec spec/models/property_spec.rb

# С документацией
bundle exec rspec --format documentation

# Проверить, нет ли незакрытых транзакций после тестов
bundle exec rspec --format progress 2>&1 | tail -5
```

### Линтер

```bash
# Проверка
bundle exec rubocop

# Автоисправление безопасных нарушений
bundle exec rubocop -a

# Только новые файлы (diff от main)
bundle exec rubocop $(git diff --name-only main...HEAD | grep '\.rb$')
```

---

## Архитектурные заметки для AI-ассистентов

1. **JSONB-колонки** (`notification_settings`, `preferences`, `filters`, `metadata`) всегда возвращают Ruby Hash со **строковыми ключами**, не символами. Используйте `hash['key']`, не `hash[:key]`. При обработке из params — `transform_keys(&:to_s)`.

2. **Мягкое удаление** — `Property` и `User` имеют `deleted_at` с `default_scope { not_deleted }`. Для работы с удалёнными записями используйте `.unscoped`.

3. **Enum с `_prefix: true`** — `property.status_active?`, не `property.active?`. `user.role_admin?`, не `user.admin?` (хотя алиас `admin?` тоже есть в `user.rb`).

4. **ViewingSchedule** — в БД хранится `scheduled_at` (datetime). Виртуальные accessor'ы `preferred_date` и `preferred_time` в модели проксируют это поле.

5. **API контроллеры** — все наследуют от `Api::V1::BaseController`. Аутентификация через `authenticate_api_user!`, текущий пользователь — `current_api_user` (не `current_user`).

6. **CSP nonces** — активны для `script-src` и `style-src`. Все `<script>` и `<style>` блоки в шаблонах должны иметь атрибут `nonce="<%= content_security_policy_nonce %>"`. Inline `style="..."` атрибуты запрещены CSP — используйте Tailwind-классы.

7. **Rack::Attack** — требует работающего Redis. При недоступности Redis все контактные формы и API могут получать 429. Отключается через `Rack::Attack.enabled = false` или комментированием middleware.

8. **Health endpoints** — `/health/database`, `/health/redis`, `/health/sidekiq` доступны только с loopback и RFC-1918 адресов (127.x, 10.x, 172.16-31.x, 192.168.x). Внешние запросы получают 404.

---

*Последнее обновление: май 2026*
