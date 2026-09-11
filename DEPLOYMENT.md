# 🚀 Руководство по развертыванию

Инструкции по развертыванию платформы **АН "Виктори"** в production окружении.

## 📋 Содержание

- [Требования](#требования)
- [Подготовка сервера](#подготовка-сервера)
- [Установка зависимостей](#установка-зависимостей)
- [Настройка базы данных](#настройка-базы-данных)
- [Настройка Redis](#настройка-redis)
- [Настройка приложения](#настройка-приложения)
- [Настройка Nginx](#настройка-nginx)
- [Настройка SSL](#настройка-ssl)
- [Настройка Puma](#настройка-puma-systemd)
- [Настройка Sidekiq](#настройка-sidekiq-systemd)
- [Настройка Cron задач](#настройка-cron-задач)
- [Backup стратегия](#backup-стратегия)
- [Мониторинг и логи](#мониторинг-и-логи)
- [Безопасность](#безопасность)
- [Проверка работоспособности](#проверка-работоспособности)
- [Troubleshooting](#troubleshooting)

---

## Требования

### Минимальные требования к серверу

- **OS:** Ubuntu 22.04 LTS или выше
- **CPU:** 2+ cores (рекомендуется 4+ cores)
- **RAM:** 8 GB+ (минимум 4 GB)
- **Disk:** 50 GB+ SSD (рекомендуется 100 GB)
- **Ruby:** 3.2.2
- **PostgreSQL:** 15+
- **Redis:** 7.0+
- **Node.js:** 18+ (для Asset Pipeline)
- **Nginx:** latest stable

---

## Подготовка сервера

### 1. Обновление системы

```bash
sudo apt update && sudo apt upgrade -y
```

### 2. Установка базовых пакетов

```bash
sudo apt install -y curl git build-essential libssl-dev libreadline-dev \
  zlib1g-dev libpq-dev libsqlite3-dev libyaml-dev libxml2-dev libxslt1-dev \
  libcurl4-openssl-dev libffi-dev imagemagick libmagickwand-dev nodejs npm
```

### 3. Установка mise (менеджер версий)

```bash
# Установка mise
curl https://mise.run | sh

# Добавить mise в PATH (для текущей сессии)
export PATH="$HOME/.local/bin:$PATH"

# Добавить в ~/.bashrc или ~/.zshrc
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
echo 'eval "$(mise activate bash)"' >> ~/.bashrc
source ~/.bashrc

# Проверка установки
mise --version
```

### 4. Установка Ruby через mise

```bash
# Перейти в директорию проекта
cd "$(git rev-parse --show-toplevel)"   # корень чекаута

# Установить Ruby 3.2.2 (mise автоматически прочитает mise.toml)
mise install ruby@3.2.2

# Активировать инструменты
mise activate

# Проверка версии
ruby -v  # Должно показать ruby 3.2.2
mise list  # Проверить установленные инструменты
```

### 5. Установка Bundler

```bash
# Установка Bundler через mise или gem
gem install bundler

# Или через mise (если указан в mise.toml)
mise install bundler
```

---

## Установка зависимостей

### PostgreSQL

```bash
# Установка PostgreSQL
sudo apt install -y postgresql postgresql-contrib

# Запуск PostgreSQL
sudo systemctl start postgresql
sudo systemctl enable postgresql

# Создание пользователя и базы данных
sudo -u postgres psql
```

В psql:
```sql
CREATE USER viktory_realty WITH PASSWORD 'your_secure_password';
CREATE DATABASE viktory_realty_production OWNER viktory_realty;
ALTER USER viktory_realty CREATEDB;
\q
```

### Redis

```bash
# Установка Redis
sudo apt install -y redis-server

# Настройка Redis
sudo nano /etc/redis/redis.conf
# Измените: supervised no -> supervised systemd
# Добавьте пароль: requirepass your_redis_password

# Перезапуск Redis
sudo systemctl restart redis
sudo systemctl enable redis

# Проверка
redis-cli ping
```

---

## Настройка приложения

### 1. Клонирование репозитория

```bash
cd /var/www
sudo git clone https://github.com/your-org/viktory-realty.git
sudo chown -R deploy:deploy viktory-realty
cd viktory-realty
```

### 2. Установка gems

```bash
bundle config set --local deployment 'true'
bundle config set --local without 'development test'
bundle install
```

### 3. Настройка переменных окружения

```bash
cp .env.example .env.production
nano .env.production
```

Заполните все необходимые переменные:

```bash
# Application
APP_NAME="АН Виктори"
APP_URL=https://viktory-realty.ru
APP_DOMAIN=viktory-realty.ru
RAILS_ENV=production

# Database
DATABASE_URL=postgresql://viktory_realty:password@localhost:5432/viktory_realty_production

# Redis
REDIS_URL=redis://:your_redis_password@localhost:6379/0

# Secret Keys
SECRET_KEY_BASE=$(rails secret)
DEVISE_SECRET_KEY=$(rails secret)

# Email (SMTP)
SMTP_ADDRESS=smtp.yandex.ru
SMTP_PORT=587
SMTP_DOMAIN=viktory-realty.ru
SMTP_USERNAME=noreply@viktory-realty.ru
SMTP_PASSWORD=your_smtp_password

# OAuth
GOOGLE_CLIENT_ID=your_google_client_id
GOOGLE_CLIENT_SECRET=your_google_client_secret
YANDEX_CLIENT_ID=your_yandex_client_id
YANDEX_CLIENT_SECRET=your_yandex_client_secret

# Monitoring
SENTRY_DSN=your_sentry_dsn
```

### 4. Настройка базы данных

```bash
RAILS_ENV=production bundle exec rails db:create
RAILS_ENV=production bundle exec rails db:migrate
RAILS_ENV=production bundle exec rails db:seed
```

### 5. Компиляция assets

```bash
RAILS_ENV=production bundle exec rails assets:precompile
```

---

## Настройка Nginx

### 1. Установка Nginx

```bash
sudo apt install -y nginx
```

### 2. Конфигурация сайта

```bash
sudo nano /etc/nginx/sites-available/viktory-realty
```

```nginx
upstream puma {
  server unix:///var/www/viktory-realty/tmp/sockets/puma.sock;
}

server {
  listen 80;
  listen [::]:80;
  server_name viktory-realty.ru www.viktory-realty.ru;
  
  return 301 https://$server_name$request_uri;
}

server {
  listen 443 ssl http2;
  listen [::]:443 ssl http2;
  server_name viktory-realty.ru www.viktory-realty.ru;
  
  root /var/www/viktory-realty/public;
  
  # SSL certificates
  ssl_certificate /etc/letsencrypt/live/viktory-realty.ru/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/viktory-realty.ru/privkey.pem;
  
  # SSL configuration
  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_ciphers HIGH:!aNULL:!MD5;
  ssl_prefer_server_ciphers on;
  
  # Security headers
  add_header X-Frame-Options "SAMEORIGIN" always;
  add_header X-Content-Type-Options "nosniff" always;
  add_header X-XSS-Protection "1; mode=block" always;
  add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
  
  # Logs
  access_log /var/log/nginx/viktory-realty-access.log;
  error_log /var/log/nginx/viktory-realty-error.log;
  
  # File size limits
  client_max_body_size 20M;
  
  # Compression
  gzip on;
  gzip_vary on;
  gzip_min_length 1024;
  gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript image/svg+xml;
  
  # Static assets
  location ^~ /assets/ {
    gzip_static on;
    expires max;
    add_header Cache-Control public;
  }
  
  # Uploads
  location ^~ /uploads/ {
    expires max;
    add_header Cache-Control public;
  }
  
  # Root
  location / {
    try_files $uri @puma;
  }
  
  # Puma upstream
  location @puma {
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header Host $http_host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_redirect off;
    proxy_pass http://puma;
  }
  
  # ActionCable
  location /cable {
    proxy_pass http://puma;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header Host $http_host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-Proto https;
    proxy_redirect off;
  }
  
  # Health check
  location /health {
    access_log off;
    return 200 "OK\n";
    add_header Content-Type text/plain;
  }
  
  error_page 500 502 503 504 /500.html;
  error_page 404 /404.html;
  error_page 422 /422.html;
}
```

### 3. Активация конфигурации

```bash
sudo ln -s /etc/nginx/sites-available/viktory-realty /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl restart nginx
```

---

## Настройка SSL (Let's Encrypt)

```bash
# Установка Certbot
sudo apt install -y certbot python3-certbot-nginx

# Получение сертификата
sudo certbot --nginx -d viktory-realty.ru -d www.viktory-realty.ru

# Автоматическое обновление
sudo systemctl enable certbot.timer
sudo systemctl start certbot.timer
```

---

## Настройка Puma (Systemd)

```bash
sudo nano /etc/systemd/system/puma.service
```

```ini
[Unit]
Description=Puma HTTP Server for Viktory Realty
After=network.target

[Service]
Type=simple
User=deploy
WorkingDirectory=/var/www/viktory-realty
Environment=RAILS_ENV=production
Environment=RAILS_LOG_TO_STDOUT=true
ExecStart=/home/deploy/.local/bin/mise exec bundle exec puma -C config/puma.rb
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable puma
sudo systemctl start puma
sudo systemctl status puma
```

---

## Настройка Sidekiq (Systemd)

```bash
sudo nano /etc/systemd/system/sidekiq.service
```

```ini
[Unit]
Description=Sidekiq Background Worker for Viktory Realty
After=network.target redis.target

[Service]
Type=simple
User=deploy
WorkingDirectory=/var/www/viktory-realty
Environment=RAILS_ENV=production
Environment=RAILS_LOG_TO_STDOUT=true
ExecStart=/home/deploy/.local/bin/mise exec bundle exec sidekiq -C config/sidekiq.yml
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable sidekiq
sudo systemctl start sidekiq
sudo systemctl status sidekiq
```

---

## Настройка Cron задач

```bash
# Установка Whenever
cd /var/www/viktory-realty
bundle exec whenever --update-crontab

# Проверка установленных задач
crontab -l
```

---

## Backup стратегия

### 1. Создание скрипта backup

```bash
nano /var/www/viktory-realty/bin/backup_database.sh
```

```bash
#!/bin/bash
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_DIR="/var/backups/viktory-realty"
DB_NAME="viktory_realty_production"
DB_USER="viktory_realty"

mkdir -p $BACKUP_DIR

# Database backup
pg_dump -U $DB_USER $DB_NAME | gzip > $BACKUP_DIR/db_$TIMESTAMP.sql.gz

# Uploads backup
tar -czf $BACKUP_DIR/uploads_$TIMESTAMP.tar.gz /var/www/viktory-realty/public/uploads

# Cleanup old backups (keep last 30 days)
find $BACKUP_DIR -name "*.gz" -mtime +30 -delete

echo "Backup completed: $TIMESTAMP"
```

```bash
chmod +x /var/www/viktory-realty/bin/backup_database.sh
```

---

## Мониторинг и логи

### Просмотр логов

```bash
# Rails logs
tail -f /var/www/viktory-realty/log/production.log

# Nginx logs
tail -f /var/log/nginx/viktory-realty-access.log
tail -f /var/log/nginx/viktory-realty-error.log

# Sidekiq logs
tail -f /var/www/viktory-realty/log/sidekiq.log

# System logs
journalctl -u puma -f
journalctl -u sidekiq -f
```

---

## 🔐 Безопасность

### Firewall (UFW)

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow ssh
sudo ufw allow http
sudo ufw allow https
sudo ufw enable
```

### Fail2Ban

```bash
sudo apt install -y fail2ban
sudo systemctl enable fail2ban
sudo systemctl start fail2ban
```

---

## 📊 Проверка работоспособности

```bash
# Проверка приложения
curl -I https://viktory-realty.ru

# Проверка WebSocket
curl -i -N -H "Connection: Upgrade" -H "Upgrade: websocket" \
  -H "Host: viktory-realty.ru" -H "Origin: https://viktory-realty.ru" \
  https://viktory-realty.ru/cable

# Проверка Sidekiq Web UI
curl https://viktory-realty.ru/sidekiq
```

---

## 🆘 Troubleshooting

### Перезапуск всех сервисов

```bash
sudo systemctl restart puma
sudo systemctl restart sidekiq
sudo systemctl restart nginx
sudo systemctl restart redis
sudo systemctl restart postgresql
```

### Очистка кеша

```bash
cd /var/www/viktory-realty
RAILS_ENV=production bundle exec rails cache:clear
```

### Пересборка assets

```bash
cd /var/www/viktory-realty
RAILS_ENV=production bundle exec rails assets:clobber
RAILS_ENV=production bundle exec rails assets:precompile
```

---

## 📊 Чек-лист после deployment

### ✅ Сразу после развертывания:
- [ ] Все сервисы запущены (puma, sidekiq, nginx, redis, postgresql)
- [ ] HTTPS работает корректно (SSL сертификат валиден)
- [ ] Сайт открывается через браузер
- [ ] Нет ошибок в логах
- [ ] База данных содержит seed данные
- [ ] Redis доступен и работает
- [ ] Sidekiq обрабатывает задачи
- [ ] Email отправляются (проверить SMTP)
- [ ] OAuth провайдеры настроены (Google, Yandex)
- [ ] WebSocket соединение работает (чат)
- [ ] Файлы загружаются корректно
- [ ] API endpoints отвечают

### ✅ В течение первой недели:
- [ ] Мониторинг собирает метрики
- [ ] Бэкапы создаются автоматически
- [ ] Логи пишутся и ротируются
- [ ] Cron задачи выполняются
- [ ] SSL обновляется автоматически
- [ ] Fail2Ban блокирует атаки
- [ ] Производительность стабильна
- [ ] Нет memory leaks
- [ ] Дисковое пространство контролируется

### ✅ Ежемесячно:
- [ ] Обновление системных пакетов
- [ ] Обновление Ruby gems
- [ ] Проверка дискового пространства
- [ ] Тест восстановления из backup
- [ ] Анализ логов на ошибки
- [ ] Проверка метрик производительности
- [ ] Security audit
- [ ] Обновление документации

---

## 🎯 Полезные команды для администрирования

### Управление сервисами:
```bash
# Перезапуск всех сервисов
sudo systemctl restart puma sidekiq nginx redis postgresql

# Проверка статуса
sudo systemctl status puma sidekiq nginx redis postgresql

# Просмотр логов
journalctl -u puma -f
journalctl -u sidekiq -f
```

### Rails команды:
```bash
# Вход в Rails console
RAILS_ENV=production bundle exec rails console

# Очистка кеша
RAILS_ENV=production bundle exec rails cache:clear

# Выполнение миграции
RAILS_ENV=production bundle exec rails db:migrate

# Rollback миграции
RAILS_ENV=production bundle exec rails db:rollback

# Пересборка assets
RAILS_ENV=production bundle exec rails assets:clobber
RAILS_ENV=production bundle exec rails assets:precompile
```

### Sidekiq команды:
```bash
# Просмотр очередей
bundle exec sidekiq-cli stats

# Очистка failed jobs
RAILS_ENV=production bundle exec rake sidekiq:clear_failed

# Restart workers
sudo systemctl restart sidekiq
```

### Database команды:
```bash
# Backup базы данных
pg_dump -U viktory_realty viktory_realty_production | gzip > backup_$(date +%Y%m%d).sql.gz

# Восстановление из backup
gunzip < backup_20241105.sql.gz | psql -U viktory_realty viktory_realty_production

# Вход в PostgreSQL
sudo -u postgres psql -d viktory_realty_production

# Проверка размера БД
sudo -u postgres psql -c "SELECT pg_size_pretty(pg_database_size('viktory_realty_production'));"
```

---

## 📈 Мониторинг производительности

### Системные метрики:
```bash
# CPU и память
htop
top

# Дисковое пространство
df -h
du -sh /var/www/viktory-realty/*

# Использование памяти
free -h

# Network connections
netstat -tulpn | grep LISTEN
ss -tulpn | grep LISTEN

# Процессы Ruby
ps aux | grep ruby
ps aux | grep puma
ps aux | grep sidekiq
```

### Application метрики:
```bash
# Размер логов
du -sh /var/www/viktory-realty/log/*

# Последние ошибки
tail -100 /var/www/viktory-realty/log/production.log | grep ERROR

# Sidekiq очереди
RAILS_ENV=production bundle exec rails runner "puts Sidekiq::Stats.new.inspect"

# Активные соединения к БД
sudo -u postgres psql -c "SELECT count(*) FROM pg_stat_activity WHERE datname='viktory_realty_production';"
```

---

## 🔍 Диагностика проблем

### Проблема: Высокая нагрузка на CPU
```bash
# Найти процесс, потребляющий CPU
top
htop

# Проверить slow queries в PostgreSQL
sudo -u postgres psql -d viktory_realty_production -c "SELECT * FROM pg_stat_activity WHERE state = 'active';"

# Профилирование Rails приложения
RAILS_ENV=production bundle exec rails runner "require 'ruby-prof'; RubyProf.start; # your code; result = RubyProf.stop; printer = RubyProf::FlatPrinter.new(result); printer.print(STDOUT)"
```

### Проблема: Медленные запросы
```bash
# Включить логирование slow queries в PostgreSQL
sudo nano /etc/postgresql/15/main/postgresql.conf
# Добавить: log_min_duration_statement = 1000

# Просмотр slow queries
tail -f /var/log/postgresql/postgresql-15-main.log | grep "duration"
```

### Проблема: Memory leak
```bash
# Мониторинг памяти Puma
ps aux | grep puma | awk '{print $6}'

# Автоматический restart при высоком использовании памяти (добавить в puma.rb)
# before_fork do
#   require 'puma_worker_killer'
#   PumaWorkerKiller.enable_rolling_restart
# end
```

---

## 🚀 Обновление приложения (Zero-downtime)

```bash
#!/bin/bash
# Скрипт для обновления приложения без простоя

cd /var/www/viktory-realty

# 1. Получить последние изменения
git fetch origin
git checkout main
git pull origin main

# 2. Установить зависимости
bundle install --deployment --without development test

# 3. Выполнить миграции
RAILS_ENV=production bundle exec rails db:migrate

# 4. Скомпилировать assets
RAILS_ENV=production bundle exec rails assets:precompile

# 5. Обновить cron задачи
bundle exec whenever --update-crontab

# 6. Restart приложения (zero-downtime)
# Puma поддерживает phased restart
sudo systemctl reload puma

# 7. Restart Sidekiq
sudo systemctl restart sidekiq

# 8. Очистка старых assets
RAILS_ENV=production bundle exec rails assets:clean

echo "✅ Deployment completed successfully!"
```

---

## 📞 Поддержка

**Документация проекта:**
- `README.md` - Общая информация
- `QUICKSTART.md` - Быстрый старт
- `DEPLOYMENT.md` - Этот файл
- `ROADMAP.md` - План развертывания
- `TESTING_GUIDE.md` - Руководство по тестированию

**Контакты:**
- Техническая поддержка: support@viktory-realty.ru
- GitHub Issues: [ссылка на репозиторий]
- Документация: [ссылка на wiki]

---

## 📚 Дополнительные ресурсы

- [Ruby on Rails Guides](https://guides.rubyonrails.org/)
- [Puma Web Server](https://puma.io/)
- [Sidekiq Best Practices](https://github.com/mperham/sidekiq/wiki/Best-Practices)
- [PostgreSQL Documentation](https://www.postgresql.org/docs/)
- [Nginx Documentation](https://nginx.org/en/docs/)
- [Let's Encrypt Documentation](https://letsencrypt.org/docs/)

---

**🎉 Успешного развертывания!**

**Версия документа:** 3.0  
**Последнее обновление:** 05.11.2025  
**Статус:** ✅ Production-Ready

**© 2024-2025 АН "Виктори". Все права защищены.**
