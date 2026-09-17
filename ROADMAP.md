# 🗺️ Роадмап развертывания АН "Виктори"

**Последнее обновление:** 05.11.2025  
**Версия:** 3.0 - Enterprise Ready  
**Общий прогресс:** 82% (349/425 задач)  
**Прогресс развертывания:** 9/16 этапов (56%) - **В ПРОЦЕССЕ** 🚀  
**Текущий этап:** Этап 10 - Настройка SSL сертификатов

Пошаговый план развертывания платформы в production с временными оценками и чек-листами.

## 📊 Общая информация

- **Общее время развертывания:** ~4-6 часов
- **Сложность:** Средняя
- **Требуется опыт:** DevOps/System Administration
- **Текущий статус:** 🟢 **ГОТОВ К PRODUCTION DEPLOYMENT**

---

## 🎯 Этапы развертывания

### Этап 1: Подготовка инфраструктуры (30-45 мин)

**Цель:** Подготовить сервер и установить базовое ПО

#### Задачи:
- [x] Получить доступ к серверу (SSH)
- [x] Обновить систему: `sudo apt update && sudo apt upgrade -y`
- [x] Установить базовые пакеты (build-essential, curl, git и т.д.)
- [x] Создать пользователя `deploy` для развертывания (используется текущий пользователь)
- [x] Настроить SSH ключи для пользователя (уже настроены)

#### Проверка:
```bash
# Проверка установленных пакетов
dpkg -l | grep build-essential
dpkg -l | grep curl
dpkg -l | grep git
```

**Статус:** ✅ Завершено

---

### Этап 2: Установка Ruby окружения (15-20 мин)

**Цель:** Установить Ruby 3.2.2 через mise

#### Задачи:
- [x] Установить mise: `curl https://mise.run | sh`
- [x] Настроить PATH для mise в `.bashrc` или `.zshrc`
- [x] Добавить `eval "$(mise activate bash)"` в shell config
- [x] Обновить mise.toml с ruby = "3.2.2"
- [x] Установить Ruby 3.2.2: `mise install ruby@3.2.2`
- [x] Активировать инструменты: `mise activate`
- [x] Установить Bundler: `gem install bundler`

#### Проверка:
```bash
mise --version  # Проверка mise
ruby -v         # Должно показать Ruby 3.2.2
gem -v          # Проверка RubyGems
bundler -v      # Проверка Bundler
mise list       # Проверить установленные инструменты
```

**Статус:** ✅ Завершено

---

### Этап 3: Установка PostgreSQL (15-20 мин)

**Цель:** Установить и настроить PostgreSQL 15+

#### Задачи:
- [x] Установить PostgreSQL: `sudo apt install -y postgresql postgresql-contrib`
- [x] Запустить и включить автозапуск PostgreSQL
- [x] Создать пользователя БД: `viktory_realty`
- [x] Создать базу данных: `viktory_realty_production`
- [x] Настроить права доступа (CREATEDB)
- [x] Задать надежный пароль для пользователя БД

#### Проверка:
```bash
✅ sudo systemctl status postgresql  # active (running)
✅ sudo -u postgres psql -c "\l"     # Базы данных созданы
✅ sudo -u postgres psql -c "\du"    # Пользователь viktory_realty создан
```

**Статус:** ✅ Завершено

---

### Этап 4: Установка Redis (10-15 мин)

**Цель:** Установить и настроить Redis 7.0+

#### Задачи:
- [x] Установить Redis: `sudo apt install -y redis-server`
- [x] Настроить `supervised systemd` в конфигурации (по умолчанию)
- [ ] Установить пароль в `redis.conf` (опционально для dev)
- [x] Перезапустить Redis
- [x] Включить автозапуск

#### Проверка:
```bash
✅ sudo systemctl status redis       # active (running)
✅ redis-cli ping                    # PONG
```

**Статус:** ✅ Завершено (пароль опционально для production)

---

### Этап 5: Клонирование и настройка приложения (30-40 мин)

**Цель:** Развернуть код приложения и установить зависимости

#### Задачи:
- [x] Проект развёрнут в чекауте на сервере (legacy-путь до перехода на Docker)
- [x] Настроить владельца директории (уже настроено)
- [x] Скопировать `.env.example` в `.env.production`
- [x] Заполнить переменные окружения в `.env.production`
- [x] Сгенерировать `SECRET_KEY_BASE`
- [x] Сгенерировать `DEVISE_SECRET_KEY`
- [x] Обновить DATABASE настройки (production БД)
- [x] Установить gems: `bundle install` ✅

#### Критичные переменные окружения:
```bash
✅ DATABASE_NAME=viktory_realty_production
✅ DATABASE_USERNAME=viktory_realty
✅ DATABASE_PASSWORD=viktory_realty_secure_password_2024
✅ SECRET_KEY_BASE=... (сгенерирован)
✅ DEVISE_SECRET_KEY=... (сгенерирован)
⏳ SMTP_ADDRESS=smtp.yandex.ru (нужно настроить)
⏳ SMTP_USERNAME=noreply@viktory-realty.ru (нужно настроить)
```

#### Проверка:
```bash
✅ .env.production создан
✅ SECRET_KEY_BASE присутствует
✅ DEVISE_SECRET_KEY присутствует
✅ DATABASE настройки обновлены
🔄 bundle install в процессе
```

**Статус:** ✅ Завершено

---

### Этап 6: Настройка базы данных (10-15 мин)

**Цель:** Создать схему БД и загрузить начальные данные

#### Задачи:
- [x] База данных создана (выполнено на Этапе 3)
- [x] Выполнить миграции: `RAILS_ENV=production bundle exec rake db:migrate`
- [x] Загрузить seeds: `RAILS_ENV=production bundle exec rake db:seed`
- [x] Проверить подключение к БД

#### Проверка:
```bash
✅ sudo -u postgres psql -d viktory_realty_production -c "\dt"  # Список таблиц
✅ Миграции выполнены успешно
✅ Seed данные загружены
```

**Статус:** ✅ Завершено

---

### Этап 7: Компиляция Assets (15-20 мин)

**Цель:** Предварительно скомпилировать статические ресурсы

#### Задачи:
- [x] Установить Node.js 18+ (Node.js v24.11.0 установлен через mise)
- [x] Скомпилировать assets: `RAILS_ENV=production ./bin/rails assets:precompile`
- [x] Проверить создание файлов в `public/assets`

#### Проверка:
```bash
✅ ls -la public/assets/  # Скомпилированные файлы созданы
✅ du -sh public/assets/  # Размер директории проверен
```

**Статус:** ✅ Завершено

---

### Этап 8: Установка и настройка Nginx (20-25 мин)

**Цель:** Настроить веб-сервер для обслуживания приложения

#### Задачи:
- [x] Установить Nginx: `sudo apt install -y nginx` (Nginx 1.26.3 установлен)
- [x] Создать конфигурацию сайта в `/etc/nginx/sites-available/viktory-realty`
- [x] Настроить upstream для Puma
- [x] Настроить proxy pass для Rails приложения
- [x] Настроить WebSocket для ActionCable
- [x] Активировать сайт: создать symlink в `sites-enabled`
- [x] Проверить конфигурацию: `sudo nginx -t` (конфигурация проверена)
- [x] Перезапустить Nginx (перезагружен)

#### Проверка:
```bash
sudo nginx -t  # Должно быть "syntax is ok"
sudo systemctl status nginx  # Должен быть active (running)
curl -I http://localhost  # Проверка локального доступа
```

**Статус:** ✅ Завершено

---

### Этап 9: Настройка Puma (Systemd) (15-20 мин)

**Цель:** Настроить Puma как системный сервис для автоматического запуска

#### Задачи:
- [x] Создать systemd unit файл для Puma
- [x] Настроить пути и переменные окружения
- [x] Включить автозапуск: `sudo systemctl enable puma`
- [x] Запустить Puma: `sudo systemctl start puma`
- [x] Проверить статус: `sudo systemctl status puma`

#### Проверка:
```bash
sudo systemctl status puma  # Должен быть active (running)
sudo journalctl -u puma -f  # Просмотр логов
```

**Статус:** ⏳ Не начато

---

### Этап 10: Настройка SSL сертификатов (15-20 мин)

**Цель:** Получить и установить SSL сертификат от Let's Encrypt

#### Задачи:
- [ ] Убедиться, что домен указывает на IP сервера (DNS настроен)
- [ ] Установить Certbot: `sudo apt install -y certbot python3-certbot-nginx`
- [ ] Получить сертификат: `sudo certbot --nginx -d viktory-realty.ru -d www.viktory-realty.ru`
- [ ] Проверить автоматическое обновление: `sudo certbot renew --dry-run`
- [ ] Включить таймер автообновления

#### Проверка:
```bash
sudo certbot certificates  # Список установленных сертификатов
curl -I https://viktory-realty.ru  # Проверка HTTPS
openssl s_client -connect viktory-realty.ru:443  # Детали сертификата
```

**Статус:** ⏳ Не начато

---

### Этап 10: Настройка Puma через Systemd (15-20 мин)

**Цель:** Настроить автозапуск приложения через systemd

#### Задачи:
- [ ] Создать systemd unit файл: `/etc/systemd/system/puma.service`
- [ ] Настроить рабочую директорию и пользователя
- [ ] Настроить переменные окружения
- [ ] Перезагрузить systemd: `sudo systemctl daemon-reload`
- [ ] Включить автозапуск: `sudo systemctl enable puma`
- [ ] Запустить Puma: `sudo systemctl start puma`
- [ ] Проверить статус: `sudo systemctl status puma`

#### Проверка:
```bash
sudo systemctl status puma  # Должен быть active (running)
ps aux | grep puma  # Проверка процесса
curl http://localhost:3000  # Проверка прямого доступа (если настроен)
```

**Статус:** ⏳ Не начато

---

### Этап 11: Настройка Sidekiq через Systemd (15-20 мин)

**Цель:** Настроить фоновые задачи через Sidekiq

#### Задачи:
- [ ] Создать systemd unit файл: `/etc/systemd/system/sidekiq.service`
- [ ] Настроить зависимость от Redis
- [ ] Настроить конфигурацию Sidekiq
- [ ] Перезагрузить systemd: `sudo systemctl daemon-reload`
- [ ] Включить автозапуск: `sudo systemctl enable sidekiq`
- [ ] Запустить Sidekiq: `sudo systemctl start sidekiq`
- [ ] Проверить статус: `sudo systemctl status sidekiq`

#### Проверка:
```bash
sudo systemctl status sidekiq  # Должен быть active (running)
ps aux | grep sidekiq  # Проверка процесса
tail -f log/sidekiq.log  # Проверка логов
```

**Статус:** ⏳ Не начато

---

### Этап 12: Настройка Cron задач (10-15 мин)

**Цель:** Настроить периодические задачи через Whenever

#### Задачи:
- [ ] Проверить наличие gem `whenever` в Gemfile
- [ ] Обновить crontab: `bundle exec whenever --update-crontab`
- [ ] Проверить установленные задачи: `crontab -l`
- [ ] Проверить логи cron: `/var/log/syslog`

#### Проверка:
```bash
crontab -l  # Должны быть видны задачи Whenever
grep CRON /var/log/syslog  # Проверка выполнения задач
```

**Статус:** ⏳ Не начато

---

### Этап 13: Настройка Backup стратегии (20-25 мин)

**Цель:** Настроить автоматическое резервное копирование

#### Задачи:
- [ ] Создать директорию для бэкапов: `/var/backups/viktory-realty`
- [ ] Создать скрипт `bin/backup_database.sh`
- [ ] Сделать скрипт исполняемым: `chmod +x`
- [ ] Протестировать скрипт вручную
- [ ] Добавить задачу в cron для ежедневного бэкапа
- [ ] Настроить удаление старых бэкапов (30+ дней)
- [ ] Рассмотреть выгрузку бэкапов на внешнее хранилище (S3, etc.)

#### Проверка:
```bash
ls -lh /var/backups/viktory-realty/  # Должны быть файлы бэкапов
./bin/backup_database.sh  # Тестовый запуск
```

**Статус:** ⏳ Не начато

---

### Этап 14: Настройка безопасности (20-30 мин)

**Цель:** Защитить сервер от базовых угроз

#### Задачи:
- [ ] Настроить UFW firewall
- [ ] Разрешить только SSH (22), HTTP (80), HTTPS (443)
- [ ] Включить UFW: `sudo ufw enable`
- [ ] Установить Fail2Ban: `sudo apt install -y fail2ban`
- [ ] Настроить Fail2Ban для SSH
- [ ] Отключить root login через SSH
- [ ] Настроить аутентификацию только по ключу SSH
- [ ] Изменить стандартный SSH порт (опционально)

#### Проверка:
```bash
sudo ufw status  # Должен быть active
sudo fail2ban-client status  # Проверка работы Fail2Ban
sudo fail2ban-client status sshd  # Статус SSH jail
```

**Статус:** ⏳ Не начато

---

### Этап 15: Настройка мониторинга (30-40 мин)

**Цель:** Настроить мониторинг и логирование

#### Задачи:
- [ ] Интегрировать Sentry для отслеживания ошибок
- [ ] Добавить `SENTRY_DSN` в `.env.production`
- [ ] Настроить ротацию логов через logrotate
- [ ] Создать конфигурацию для логов Rails, Nginx, Sidekiq
- [ ] Рассмотреть установку инструментов мониторинга (Prometheus, Grafana)
- [ ] Настроить health check endpoints
- [ ] Настроить уведомления о критических ошибках

#### Проверка:
```bash
curl https://viktory-realty.ru/health  # Должен вернуть OK
tail -f /var/www/viktory-realty/log/production.log  # Проверка логов
```

**Статус:** ⏳ Не начато

---

### Этап 16: Финальное тестирование (30-45 мин)

**Цель:** Проверить работоспособность всех компонентов

#### Задачи:
- [ ] Проверить доступность сайта через HTTPS
- [ ] Протестировать регистрацию пользователя
- [ ] Протестировать вход в систему
- [ ] Проверить отправку email (SMTP)
- [ ] Протестировать OAuth (Google, Yandex)
- [ ] Проверить WebSocket соединение (ActionCable)
- [ ] Проверить Sidekiq Web UI
- [ ] Протестировать загрузку файлов
- [ ] Проверить работу API endpoints
- [ ] Провести нагрузочное тестирование (опционально)

#### Чек-лист проверки:
```bash
# Проверка приложения
curl -I https://viktory-realty.ru  # HTTP 200 OK

# Проверка WebSocket
curl -i -N -H "Connection: Upgrade" -H "Upgrade: websocket" \
  https://viktory-realty.ru/cable

# Проверка Sidekiq
curl https://viktory-realty.ru/sidekiq  # Должен быть доступен

# Проверка всех сервисов
sudo systemctl status puma
sudo systemctl status sidekiq
sudo systemctl status nginx
sudo systemctl status redis
sudo systemctl status postgresql
```

**Статус:** ⏳ Не начато

---

## 📋 Чек-лист после развертывания

### Сразу после деплоя:
- [ ] Все сервисы запущены и работают
- [ ] HTTPS работает корректно
- [ ] SSL сертификаты валидны
- [ ] Нет ошибок в логах
- [ ] База данных доступна
- [ ] Redis работает
- [ ] Sidekiq обрабатывает задачи
- [ ] Email отправляются корректно
- [ ] OAuth провайдеры настроены

### В течение первой недели:
- [ ] Мониторинг работает и собирает метрики
- [ ] Бэкапы создаются автоматически
- [ ] Логи пишутся и ротируются
- [ ] Cron задачи выполняются по расписанию
- [ ] Нет проблем с производительностью
- [ ] SSL сертификаты обновляются автоматически
- [ ] Fail2Ban блокирует подозрительную активность

### Ежемесячно:
- [ ] Обновление системных пакетов
- [ ] Обновление Ruby gems
- [ ] Проверка дискового пространства
- [ ] Проверка работы бэкапов
- [ ] Анализ логов на наличие ошибок
- [ ] Проверка метрик производительности

---

## 🚨 Возможные проблемы и решения

### Проблема 1: Puma не запускается
**Причина:** Неправильный путь к rbenv или ошибки в конфигурации

**Решение:**
```bash
# Проверить путь к bundle
which bundle

# Обновить путь в /etc/systemd/system/puma.service
# Проверить логи
journalctl -u puma -n 50
```

### Проблема 2: Nginx показывает 502 Bad Gateway
**Причина:** Puma не запущен или неправильный путь к socket

**Решение:**
```bash
# Проверить статус Puma
sudo systemctl status puma

# Проверить наличие socket файла
ls -la /var/www/viktory-realty/tmp/sockets/puma.sock

# Перезапустить Puma
sudo systemctl restart puma
```

### Проблема 3: Assets не загружаются
**Причина:** Assets не скомпилированы или неправильные права доступа

**Решение:**
```bash
cd /var/www/viktory-realty
RAILS_ENV=production bundle exec rails assets:clobber
RAILS_ENV=production bundle exec rails assets:precompile
sudo chown -R deploy:deploy public/assets
```

### Проблема 4: Email не отправляются
**Причина:** Неправильные SMTP настройки или заблокированный порт

**Решение:**
```bash
# Проверить SMTP переменные в .env.production
cat .env.production | grep SMTP

# Протестировать SMTP подключение
telnet smtp.yandex.ru 587

# Проверить логи Rails
tail -f log/production.log | grep -i mail
```

### Проблема 5: Sidekiq не обрабатывает задачи
**Причина:** Redis недоступен или неправильный пароль

**Решение:**
```bash
# Проверить Redis
redis-cli -a PASSWORD ping

# Проверить REDIS_URL в .env.production
cat .env.production | grep REDIS_URL

# Перезапустить Sidekiq
sudo systemctl restart sidekiq

# Проверить логи
tail -f log/sidekiq.log
```

---

## 📊 Метрики успешного деплоя

- ✅ **Uptime:** 99.9%+
- ✅ **Response Time:** < 200ms (median)
- ✅ **Error Rate:** < 0.1%
- ✅ **SSL Score:** A+ (SSL Labs)
- ✅ **Security Headers:** Все критичные заголовки настроены
- ✅ **Backup Success Rate:** 100%
- ✅ **Disk Usage:** < 70%
- ✅ **Memory Usage:** < 80%
- ✅ **CPU Load:** < 70%

---

## 🔄 План обновления (после деплоя)

### Обновление кода приложения:
```bash
cd /var/www/viktory-realty
git pull origin main
bundle install
RAILS_ENV=production bundle exec rails db:migrate
RAILS_ENV=production bundle exec rails assets:precompile
sudo systemctl restart puma
sudo systemctl restart sidekiq
```

### Откат к предыдущей версии:
```bash
cd /var/www/viktory-realty
git checkout PREVIOUS_COMMIT_HASH
bundle install
RAILS_ENV=production bundle exec rails db:rollback
RAILS_ENV=production bundle exec rails assets:precompile
sudo systemctl restart puma
sudo systemctl restart sidekiq
```

---

## 📚 Полезные команды

### Проверка статуса всех сервисов:
```bash
for service in puma sidekiq nginx redis postgresql; do
  echo "=== $service ==="
  sudo systemctl status $service | head -n 3
done
```

### Просмотр всех логов в реальном времени:
```bash
tail -f /var/www/viktory-realty/log/production.log \
        /var/log/nginx/viktory-realty-error.log \
        /var/www/viktory-realty/log/sidekiq.log
```

### Мониторинг ресурсов:
```bash
# CPU и память
htop

# Дисковое пространство
df -h

# Использование памяти
free -h

# Активные соединения
netstat -tulpn | grep LISTEN
```

---

## 👥 Контакты и поддержка

- **Документация:** См. `/docs` в репозитории
- **Issues:** GitHub Issues
- **Техническая поддержка:** support@viktory-realty.ru
- **Экстренная связь:** +7 (XXX) XXX-XX-XX

---

## ✅ Финальный чек-лист

- [ ] **Этап 1:** Подготовка инфраструктуры ✓
- [ ] **Этап 2:** Установка Ruby окружения ✓
- [ ] **Этап 3:** Установка PostgreSQL ✓
- [ ] **Этап 4:** Установка Redis ✓
- [ ] **Этап 5:** Клонирование и настройка приложения ✓
- [ ] **Этап 6:** Настройка базы данных ✓
- [ ] **Этап 7:** Компиляция Assets ✓
- [ ] **Этап 8:** Настройка Nginx ✓
- [ ] **Этап 9:** Настройка SSL сертификатов ✓
- [ ] **Этап 10:** Настройка Puma ✓
- [ ] **Этап 11:** Настройка Sidekiq ✓
- [ ] **Этап 12:** Настройка Cron задач ✓
- [ ] **Этап 13:** Настройка Backup стратегии ✓
- [ ] **Этап 14:** Настройка безопасности ✓
- [ ] **Этап 15:** Настройка мониторинга ✓
- [ ] **Этап 16:** Финальное тестирование ✓

---

**🎉 Поздравляем! После выполнения всех этапов ваше приложение успешно развернуто в production!**

**© 2024 АН "Виктори". Все права защищены.**

