#!/usr/bin/env bash
# SessionStart hook №2 — подготовка облачной сессии (Claude Code on the web).
#
# Зачем отдельный файл, а не дописка в session-start.sh: тот печатает routing и
# inbox за <100 мс и обязан отработать всегда. Этот ставит тулчейн и поднимает
# сервисы, идёт минутами и только в облаке. Разные обязанности — разные файлы;
# оба висят на SessionStart и выполняются по порядку.
#
# На машинах агентства (/home/q, /opt/.openclaw) скрипт выходит сразу: там свой
# Ruby через bin/rb и свои контейнеры, лезть туда с apt и initdb нельзя.
#
# Что делает (всё идемпотентно, повторный запуск — почти no-op):
#   1. Ruby 3.4.10 через rbenv (в образе только 3.1/3.2/3.3)
#   2. gem'ы проекта
#   3. PostgreSQL 16 + PostGIS + pgvector, кластер на trust-аутентификации
#   4. Redis
#   5. ENV для спеков в $CLAUDE_ENV_FILE
#   6. db:test:prepare
#
# Почему системный PostgreSQL, а не образ из Dockerfile.postgres, как в CI:
# docker-демон в облачном контейнере недоступен. Отсюда расхождение версий —
# PG 16 + PostGIS 3.4 против PG 15 + PostGIS 3.6 в проде и CI. Для прогона
# спеков это безразлично (db/structure.sql не пинит версии расширений), но
# верить облачному прогону как проверке совместимости с прод-базой нельзя:
# последнее слово за джобом RSpec в CI.
#
# Никогда не валит старт сессии: каждый шаг умеет отвалиться, сказать об этом
# и пропустить зависящие от него. Финальный exit — всегда 0.

set -uo pipefail

RUBY_TARGET='3.4.10'
PG_MAJOR='16'
PGDATA='/var/lib/postgresql/16/claude-cloud'
SCRATCH="${TMPDIR:-/tmp}/claude-bootstrap"

log() { printf '[bootstrap] %s\n' "$*"; }
fail() { printf '[bootstrap] ⚠️  %s\n' "$*"; }

# ── 0. Только облако ────────────────────────────────────────────────────────
if [ "${CLAUDE_CODE_REMOTE:-}" != 'true' ]; then
  exit 0
fi

cd "${CLAUDE_PROJECT_DIR:-$(pwd)}" 2>/dev/null || exit 0
mkdir -p "$SCRATCH"

log "облачная сессия: готовлю окружение в $(pwd)"

# ── 1. Ruby ─────────────────────────────────────────────────────────────────
RUBY_OK=0
if [ -x "/opt/rbenv/versions/${RUBY_TARGET}/bin/ruby" ]; then
  log "Ruby ${RUBY_TARGET} уже собран"
  RUBY_OK=1
elif command -v rbenv >/dev/null 2>&1; then
  # ruby-build в образе отстаёт и не знает 3.4.10 — подтягиваем определения.
  # Без этого rbenv install падает с «version not installed».
  if [ ! -f "/opt/rbenv/plugins/ruby-build/share/ruby-build/${RUBY_TARGET}" ]; then
    log "обновляю ruby-build (нет определения ${RUBY_TARGET})"
    git -C /opt/rbenv/plugins/ruby-build fetch --depth=1 -q origin master 2>&1 | tail -2
    git -C /opt/rbenv/plugins/ruby-build checkout -q FETCH_HEAD 2>&1 | tail -2
  fi
  log "собираю Ruby ${RUBY_TARGET} (несколько минут, результат кэшируется)"
  if rbenv install -s "$RUBY_TARGET" > "$SCRATCH/ruby-build.log" 2>&1; then
    log "Ruby ${RUBY_TARGET} собран"
    RUBY_OK=1
  else
    fail "сборка Ruby не удалась, хвост лога:"
    tail -15 "$SCRATCH/ruby-build.log"
  fi
else
  fail 'rbenv не найден — Ruby-часть пропущена'
fi

if [ "$RUBY_OK" = 1 ]; then
  export RBENV_VERSION="$RUBY_TARGET"
  export PATH="/opt/rbenv/versions/${RUBY_TARGET}/bin:/opt/rbenv/shims:${PATH}"
fi

# ── 2. Гемы ─────────────────────────────────────────────────────────────────
GEMS_OK=0
if [ "$RUBY_OK" = 1 ]; then
  # bundle check дешевле полного install и делает шаг почти-no-op на тёплом
  # контейнере. --jobs 4 заметно ускоряет первую холодную установку.
  if bundle check >/dev/null 2>&1; then
    log 'гемы на месте'
    GEMS_OK=1
  else
    log 'bundle install (первый прогон — минуты)'
    if bundle install --jobs 4 --retry 2 > "$SCRATCH/bundle.log" 2>&1; then
      log 'гемы установлены'
      GEMS_OK=1
    else
      fail 'bundle install не прошёл, хвост лога:'
      tail -20 "$SCRATCH/bundle.log"
    fi
  fi
fi

# ── 3. PostgreSQL + PostGIS + pgvector ──────────────────────────────────────
PGBIN="/usr/lib/postgresql/${PG_MAJOR}/bin"
PG_OK=0

if [ ! -x "$PGBIN/initdb" ]; then
  fail "PostgreSQL ${PG_MAJOR} не найден — БД-часть пропущена"
elif [ ! -f "/usr/share/postgresql/${PG_MAJOR}/extension/postgis.control" ] \
  || [ ! -f "/usr/share/postgresql/${PG_MAJOR}/extension/vector.control" ]; then
  log 'ставлю PostGIS + pgvector'
  # Индекс в образе протухший: без update половина .deb отдаёт 404.
  # -scripts нужен ради postgis_tiger_geocoder — его требует db/structure.sql.
  if { apt-get update -qq \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
         "postgresql-${PG_MAJOR}-postgis-3" \
         "postgresql-${PG_MAJOR}-postgis-3-scripts" \
         "postgresql-${PG_MAJOR}-pgvector"; } > "$SCRATCH/apt-pg.log" 2>&1; then
    log 'расширения установлены'
  else
    fail 'установка расширений не прошла, хвост лога:'
    tail -10 "$SCRATCH/apt-pg.log"
  fi
fi

if [ -x "$PGBIN/initdb" ] \
  && [ -f "/usr/share/postgresql/${PG_MAJOR}/extension/postgis.control" ] \
  && [ -f "/usr/share/postgresql/${PG_MAJOR}/extension/vector.control" ]; then
  mkdir -p "$PGDATA"
  chown postgres:postgres "$PGDATA" 2>/dev/null

  if [ ! -f "$PGDATA/PG_VERSION" ]; then
    log 'инициализирую кластер'
    # trust, как и в CI: кластер слушает только внутри контейнера и умирает
    # вместе с ним. Пароль здесь ничего не защищает, зато захардкоженный он
    # неотличим от настоящего и валит секрет-сканер.
    su postgres -c "$PGBIN/initdb -D '$PGDATA' -A trust -U postgres" \
      > "$SCRATCH/initdb.log" 2>&1 \
      || { fail 'initdb не прошёл:'; tail -10 "$SCRATCH/initdb.log"; }
  fi

  # Лог сервера обязан лежать внутри PGDATA, а не в scratch: scratch создан
  # под root с правами 755, и `su postgres` в него не пишет — pg_ctl тогда
  # падает ещё до запуска, а причину узнать неоткуда (первый прогон уткнулся
  # ровно в это: «cannot open pg.log»).
  PGLOG="$PGDATA/startup.log"

  # Спрашиваем pg_ctl про НАШ каталог, а не pg_isready про порт. В образе
  # рядом лежит дебиановский кластер /var/lib/postgresql/16/main со
  # scram-аутентификацией; если на 5432 сидит он, pg_isready ответит «готов»,
  # а createdb и db:test:prepare упадут на авторизации — и сводка при этом
  # отрапортует успех. pg_ctl status различает эти два случая.
  if su postgres -c "$PGBIN/pg_ctl -D '$PGDATA' status" >/dev/null 2>&1; then
    log 'PostgreSQL уже поднят'
    PG_OK=1
  elif [ -f "$PGDATA/PG_VERSION" ]; then
    log 'поднимаю PostgreSQL'
    # fsync=off — база одноразовая, живёт внутри сессии; без этого
    # DatabaseCleaner упирается в statement_timeout на TRUNCATE сотен таблиц.
    if su postgres -c "$PGBIN/pg_ctl -D '$PGDATA' -l '$PGLOG' -w -t 60 \
      -o '-p 5432 -h 127.0.0.1 -c fsync=off -c synchronous_commit=off -c full_page_writes=off' start" \
      > "$SCRATCH/pg-ctl.log" 2>&1; then
      PG_OK=1
    else
      fail 'PostgreSQL не поднялся (возможно, порт 5432 занят чужим кластером):'
      tail -10 "$SCRATCH/pg-ctl.log" 2>/dev/null
      tail -15 "$PGLOG" 2>/dev/null
    fi
  fi
fi

# Тестовая база: создаём здесь, а не полагаемся на db:test:prepare — тот
# подключается к ней же и на пустом кластере спотыкается о её отсутствие.
# Неудача тушит PG_OK: без базы шаг 6 всё равно не отработает, а молчаливый
# postgres:1 в сводке — хуже, чем честный ноль.
if [ "$PG_OK" = 1 ]; then
  if ! su postgres -c "$PGBIN/psql -h 127.0.0.1 -p 5432 -U postgres -tAc \
    \"SELECT 1 FROM pg_database WHERE datname='viktory_realty_test'\"" 2>/dev/null \
    | grep -q 1; then
    if su postgres -c "$PGBIN/createdb -h 127.0.0.1 -p 5432 -U postgres viktory_realty_test" \
         > "$SCRATCH/createdb.log" 2>&1; then
      log 'создана база viktory_realty_test'
    else
      fail 'не удалось создать viktory_realty_test:'
      tail -5 "$SCRATCH/createdb.log" 2>/dev/null
      PG_OK=0
    fi
  fi
fi

# ── 4. Redis ────────────────────────────────────────────────────────────────
if command -v redis-server >/dev/null 2>&1; then
  if redis-cli -h 127.0.0.1 ping >/dev/null 2>&1; then
    log 'Redis уже поднят'
  else
    redis-server --daemonize yes --bind 127.0.0.1 --port 6379 \
      --save '' --appendonly no > "$SCRATCH/redis.log" 2>&1 \
      && log 'Redis поднят' \
      || fail 'Redis не поднялся'
  fi
else
  fail 'redis-server не найден — Sidekiq-спеки могут падать'
fi

# ── 5. ENV сессии ───────────────────────────────────────────────────────────
# Набор ровно тот же, что у джоба RSpec в .github/workflows/lint.yml — чтобы
# облачный прогон и CI расходились только версией PostgreSQL, а не конфигом.
# Значения-заглушки не секреты: сеть в спеках закрыта WebMock
# (spec/support/external_services.rb), наружу никто не ходит. Они нужны лишь
# потому, что Telegram::Client и Llm::OmniClient отказываются инициализироваться
# с пустыми значениями — то есть без них спеки не создадут даже объект.
#
# DATABASE_NAME намеренно НЕ выставляем: config/database.yml читает его только
# в production/staging, а имена dev- и test-баз там захардкожены. Выставленная
# переменная создавала бы ложное впечатление, что ею можно управлять.
#
# Маркер против повторной дописки: SessionStart срабатывает и на resume/clear/
# compact, а блок содержит самоссылающийся `PATH=…:$PATH` — без маркера каталоги
# rbenv добавлялись бы в PATH заново на каждом старте.
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  if grep -q 'victory-bootstrap-env' "$CLAUDE_ENV_FILE" 2>/dev/null; then
    log 'ENV уже записан, пропускаю'
  else
    {
      echo '# victory-bootstrap-env'
      if [ "$RUBY_OK" = 1 ]; then
        echo "export RBENV_VERSION='${RUBY_TARGET}'"
        echo "export PATH=\"/opt/rbenv/versions/${RUBY_TARGET}/bin:/opt/rbenv/shims:\$PATH\""
      fi
      echo "export DATABASE_HOST='127.0.0.1'"
      echo "export DATABASE_PORT='5432'"
      echo "export DATABASE_USERNAME='postgres'"
      echo "export REDIS_URL='redis://127.0.0.1:6379/0'"
      echo "export DATABASE_CLEANER_ALLOW_REMOTE_DATABASE_URL='true'"
      echo "export TELEGRAM_BOT_TOKEN='not-a-token-webmock-blocks-network'"
      echo "export OMNIROUTE_BASE_URL='http://llm.invalid/v1'"
      echo "export OMNIROUTE_API_KEY='not-a-key-webmock-blocks-network'"
    } >> "$CLAUDE_ENV_FILE"
    log 'ENV записан в CLAUDE_ENV_FILE'
  fi
fi

# ── 6. Тестовая база ────────────────────────────────────────────────────────
if [ "$GEMS_OK" = 1 ] && [ "$PG_OK" = 1 ]; then
  log 'db:test:prepare'
  RAILS_ENV=test \
  DATABASE_HOST=127.0.0.1 DATABASE_PORT=5432 \
  DATABASE_USERNAME=postgres \
  REDIS_URL='redis://127.0.0.1:6379/0' \
  TELEGRAM_BOT_TOKEN='not-a-token-webmock-blocks-network' \
  OMNIROUTE_BASE_URL='http://llm.invalid/v1' \
  OMNIROUTE_API_KEY='not-a-key-webmock-blocks-network' \
    bundle exec rails db:test:prepare > "$SCRATCH/db-prepare.log" 2>&1 \
    && log 'тестовая база готова' \
    || { fail 'db:test:prepare не прошёл, хвост лога:'; tail -15 "$SCRATCH/db-prepare.log"; }
fi

# ── Итог ────────────────────────────────────────────────────────────────────
log "готово — ruby:${RUBY_OK} gems:${GEMS_OK} postgres:${PG_OK}"
if [ "$GEMS_OK" != 1 ]; then
  fail 'Ruby-инструменты недоступны: rubocop и rspec в этой сессии не гонять'
fi

exit 0
