# Quickstart — АН "Виктори"

> От нуля до работающего приложения за 5 минут.

---

## Требования

| Инструмент | Версия | Проверка |
|-----------|--------|----------|
| Ruby | 3.2.2 | `ruby --version` |
| Bundler | 2.x | `bundle --version` |
| PostgreSQL | 15+ | `psql --version` |

**Node.js и Yarn не нужны** — проект использует Importmap (JS-зависимости без сборщика).

---

## 1. Установка

```bash
# Клонировать репозиторий
git clone <url-репозитория>
cd victory
# Установить ruby
sudo apt update
sudo apt install build-essential rustup libssl-dev libyaml-dev zlib1g-dev libgmp-dev 
rustup default stable
curl -L mise.run | bash
mise settings ruby.compile=false
mise trust
mise install
# Установить гемы
bundle install
```

---

## 2. База данных

Приложение подключается к PostgreSQL через переменные окружения.
По умолчанию используется пользователь `postgres` на `localhost:5432`.

```bash
# Создать базы данных (development и test)
bin/rails db:create

# Применить миграции (13 штук)
bin/rails db:migrate

# Загрузить начальные данные (опционально)
bin/rails db:seed
```

Если PostgreSQL запущен с нестандартными параметрами, задайте переменные перед командами:

```bash
export DATABASE_USERNAME=мой_пользователь
export DATABASE_PASSWORD=мой_пароль
export DATABASE_HOST=localhost
bin/rails db:create db:migrate
```

Либо создайте файл `.env` и загружайте его через `dotenv` или вручную.

---

## 3. Запуск

```bash
bin/rails server
```

Приложение запускается на порту **5000** (задан в `config/puma.rb`):

```
http://localhost:5000
```

> В среде Replit порт проксируется автоматически. Не меняйте его без необходимости.

---

## 4. Основные страницы

| URL | Что откроет |
|-----|------------|
| `http://localhost:5000/` | Главная (landing page) |
| `http://localhost:5000/properties` | Каталог объектов |
| `http://localhost:5000/properties/new` | Создать объявление |
| `http://localhost:5000/valuations/new` | Онлайн-оценка недвижимости |
| `http://localhost:5000/dashboard` | Личный кабинет (заглушка) |

> **Важно:** аутентификация в данный момент отключена. `current_user` всегда возвращает `nil`,
> `user_signed_in?` — `false`. Защищённые разделы (dashboard, admin) доступны, но работают
> с ограничениями.

---

## 5. Консоль Rails

```bash
bin/rails console
```

Полезные команды в консоли:

```ruby
# Количество объектов в базе
Property.count
Property.published.count

# Создать тестовый объект
Property.create!(
  title: 'Квартира в центре',
  deal_type: :sale,
  status: :active,
  price: 8_500_000,
  area: 65,
  address: 'Москва, ул. Тверская, 1'
)

# Запустить оценку вручную
service = PropertyEvaluationService.new(property_id: 1, area: 60, district: 'Центр')
result = service.call

# Посмотреть маршруты
# (из терминала, не консоли)
# bin/rails routes | grep properties
```

---

## 6. Запуск тестов

```bash
# Все тесты
bundle exec rspec

# Только модели
bundle exec rspec spec/models

# С подробным выводом
bundle exec rspec --format documentation

# Один файл
bundle exec rspec spec/models/property_spec.rb
```

---

## 7. Линтинг

```bash
# Проверка кода
bundle exec rubocop

# Автоисправление безопасных нарушений
bundle exec rubocop -a
```

---

## 8. Полезные команды

```bash
# Просмотр всех маршрутов
bin/rails routes

# Статус миграций
bin/rails db:migrate:status

# Откат последней миграции
bin/rails db:rollback

# Сброс БД (drop + create + migrate + seed)
bin/rails db:reset

# Очистка временных файлов и кэша
bin/rails tmp:clear

# Компиляция Tailwind CSS вручную
bin/rails tailwindcss:build
```

---

## 9. Устранение типичных проблем

### "could not connect to server" при запуске

PostgreSQL не запущен или недоступен.

```bash
# macOS (Homebrew)
brew services start postgresql@15

# Ubuntu/Debian
sudo systemctl start postgresql

# Проверить подключение
psql -U postgres -h localhost -c "SELECT 1"
```

### "role does not exist"

```bash
# Создать роль с правами на создание БД
sudo -u postgres createuser -s $(whoami)
# или
sudo -u postgres psql -c "CREATE USER postgres WITH SUPERUSER PASSWORD '';"
```

### "Migrations are pending"

```bash
bin/rails db:migrate
```

### "Bundler version mismatch"

```bash
gem install bundler
bundle install
```

### "cannot load such file — pg"

Нужен системный адаптер PostgreSQL:

```bash
# macOS
brew install libpq
bundle config --local build.pg --with-pg-config=$(brew --prefix libpq)/bin/pg_config

# Ubuntu
sudo apt-get install libpq-dev
bundle install
```

---

## 10. Структура переменных окружения

Для локальной разработки достаточно задать только подключение к БД:

```env
DATABASE_HOST=localhost
DATABASE_PORT=5432
DATABASE_USERNAME=postgres
DATABASE_PASSWORD=
```

Остальные переменные имеют значения по умолчанию. Полный список — в [README.md](README.md#переменные-окружения).

---

## Что дальше?

- [README.md](README.md) — полная документация проекта
- [ROADMAP.md](ROADMAP.md) — текущее состояние и план развития
- `bin/rails routes` — таблица всех маршрутов
- `app/models/property.rb` — главная модель с документацией в комментариях
