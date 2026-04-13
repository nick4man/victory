#!/usr/bin/env bash
# =============================================================================
#  АН "Виктори" — скрипт развёртывания на чистом Debian 11/12
#  Использование:
#    sudo bash setup.sh                        # интерактивный режим
#    sudo DOMAIN=viktory-realty.ru \
#         REPO_URL=https://github.com/org/victory.git \
#         bash setup.sh                        # переменные через env
# =============================================================================
set -euo pipefail

# ─── Цвета ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'

log()   { echo -e "${GREEN}[✓]${RESET} $*"; }
info()  { echo -e "${BLUE}[→]${RESET} $*"; }
warn()  { echo -e "${YELLOW}[!]${RESET} $*"; }
error() { echo -e "${RED}[✗]${RESET} $*" >&2; exit 1; }
header(){ echo -e "\n${BOLD}${BLUE}══════════════════════════════════════════${RESET}"; \
          echo -e "${BOLD}  $*${RESET}"; \
          echo -e "${BOLD}${BLUE}══════════════════════════════════════════${RESET}"; }

# ─── Проверка root ────────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && error "Запустите скрипт от root: sudo bash $0"

# ─── Версии ───────────────────────────────────────────────────────────────────
RUBY_VERSION="3.3.6"
BUNDLER_VERSION="2.5.23"
NODE_VERSION="20"
PG_VERSION="16"

# ─── Конфигурация (интерактивный ввод или переменные окружения) ───────────────
header "Конфигурация развёртывания"

ask() {
  local var=$1 prompt=$2 default=$3
  if [[ -z "${!var:-}" ]]; then
    read -rp "$(echo -e "${YELLOW}${prompt}${RESET} [${default}]: ")" input
    export "$var"="${input:-$default}"
  else
    info "$prompt: ${!var}"
  fi
}

ask DOMAIN        "Домен (без https://)"          "viktory-realty.ru"
ask APP_USER      "Системный пользователь"         "deploy"
ask APP_DIR       "Каталог приложения"              "/var/www/victory"
ask REPO_URL      "URL Git-репозитория"             "https://github.com/nick4man/victory.git"
ask REPO_BRANCH   "Ветка"                           "main"
ask DB_NAME       "Имя базы данных"                 "viktory_realty_production"
ask DB_USER       "Пользователь БД"                 "viktory"
ask DB_PASSWORD   "Пароль БД"                       "$(openssl rand -hex 16)"
ask SECRET_KEY    "Rails secret_key_base"           "$(openssl rand -hex 64)"
ask ADMIN_EMAIL   "Email администратора"            "admin@${DOMAIN}"

# SMTP (опционально)
ask SMTP_ADDRESS  "SMTP-сервер (Enter = пропустить)" ""
if [[ -n "$SMTP_ADDRESS" ]]; then
  ask SMTP_PORT     "SMTP-порт"      "587"
  ask SMTP_USERNAME "SMTP логин"     ""
  ask SMTP_PASSWORD "SMTP пароль"    ""
fi

APP_URL="https://${DOMAIN}"
APP_PORT=3000  # Puma слушает 3000, nginx проксирует

# ─── Системные зависимости ───────────────────────────────────────────────────
header "Системные пакеты"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
  curl wget gnupg2 ca-certificates lsb-release \
  build-essential git libssl-dev libreadline-dev zlib1g-dev \
  libxml2-dev libxslt1-dev libffi-dev libyaml-dev \
  libgdbm-dev libncurses5-dev libpq-dev \
  imagemagick libmagickwand-dev \
  nginx certbot python3-certbot-nginx \
  logrotate cron \
  2>/dev/null
log "Системные пакеты установлены"

# ─── PostgreSQL ───────────────────────────────────────────────────────────────
header "PostgreSQL ${PG_VERSION}"

if ! command -v psql &>/dev/null; then
  install -d /usr/share/postgresql-common/pgdg
  curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
    | gpg --dearmor -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.gpg
  echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.gpg] \
    https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
    > /etc/apt/sources.list.d/pgdg.list
  apt-get update -qq
  apt-get install -y -qq "postgresql-${PG_VERSION}" "postgresql-client-${PG_VERSION}" 2>/dev/null
fi

systemctl enable postgresql
systemctl start postgresql
log "PostgreSQL запущен"

# Создание базы и пользователя
info "Создание БД и пользователя"
sudo -u postgres psql -c "CREATE USER ${DB_USER} WITH PASSWORD '${DB_PASSWORD}';" 2>/dev/null || \
  sudo -u postgres psql -c "ALTER USER ${DB_USER} WITH PASSWORD '${DB_PASSWORD}';"
sudo -u postgres psql -c "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};" 2>/dev/null || \
  warn "База ${DB_NAME} уже существует"
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};"
log "База данных готова"

# ─── Redis ────────────────────────────────────────────────────────────────────
header "Redis"

if ! command -v redis-server &>/dev/null; then
  curl -fsSL https://packages.redis.io/gpg | gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] \
    https://packages.redis.io/deb $(lsb_release -cs) main" \
    > /etc/apt/sources.list.d/redis.list
  apt-get update -qq
  apt-get install -y -qq redis-server 2>/dev/null
fi

# Настройка Redis
sed -i 's/^# maxmemory .*/maxmemory 256mb/'   /etc/redis/redis.conf 2>/dev/null || true
sed -i 's/^# maxmemory-policy .*/maxmemory-policy allkeys-lru/' /etc/redis/redis.conf 2>/dev/null || true
sed -i 's/^supervised no/supervised systemd/' /etc/redis/redis.conf 2>/dev/null || true

systemctl enable redis-server
systemctl start redis-server
log "Redis запущен"

# ─── Node.js ──────────────────────────────────────────────────────────────────
header "Node.js ${NODE_VERSION}"

if ! command -v node &>/dev/null || [[ "$(node --version | cut -d. -f1 | tr -d v)" -lt "$NODE_VERSION" ]]; then
  curl -fsSL "https://deb.nodesource.com/setup_${NODE_VERSION}.x" | bash - >/dev/null 2>&1
  apt-get install -y -qq nodejs 2>/dev/null
fi
log "Node.js $(node --version) установлен"

# ─── Пользователь deploy ─────────────────────────────────────────────────────
header "Пользователь приложения"

if ! id "${APP_USER}" &>/dev/null; then
  useradd -m -s /bin/bash -d "/home/${APP_USER}" "${APP_USER}"
  log "Пользователь ${APP_USER} создан"
else
  log "Пользователь ${APP_USER} уже существует"
fi

# Добавляем в группу www-data для nginx
usermod -aG www-data "${APP_USER}" 2>/dev/null || true

# ─── rbenv + Ruby ─────────────────────────────────────────────────────────────
header "Ruby ${RUBY_VERSION} (rbenv)"

RBENV_ROOT="/home/${APP_USER}/.rbenv"

if [[ ! -d "$RBENV_ROOT" ]]; then
  sudo -u "${APP_USER}" git clone https://github.com/rbenv/rbenv.git "$RBENV_ROOT"
  sudo -u "${APP_USER}" git clone https://github.com/rbenv/ruby-build.git "${RBENV_ROOT}/plugins/ruby-build"
fi

# Добавляем rbenv в PATH для пользователя
RBENV_INIT=$(cat <<'PROFILE'
export RBENV_ROOT="$HOME/.rbenv"
export PATH="$RBENV_ROOT/bin:$RBENV_ROOT/shims:$PATH"
eval "$(rbenv init -)"
PROFILE
)

if ! grep -q 'rbenv init' "/home/${APP_USER}/.bashrc" 2>/dev/null; then
  echo "$RBENV_INIT" >> "/home/${APP_USER}/.bashrc"
fi
if ! grep -q 'rbenv init' "/home/${APP_USER}/.profile" 2>/dev/null; then
  echo "$RBENV_INIT" >> "/home/${APP_USER}/.profile"
fi

# Функция запуска команд от deploy с rbenv
run_as_deploy() {
  sudo -u "${APP_USER}" bash -c \
    "export RBENV_ROOT=${RBENV_ROOT}; export PATH=${RBENV_ROOT}/bin:${RBENV_ROOT}/shims:\$PATH; eval \"\$(${RBENV_ROOT}/bin/rbenv init -)\" 2>/dev/null; $*"
}

# Установка Ruby (может занять 5-15 минут)
info "Установка Ruby ${RUBY_VERSION} — это займёт несколько минут..."
run_as_deploy "rbenv install -s ${RUBY_VERSION}"
run_as_deploy "rbenv global ${RUBY_VERSION}"
run_as_deploy "gem install bundler -v ${BUNDLER_VERSION} --no-document 2>/dev/null"
log "Ruby $(run_as_deploy 'ruby --version') готов"

# ─── Каталог приложения ───────────────────────────────────────────────────────
header "Развёртывание кода"

mkdir -p "${APP_DIR}" \
         "${APP_DIR}/shared/config" \
         "${APP_DIR}/shared/log" \
         "${APP_DIR}/shared/tmp/pids" \
         "${APP_DIR}/shared/tmp/sockets" \
         "${APP_DIR}/shared/public/uploads"

chown -R "${APP_USER}:${APP_USER}" "${APP_DIR}"

# Клонирование репозитория
if [[ ! -d "${APP_DIR}/current/.git" ]]; then
  sudo -u "${APP_USER}" git clone "${REPO_URL}" "${APP_DIR}/current"
  sudo -u "${APP_USER}" bash -c "cd ${APP_DIR}/current && git checkout ${REPO_BRANCH}"
else
  info "Репозиторий уже клонирован — обновляем"
  sudo -u "${APP_USER}" bash -c "cd ${APP_DIR}/current && git fetch origin && git reset --hard origin/${REPO_BRANCH}"
fi
log "Код загружен"

# ─── .env (переменные окружения) ─────────────────────────────────────────────
header "Файл .env"

ENV_FILE="${APP_DIR}/current/.env"

cat > "${ENV_FILE}" <<ENV
# Сгенерировано автоматически скриптом setup.sh
# $(date)

RAILS_ENV=production
RAILS_LOG_TO_STDOUT=true
RAILS_SERVE_STATIC_FILES=true

# Сервер
PORT=${APP_PORT}
APP_HOST=${DOMAIN}
APP_URL=${APP_URL}
APP_DOMAIN=${DOMAIN}

# Секрет
SECRET_KEY_BASE=${SECRET_KEY}

# База данных
DATABASE_NAME=${DB_NAME}
DATABASE_USERNAME=${DB_USER}
DATABASE_PASSWORD=${DB_PASSWORD}
DATABASE_HOST=localhost
DATABASE_PORT=5432

# Redis / Sidekiq
REDIS_URL=redis://localhost:6379/0

# Action Cable
ACTION_CABLE_URL=wss://${DOMAIN}/cable

# Почта
ADMIN_EMAIL=${ADMIN_EMAIL}
MANAGER_EMAILS=${ADMIN_EMAIL}
CONTACT_PHONE=+7 (XXX) XXX-XX-XX

# SMTP
SMTP_ADDRESS=${SMTP_ADDRESS:-smtp.yandex.ru}
SMTP_PORT=${SMTP_PORT:-587}
SMTP_DOMAIN=${DOMAIN}
SMTP_USERNAME=${SMTP_USERNAME:-}
SMTP_PASSWORD=${SMTP_PASSWORD:-}
SMTP_AUTHENTICATION=plain
SMTP_ENABLE_STARTTLS_AUTO=true

# Прочее
RAILS_MAX_THREADS=5
WEB_CONCURRENCY=2
SESSION_TIMEOUT=1800
ENV

chmod 600 "${ENV_FILE}"
chown "${APP_USER}:${APP_USER}" "${ENV_FILE}"
log ".env создан: ${ENV_FILE}"

# ─── bundle install ───────────────────────────────────────────────────────────
header "Bundle install"

run_as_deploy "cd ${APP_DIR}/current && \
  bundle config set --local deployment 'true' && \
  bundle config set --local without 'development test' && \
  bundle install --jobs $(nproc) --retry 3 2>&1"
log "Gems установлены"

# ─── Assets и DB ─────────────────────────────────────────────────────────────
header "Миграции и ассеты"

run_as_deploy "cd ${APP_DIR}/current && \
  set -a && source .env && set +a && \
  bundle exec rails db:migrate RAILS_ENV=production 2>&1"
log "Миграции применены"

run_as_deploy "cd ${APP_DIR}/current && \
  set -a && source .env && set +a && \
  bundle exec rails assets:precompile RAILS_ENV=production 2>&1"
log "Ассеты скомпилированы"

# Tailwind CSS
run_as_deploy "cd ${APP_DIR}/current && \
  set -a && source .env && set +a && \
  bundle exec rails tailwindcss:build RAILS_ENV=production 2>&1" || \
  warn "Tailwind build не завершён — проверьте вручную"

# ─── Tmpfs/pid директории ────────────────────────────────────────────────────
mkdir -p "${APP_DIR}/current/tmp/pids" \
         "${APP_DIR}/current/tmp/sockets" \
         "${APP_DIR}/current/log"
chown -R "${APP_USER}:${APP_USER}" \
         "${APP_DIR}/current/tmp" \
         "${APP_DIR}/current/log"

# ─── Systemd: Puma ───────────────────────────────────────────────────────────
header "Systemd: puma"

cat > /etc/systemd/system/victory-puma.service <<SYSTEMD
[Unit]
Description=АН Виктори — Puma HTTP Server
After=network.target postgresql.service redis-server.service
Wants=postgresql.service redis-server.service

[Service]
Type=simple
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${APP_DIR}/current

EnvironmentFile=${APP_DIR}/current/.env
Environment=RBENV_ROOT=${RBENV_ROOT}
Environment=PATH=${RBENV_ROOT}/shims:${RBENV_ROOT}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin

ExecStart=${RBENV_ROOT}/shims/bundle exec puma \
  -C config/puma.rb \
  --environment production

ExecReload=/bin/kill -TSTP \$MAINPID
ExecStop=/bin/kill -s QUIT \$MAINPID

TimeoutStartSec=90
TimeoutStopSec=30
Restart=on-failure
RestartSec=5

KillMode=mixed

StandardOutput=append:${APP_DIR}/current/log/puma.stdout.log
StandardError=append:${APP_DIR}/current/log/puma.stderr.log

[Install]
WantedBy=multi-user.target
SYSTEMD

log "victory-puma.service создан"

# ─── Systemd: Sidekiq ────────────────────────────────────────────────────────
header "Systemd: sidekiq"

cat > /etc/systemd/system/victory-sidekiq.service <<SYSTEMD
[Unit]
Description=АН Виктори — Sidekiq Background Jobs
After=network.target postgresql.service redis-server.service victory-puma.service
Wants=postgresql.service redis-server.service

[Service]
Type=simple
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${APP_DIR}/current

EnvironmentFile=${APP_DIR}/current/.env
Environment=RBENV_ROOT=${RBENV_ROOT}
Environment=PATH=${RBENV_ROOT}/shims:${RBENV_ROOT}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin

ExecStart=${RBENV_ROOT}/shims/bundle exec sidekiq \
  -C config/sidekiq.yml \
  -e production

ExecReload=/bin/kill -TSTP \$MAINPID

TimeoutStartSec=60
TimeoutStopSec=30
Restart=on-failure
RestartSec=10

KillMode=mixed

StandardOutput=append:${APP_DIR}/current/log/sidekiq.log
StandardError=append:${APP_DIR}/current/log/sidekiq.log

[Install]
WantedBy=multi-user.target
SYSTEMD

log "victory-sidekiq.service создан"

# ─── Nginx ────────────────────────────────────────────────────────────────────
header "Nginx"

cat > /etc/nginx/sites-available/victory <<NGINX
upstream victory_puma {
  server unix:${APP_DIR}/current/tmp/sockets/puma.sock fail_timeout=0;
}

# HTTP → HTTPS редирект
server {
  listen 80;
  listen [::]:80;
  server_name ${DOMAIN} www.${DOMAIN};

  # ACME challenge для Let's Encrypt
  location /.well-known/acme-challenge/ {
    root /var/www/certbot;
  }

  location / {
    return 301 https://\$host\$request_uri;
  }
}

# HTTPS
server {
  listen 443 ssl http2;
  listen [::]:443 ssl http2;
  server_name ${DOMAIN} www.${DOMAIN};

  # SSL — заполнится certbot-ом
  # ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
  # ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
  # include             /etc/letsencrypt/options-ssl-nginx.conf;
  # ssl_dhparam         /etc/letsencrypt/ssl-dhparams.pem;

  root ${APP_DIR}/current/public;
  access_log /var/log/nginx/victory.access.log;
  error_log  /var/log/nginx/victory.error.log;

  client_max_body_size 50m;

  # Статика и ассеты (кешируем агрессивно)
  location ^~ /assets/ {
    gzip_static on;
    expires     max;
    add_header  Cache-Control public;
    add_header  Last-Modified "";
    add_header  ETag "";
  }

  location ^~ /packs/ {
    gzip_static on;
    expires     max;
    add_header  Cache-Control public;
  }

  # Загруженные файлы (Active Storage)
  location ^~ /rails/active_storage/ {
    proxy_pass         http://victory_puma;
    proxy_set_header   Host \$host;
    proxy_set_header   X-Real-IP \$remote_addr;
    proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header   X-Forwarded-Proto \$scheme;
    proxy_read_timeout 300;
  }

  # Action Cable WebSocket
  location /cable {
    proxy_pass         http://victory_puma;
    proxy_http_version 1.1;
    proxy_set_header   Upgrade \$http_upgrade;
    proxy_set_header   Connection "upgrade";
    proxy_set_header   Host \$host;
    proxy_set_header   X-Real-IP \$remote_addr;
    proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header   X-Forwarded-Proto \$scheme;
    proxy_read_timeout 3600;
    proxy_send_timeout 3600;
  }

  # Health check (без логов)
  location /health {
    proxy_pass       http://victory_puma;
    access_log       off;
    proxy_set_header Host \$host;
  }

  # Sidekiq Web UI (только для localhost или по IP-whitelist)
  location /sidekiq {
    allow 127.0.0.1;
    # allow YOUR_OFFICE_IP;
    deny  all;
    proxy_pass       http://victory_puma;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
  }

  # Всё остальное — в Rails
  location / {
    try_files \$uri/index.html \$uri @puma;
  }

  location @puma {
    proxy_pass         http://victory_puma;
    proxy_set_header   Host \$host;
    proxy_set_header   X-Real-IP \$remote_addr;
    proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header   X-Forwarded-Proto \$scheme;
    proxy_set_header   X-Forwarded-Host \$host;
    proxy_redirect     off;
    proxy_read_timeout 60;
    proxy_connect_timeout 60;
    proxy_send_timeout 60;

    # Буферизация для защиты от slow clients
    proxy_buffering    on;
    proxy_buffer_size  16k;
    proxy_buffers      4 32k;
  }

  # Скрываем файлы конфигурации
  location ~ /\. { deny all; }
  location = /favicon.ico { access_log off; log_not_found off; }
  location = /robots.txt  { access_log off; log_not_found off; }
}
NGINX

# Активируем сайт
ln -sf /etc/nginx/sites-available/victory /etc/nginx/sites-enabled/victory
rm -f /etc/nginx/sites-enabled/default

nginx -t && systemctl reload nginx
log "Nginx настроен"

# ─── Запуск сервисов ──────────────────────────────────────────────────────────
header "Запуск сервисов"

systemctl daemon-reload
systemctl enable victory-puma victory-sidekiq

systemctl start victory-puma
systemctl start victory-sidekiq

sleep 3

systemctl is-active --quiet victory-puma   && log "Puma запущен"   || warn "Puma не запустился — проверьте: journalctl -u victory-puma -n 50"
systemctl is-active --quiet victory-sidekiq && log "Sidekiq запущен" || warn "Sidekiq не запустился — проверьте: journalctl -u victory-sidekiq -n 50"

# ─── Logrotate ────────────────────────────────────────────────────────────────
cat > /etc/logrotate.d/victory <<'LOGROTATE'
/var/www/victory/current/log/*.log {
  daily
  missingok
  rotate 14
  compress
  delaycompress
  notifempty
  copytruncate
  su deploy deploy
}
LOGROTATE

log "Logrotate настроен"

# ─── SSL (Let's Encrypt) ─────────────────────────────────────────────────────
header "SSL / Let's Encrypt"

mkdir -p /var/www/certbot
if [[ -n "$DOMAIN" ]] && [[ "$DOMAIN" != "viktory-realty.ru" || $(hostname -f 2>/dev/null) == *"$DOMAIN"* ]]; then
  info "Получение сертификата для ${DOMAIN}..."
  certbot --nginx -d "${DOMAIN}" -d "www.${DOMAIN}" \
    --non-interactive --agree-tos --email "${ADMIN_EMAIL}" \
    --redirect 2>/dev/null && log "SSL сертификат получен" || \
    warn "SSL не настроен автоматически. Запустите вручную:
  certbot --nginx -d ${DOMAIN} -d www.${DOMAIN} --email ${ADMIN_EMAIL}"
else
  warn "SSL не запрошен автоматически (домен не разрешается или это localhost).
  Запустите вручную после настройки DNS:
  certbot --nginx -d ${DOMAIN} -d www.${DOMAIN} --email ${ADMIN_EMAIL}"
fi

# ─── Скрипт обновления ───────────────────────────────────────────────────────
header "Скрипт обновления"

cat > /usr/local/bin/victory-deploy <<DEPLOYSCRIPT
#!/usr/bin/env bash
# Обновление приложения (запускать от root или deploy через sudo)
set -euo pipefail

APP_DIR="${APP_DIR}"
APP_USER="${APP_USER}"
RBENV_ROOT="${RBENV_ROOT}"
BRANCH="${REPO_BRANCH}"

run() {
  sudo -u "\${APP_USER}" bash -c \
    "export RBENV_ROOT=\${RBENV_ROOT}; export PATH=\${RBENV_ROOT}/shims:\${RBENV_ROOT}/bin:\$PATH; cd \${APP_DIR}/current; set -a; source .env; set +a; \$*"
}

echo "[→] Получение обновлений..."
run "git fetch origin && git reset --hard origin/\${BRANCH}"

echo "[→] Bundle install..."
run "bundle install --jobs \$(nproc) --retry 3"

echo "[→] Миграции..."
run "bundle exec rails db:migrate RAILS_ENV=production"

echo "[→] Ассеты..."
run "bundle exec rails assets:precompile RAILS_ENV=production"
run "bundle exec rails tailwindcss:build RAILS_ENV=production" 2>/dev/null || true

echo "[→] Перезапуск Puma..."
systemctl reload-or-restart victory-puma

echo "[→] Перезапуск Sidekiq..."
systemctl reload-or-restart victory-sidekiq

echo "[✓] Деплой завершён: \$(date)"
DEPLOYSCRIPT

chmod +x /usr/local/bin/victory-deploy
log "Скрипт обновления: /usr/local/bin/victory-deploy"

# ─── Итог ─────────────────────────────────────────────────────────────────────
header "Развёртывание завершено"

PUMA_STATUS=$(systemctl is-active victory-puma   2>/dev/null || echo "unknown")
SIDEKIQ_STATUS=$(systemctl is-active victory-sidekiq 2>/dev/null || echo "unknown")
NGINX_STATUS=$(systemctl is-active nginx            2>/dev/null || echo "unknown")
PG_STATUS=$(systemctl is-active postgresql          2>/dev/null || echo "unknown")
REDIS_STATUS=$(systemctl is-active redis-server     2>/dev/null || echo "unknown")

echo ""
echo -e "${BOLD}Статус сервисов:${RESET}"
echo -e "  PostgreSQL   : $([ "$PG_STATUS"     = "active" ] && echo "${GREEN}$PG_STATUS${RESET}"     || echo "${RED}$PG_STATUS${RESET}")"
echo -e "  Redis        : $([ "$REDIS_STATUS"  = "active" ] && echo "${GREEN}$REDIS_STATUS${RESET}"  || echo "${RED}$REDIS_STATUS${RESET}")"
echo -e "  Puma         : $([ "$PUMA_STATUS"   = "active" ] && echo "${GREEN}$PUMA_STATUS${RESET}"   || echo "${RED}$PUMA_STATUS${RESET}")"
echo -e "  Sidekiq      : $([ "$SIDEKIQ_STATUS"= "active" ] && echo "${GREEN}$SIDEKIQ_STATUS${RESET}"|| echo "${RED}$SIDEKIQ_STATUS${RESET}")"
echo -e "  Nginx        : $([ "$NGINX_STATUS"  = "active" ] && echo "${GREEN}$NGINX_STATUS${RESET}"  || echo "${RED}$NGINX_STATUS${RESET}")"

echo ""
echo -e "${BOLD}Конфигурация:${RESET}"
echo -e "  Приложение   : ${APP_DIR}/current"
echo -e "  Env-файл     : ${APP_DIR}/current/.env"
echo -e "  Логи         : ${APP_DIR}/current/log/"
echo -e "  БД           : ${DB_NAME} @ localhost (user: ${DB_USER})"

echo ""
echo -e "${BOLD}Команды управления:${RESET}"
echo -e "  Обновить     : ${YELLOW}victory-deploy${RESET}"
echo -e "  Логи Puma    : ${YELLOW}journalctl -u victory-puma -f${RESET}"
echo -e "  Логи Sidekiq : ${YELLOW}journalctl -u victory-sidekiq -f${RESET}"
echo -e "  Рестарт      : ${YELLOW}systemctl restart victory-puma${RESET}"
echo -e "  Rails console: ${YELLOW}sudo -u ${APP_USER} bash -c 'cd ${APP_DIR}/current && source .env && bundle exec rails c'${RESET}"

echo ""
if [[ "$PUMA_STATUS" == "active" ]]; then
  echo -e "  ${GREEN}${BOLD}Сайт доступен: ${APP_URL}${RESET}"
else
  echo -e "  ${RED}${BOLD}Puma не запущен. Проверьте логи:${RESET}"
  echo -e "  journalctl -u victory-puma -n 50 --no-pager"
fi
echo ""
