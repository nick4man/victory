# 🚀 Руководство по запуску приложения

Краткая инструкция для быстрого старта платформы **АН "Виктори"**.

---

## ✅ Предварительные требования

Убедитесь, что у вас установлено:

- **Ruby** 3.2.2 или выше
- **Rails** 7.1+
- **PostgreSQL** 15+
- **Redis** 7.0+
- **Node.js** 18+ & npm
- **Bundler** 2.4+

---

## 📦 Установка зависимостей

### 1. Клонирование репозитория

```bash
cd /home/q/site/project
cd viktory_realty
```

### 2. Установка Ruby gems

```bash
bundle install
```

### 3. Установка JavaScript зависимостей

```bash
npm install
# или
yarn install
```

---

## ⚙️ Настройка окружения

### 1. Создание .env файла

```bash
cp .env.example .env
```

### 2. Редактирование .env

Минимальные настройки для development:

```bash
# Application
APP_NAME="АН Виктори"
APP_URL=http://localhost:3000
APP_HOST=localhost
APP_PORT=3000

# Database
DATABASE_USERNAME=postgres
DATABASE_PASSWORD=
DATABASE_HOST=localhost
DATABASE_PORT=5432

# Redis
REDIS_URL=redis://localhost:6379/0

# Secret Keys (сгенерируйте новые!)
SECRET_KEY_BASE=$(rails secret)
DEVISE_SECRET_KEY=$(rails secret)

# Email (для development используется Letter Opener)
DEFAULT_FROM_EMAIL=noreply@viktory-realty.ru
CONTACT_EMAIL=info@viktory-realty.ru
CONTACT_PHONE=+7 (999) 123-45-67
```

### 3. Генерация secret keys

```bash
# В Rails console
rails secret
# Скопируйте результат в .env как SECRET_KEY_BASE

rails secret
# Скопируйте результат в .env как DEVISE_SECRET_KEY
```

---

## 🗄️ Настройка базы данных

### 1. Проверка работы PostgreSQL

```bash
# Проверка статуса
sudo systemctl status postgresql

# Если не запущен
sudo systemctl start postgresql
```

### 2. Создание базы данных

```bash
rails db:create
```

### 3. Запуск миграций

```bash
rails db:migrate
```

### 4. Загрузка начальных данных

```bash
rails db:seed
```

Это создаст:
- **Admin пользователя:** admin@viktory-realty.ru / password123
- **Manager:** manager@viktory-realty.ru / password123
- **5 тестовых пользователей**
- **50 объектов недвижимости**
- **30 заявок**
- **Избранное, отзывы, просмотры**

---

## 🔴 Запуск Redis

```bash
# Проверка статуса
sudo systemctl status redis

# Запуск если не работает
sudo systemctl start redis

# Проверка подключения
redis-cli ping
# Ответ: PONG
```

---

## 🚀 Запуск приложения

### Вариант 1: Простой запуск (только веб-сервер)

```bash
rails server
# или
rails s
```

Приложение будет доступно по адресу: **http://localhost:3000**

### Вариант 2: Полный запуск (с фоновыми задачами)

Откройте **3 терминала**:

**Терминал 1 - Rails сервер:**
```bash
rails server
```

**Терминал 2 - Sidekiq (фоновые задачи):**
```bash
bundle exec sidekiq
```

**Терминал 3 - Tailwind CSS (если нужна hot-reload):**
```bash
rails tailwindcss:watch
```

### Вариант 3: Использование Foreman (рекомендуется)

Создайте файл `Procfile.dev`:

```yaml
web: bin/rails server -p 3000
worker: bundle exec sidekiq
css: bin/rails tailwindcss:watch
```

Затем запустите:

```bash
gem install foreman
foreman start -f Procfile.dev
```

---

## 🧪 Проверка работоспособности

### 1. Открыть приложение

```bash
# В браузере
http://localhost:3000
```

### 2. Войти как администратор

```
Email: admin@viktory-realty.ru
Password: password123
```

### 3. Проверить основные разделы

- ✅ Главная страница: http://localhost:3000
- ✅ Каталог: http://localhost:3000/properties
- ✅ Личный кабинет: http://localhost:3000/dashboard
- ✅ Онлайн оценка: http://localhost:3000/valuations/new
- ✅ Sidekiq UI: http://localhost:3000/sidekiq (admin only)

### 4. Отправить тестовое письмо

В development письма открываются в браузере через **Letter Opener**:

1. Отправьте заявку на сайте
2. Письмо автоматически откроется в новой вкладке

---

## 🎨 Работа с Assets

### Компиляция CSS (Tailwind)

```bash
# Development с автообновлением
rails tailwindcss:watch

# Production сборка
rails tailwindcss:build
```

### Компиляция всех assets

```bash
rails assets:precompile
```

---

## 🔧 Работа с Rails Console

```bash
# Открыть Rails console
rails console
# или
rails c

# Примеры команд:
User.count
Property.last
Inquiry.where(status: 'pending').count
```

---

## 📊 Проверка фоновых задач

### Sidekiq Web UI

```
http://localhost:3000/sidekiq
```

Логин с admin аккаунтом.

### Проверка очередей

```bash
# В Rails console
Sidekiq::Queue.all.map { |q| [q.name, q.size] }

# Очистка очередей (осторожно!)
Sidekiq::Queue.new('default').clear
```

---

## 🧪 Запуск тестов

```bash
# Все тесты
bundle exec rspec

# Конкретный файл
bundle exec rspec spec/models/user_spec.rb

# С покрытием
COVERAGE=true bundle exec rspec
```

---

## 📝 Работа с БД

### Сброс базы данных

```bash
# ОСТОРОЖНО! Удалит все данные
rails db:reset
# Это выполнит: drop + create + migrate + seed
```

### Откат миграций

```bash
# Откатить последнюю миграцию
rails db:rollback

# Откатить N миграций
rails db:rollback STEP=3
```

### Проверка статуса миграций

```bash
rails db:migrate:status
```

---

## 🐛 Troubleshooting

### Проблема: База данных не создается

```bash
# Проверка PostgreSQL
sudo -u postgres psql
\l  # Список баз данных
\q  # Выход

# Создание пользователя вручную
sudo -u postgres createuser -s $(whoami)
```

### Проблема: Redis не подключается

```bash
# Проверка Redis
redis-cli ping

# Если не отвечает
sudo systemctl restart redis
```

### Проблема: Bundler not found

```bash
gem install bundler
bundle install
```

### Проблема: JavaScript не работает

```bash
# Переустановка node_modules
rm -rf node_modules
npm install

# Или с Yarn
rm -rf node_modules yarn.lock
yarn install
```

### Проблема: Assets не компилируются

```bash
# Очистка и пересборка
rails assets:clobber
rails assets:precompile
```

### Проблема: Порт 3000 занят

```bash
# Найти процесс
lsof -i :3000

# Убить процесс
kill -9 <PID>

# Или запустить на другом порту
rails s -p 3001
```

---

## 📂 Структура проекта

```
viktory_realty/
├── app/
│   ├── controllers/       # Контроллеры
│   ├── models/           # Модели
│   ├── views/            # Представления (ERB)
│   ├── javascript/       # Stimulus контроллеры
│   ├── assets/           # Images, fonts
│   ├── helpers/          # View helpers
│   ├── mailers/          # Email mailers
│   ├── jobs/             # Background jobs
│   └── services/         # Service objects
├── config/
│   ├── initializers/     # Инициализаторы
│   ├── locales/          # I18n переводы
│   ├── environments/     # Environment configs
│   ├── routes.rb         # Маршруты
│   ├── database.yml      # БД конфиг
│   ├── cable.yml         # ActionCable
│   └── puma.rb           # Веб-сервер
├── db/
│   ├── migrate/          # Миграции
│   └── seeds.rb          # Начальные данные
├── spec/                 # RSpec тесты
├── public/               # Статика
├── .env                  # Переменные окружения
└── Gemfile               # Ruby зависимости
```

---

## 🔑 Важные URL'ы (Development)

| Раздел | URL |
|--------|-----|
| Главная | http://localhost:3000 |
| Каталог | http://localhost:3000/properties |
| Оценка | http://localhost:3000/valuations/new |
| Вход | http://localhost:3000/users/sign_in |
| Регистрация | http://localhost:3000/users/sign_up |
| Личный кабинет | http://localhost:3000/dashboard |
| Sidekiq | http://localhost:3000/sidekiq |
| Letter Opener | http://localhost:3000/letter_opener |

---

## 📧 Работа с Email (Development)

В development используется **Letter Opener** - письма открываются в браузере.

### Просмотр отправленных писем

```
http://localhost:3000/letter_opener
```

### Тестовая отправка письма

```ruby
# В Rails console
PropertyValuationMailer.valuation_completed(PropertyValuation.last).deliver_now
```

---

## 🎯 Следующие шаги

1. ✅ Приложение запущено
2. 📝 Изучите код в `app/controllers` и `app/models`
3. 🎨 Кастомизируйте стили в Tailwind
4. 📧 Настройте SMTP для production email
5. 🧪 Напишите тесты
6. 🚀 Разверните на production (см. DEPLOYMENT.md)

---

## 📞 Полезные команды

```bash
# Информация о маршрутах
rails routes

# Список задач Rake
rails -T

# Обновление гемов
bundle update

# Консоль БД
rails dbconsole

# Логи в реальном времени
tail -f log/development.log

# Очистка логов
rails log:clear

# Очистка кеша
rails cache:clear
```

---

## 🎉 Готово!

Приложение готово к разработке. Удачи! 🚀

Если возникли проблемы - смотрите раздел **Troubleshooting** или проверьте логи:
- `log/development.log`
- `log/sidekiq.log`

---

**© 2024 АН "Виктори" Development Team**

