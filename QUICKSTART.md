# 🚀 QUICKSTART GUIDE - АН "Виктори"

> Быстрый старт для разработчиков - от установки до первого запуска за 10 минут

---

## ⚡ Быстрый старт (TL;DR)

```bash
# 1. Клонирование и установка зависимостей
git clone <repository-url>
cd viktory_realty
bundle install
yarn install

# 2. Настройка окружения
cp .env.example .env
# Отредактируйте .env и укажите параметры БД

# 3. База данных
rails db:create
rails db:migrate
rails db:seed

# 4. Запуск
rails server

# Готово! Откройте http://localhost:3000
```

---

## 📋 Требования

Перед началом убедитесь, что установлены:

- ✅ **Ruby** 3.2.2+ (`ruby --version`)
- ✅ **Rails** 7.1.0+ (`rails --version`)
- ✅ **PostgreSQL** 15+ (`psql --version`)
- ✅ **Redis** 7.0+ (`redis-cli --version`)
- ✅ **Node.js** 18+ (`node --version`)
- ✅ **Yarn** (`yarn --version`)

### Установка зависимостей (если нужно)

#### macOS (Homebrew)
```bash
brew install ruby postgresql@15 redis node yarn imagemagick
brew services start postgresql@15
brew services start redis
```

#### Ubuntu/Debian
```bash
sudo apt-get update
sudo apt-get install ruby-full postgresql-15 redis-server nodejs npm imagemagick libvips
sudo npm install -g yarn
sudo systemctl start postgresql
sudo systemctl start redis
```

#### Windows
- Установите Ruby через [RubyInstaller](https://rubyinstaller.org/)
- PostgreSQL через [официальный установщик](https://www.postgresql.org/download/windows/)
- Redis через [WSL](https://redis.io/docs/getting-started/installation/install-redis-on-windows/) или Docker

---

## 🛠️ Пошаговая установка

### Шаг 1: Клонирование репозитория

```bash
git clone https://github.com/yourusername/viktory_realty.git
cd viktory_realty
```

### Шаг 2: Установка Ruby зависимостей

```bash
bundle install
```

Если возникают проблемы с установкой конкретных gem:
```bash
bundle update
bundle install --retry=3
```

### Шаг 3: Установка JavaScript зависимостей

```bash
yarn install
# или
npm install
```

### Шаг 4: Настройка переменных окружения

```bash
# Скопируйте пример файла
cp .env.example .env

# Отредактируйте .env
nano .env
# или
code .env
```

**Минимальная конфигурация для .env:**

```env
# Database
DATABASE_USERNAME=postgres
DATABASE_PASSWORD=your_postgres_password
DATABASE_HOST=localhost

# Redis
REDIS_URL=redis://localhost:6379/0

# Secret keys
SECRET_KEY_BASE=$(rails secret)
DEVISE_SECRET_KEY=$(rails secret)
```

Сгенерируйте секретные ключи:
```bash
rails secret
```

### Шаг 5: Создание базы данных

```bash
# Создать базы данных (development и test)
rails db:create

# Если ошибка "database already exists":
rails db:drop db:create
```

### Шаг 6: Запуск миграций

```bash
rails db:migrate
```

Проверьте статус миграций:
```bash
rails db:migrate:status
```

### Шаг 7: Загрузка тестовых данных

```bash
rails db:seed
```

Это создаст:
- ✅ 1 администратора
- ✅ 5 агентов
- ✅ 20 клиентов
- ✅ 6 типов недвижимости
- ✅ 100 объектов недвижимости
- ✅ 50 заявок
- ✅ Избранное, просмотры, отзывы

**Данные для входа (после seed):**
```
Администратор: admin@viktory-realty.ru / Password123!
Агент:         agent1@viktory-realty.ru / Password123!
```

---

## 🎬 Запуск приложения

### Вариант 1: Простой запуск

```bash
rails server
# или
rails s
```

Откройте браузер: **http://localhost:3000**

### Вариант 2: Запуск с Sidekiq (рекомендуется)

Откройте 2 терминала:

**Терминал 1 - Rails:**
```bash
rails server
```

**Терминал 2 - Sidekiq:**
```bash
bundle exec sidekiq
```

### Вариант 3: Запуск всех сервисов через Foreman

Создайте `Procfile.dev`:
```
web: rails server -p 3000
sidekiq: bundle exec sidekiq
```

Запустите:
```bash
gem install foreman
foreman start -f Procfile.dev
```

---

## 🔐 Первый вход

### 1. Откройте главную страницу
```
http://localhost:3000
```

### 2. Войдите как администратор
```
Email:    admin@viktory-realty.ru
Password: Password123!
```

### 3. Доступ к админ-панели
```
http://localhost:3000/admin
```

### 4. Личный кабинет
```
http://localhost:3000/dashboard
```

### 5. Каталог недвижимости
```
http://localhost:3000/properties
```

---

## 🧪 Тестирование

### Запуск всех тестов
```bash
bundle exec rspec
```

### С покрытием кода
```bash
COVERAGE=true bundle exec rspec
open coverage/index.html
```

### Проверка кода (Rubocop)
```bash
bundle exec rubocop
# С автоисправлением
bundle exec rubocop -A
```

### Security audit
```bash
bundle exec brakeman
bundle exec bundle-audit check --update
```

---

## 🔧 Полезные команды

### База данных

```bash
# Сброс и пересоздание БД
rails db:reset

# Откат последней миграции
rails db:rollback

# Откат N миграций
rails db:rollback STEP=3

# Статус миграций
rails db:migrate:status

# Консоль БД
rails dbconsole
# или
psql viktory_realty_development
```

### Rails консоль

```bash
# Открыть консоль
rails console
# или
rails c

# В консоли:
User.count
Property.published.count
admin = User.admins.first
```

### Очистка кэша

```bash
rails cache:clear
rails tmp:clear
```

### Assets

```bash
# Прекомпиляция assets
rails assets:precompile

# Очистка скомпилированных assets
rails assets:clobber
```

### Логи

```bash
# Просмотр логов в реальном времени
tail -f log/development.log

# Очистка логов
rake log:clear
```

---

## 🐛 Troubleshooting

### Проблема: "Could not connect to database"

**Решение:**
```bash
# Проверьте, запущен ли PostgreSQL
sudo systemctl status postgresql
# или
brew services list

# Проверьте .env файл
cat .env | grep DATABASE

# Попробуйте подключиться вручную
psql -U postgres -h localhost
```

### Проблема: "Redis connection failed"

**Решение:**
```bash
# Проверьте Redis
redis-cli ping
# Должен вернуть: PONG

# Запустите Redis
sudo systemctl start redis
# или
brew services start redis
```

### Проблема: "Bundler version mismatch"

**Решение:**
```bash
gem install bundler
bundle update --bundler
```

### Проблема: "Yarn install fails"

**Решение:**
```bash
# Очистите кэш
yarn cache clean
rm -rf node_modules
yarn install
```

### Проблема: "PG::ConnectionBad"

**Решение:**
```bash
# Создайте роль postgres (если нужно)
sudo -u postgres createuser -s $(whoami)

# Или создайте пользователя в psql
sudo -u postgres psql
CREATE USER your_username WITH PASSWORD 'your_password';
ALTER USER your_username CREATEDB;
\q
```

### Проблема: "LoadError: cannot load such file"

**Решение:**
```bash
# Переустановите зависимости
rm -rf vendor/bundle
bundle install
```

### Проблема: "Migrations are pending"

**Решение:**
```bash
rails db:migrate
# или для теста
rails db:migrate RAILS_ENV=test
```

---

## 📚 Дополнительные ресурсы

### Разработка

- **Letter Opener** (просмотр email): http://localhost:3000/letter_opener
- **Sidekiq UI**: http://localhost:3000/sidekiq
- **Flipper UI** (feature flags): http://localhost:3000/flipper
- **ActiveAdmin**: http://localhost:3000/admin

### API

- **API Endpoint**: http://localhost:3000/api/v1
- **Health check**: http://localhost:3000/health

### Документация

- [README.md](README.md) - Полная документация проекта
- [ROADMAP.md](../ruby/sonnet/ROADMAP.md) - План разработки
- [v2.md](../ruby/sonnet/v2.md) - Техническая спецификация

---

## 🎯 Следующие шаги после установки

### 1. Исследуйте приложение
- ✅ Откройте главную страницу
- ✅ Просмотрите каталог недвижимости
- ✅ Откройте карточку объекта
- ✅ Попробуйте фильтры и поиск
- ✅ Добавьте объект в избранное
- ✅ Используйте калькулятор ипотеки

### 2. Войдите в админ-панель
```
http://localhost:3000/admin
Login: admin@viktory-realty.ru
Password: Password123!
```

### 3. Протестируйте личный кабинет
- Зарегистрируйте нового пользователя
- Добавьте объекты в избранное
- Создайте заявку
- Сохраните поиск

### 4. Проверьте базовый функционал
- [ ] Регистрация нового пользователя
- [ ] Вход в систему
- [ ] Просмотр каталога
- [ ] Фильтрация и сортировка
- [ ] Просмотр карточки объекта
- [ ] Добавление в избранное
- [ ] Создание заявки
- [ ] Калькулятор ипотеки

---

## 💡 Полезные советы

### Для разработки

1. **Используйте автоперезагрузку**
   ```ruby
   # В Gemfile уже есть:
   gem 'hotwire-livereload'
   ```

2. **N+1 запросы** - используйте Bullet
   ```bash
   # Bullet автоматически активен в development
   # Проверяйте консоль на предупреждения
   ```

3. **Debugging**
   ```ruby
   # Используйте binding.pry в коде
   binding.pry
   
   # Или
   debugger
   ```

4. **Letter Opener** для email
   ```ruby
   # Все email открываются в браузере автоматически
   # Проверяйте: http://localhost:3000/letter_opener
   ```

### Для production

1. **Не забудьте:**
   - Изменить `SECRET_KEY_BASE`
   - Включить `FORCE_SSL=true`
   - Настроить SMTP для email
   - Добавить API ключи (Яндекс.Карты, reCAPTCHA)

2. **Перед деплоем:**
   ```bash
   rails assets:precompile
   rails db:migrate
   bundle exec brakeman
   bundle exec rubocop
   ```

---

## 📞 Нужна помощь?

- 📖 Читайте [README.md](README.md)
- 🗺️ Проверьте [ROADMAP.md](../ruby/sonnet/ROADMAP.md)
- 📋 Смотрите [v2.md](../ruby/sonnet/v2.md) для деталей
- 🐛 Создайте issue в GitHub

---

## ✅ Checklist готовности к разработке

- [ ] Ruby 3.2.2+ установлен
- [ ] Rails 7.1.0+ установлен
- [ ] PostgreSQL запущен
- [ ] Redis запущен
- [ ] Bundle install выполнен успешно
- [ ] Yarn install выполнен успешно
- [ ] .env файл создан и настроен
- [ ] База данных создана (db:create)
- [ ] Миграции выполнены (db:migrate)
- [ ] Seed данные загружены (db:seed)
- [ ] Сервер запускается без ошибок
- [ ] Главная страница открывается
- [ ] Админ-панель доступна
- [ ] Можете войти как admin

---

## 🎉 Поздравляем!

Вы успешно развернули **АН "Виктори" Digital Platform**!

Проект включает:
- ✅ 100 объектов недвижимости
- ✅ 25+ пользователей
- ✅ AI-рекомендации
- ✅ Поиск и фильтрация
- ✅ Личный кабинет
- ✅ Калькулятор ипотеки
- ✅ Интеграция карт
- ✅ Responsive design

**Начинайте разработку! 🚀**

---

**Версия:** 2.0.0  
**Последнее обновление:** 2024  
**Статус:** ✅ MVP Core Ready