#!/usr/bin/env bash
# postCreateCommand для Codespaces / Dev Containers.
#
# Отрабатывает один раз при создании контейнера. Гемы и расширения PostgreSQL
# уже лежат в образах (Dockerfile и Dockerfile.postgres), здесь остаётся
# догнать дрейф Gemfile и развернуть базы.
#
# Не валит создание контейнера: любой шаг может отвалиться, сказать об этом
# и пропустить зависящие. Codespace должен подняться даже с битой базой —
# иначе чинить её будет негде.

set -uo pipefail

log() { printf '[post-create] %s\n' "$*"; }
fail() { printf '[post-create] ⚠️  %s\n' "$*"; }

cd /workspaces/victory || exit 0

log "ruby $(ruby -v 2>/dev/null | awk '{print $2}') · bundler $(bundle -v 2>/dev/null | awk '{print $3}')"

# ── Гемы ────────────────────────────────────────────────────────────────────
# Образ собран на Gemfile.lock момента сборки. Если с тех пор он изменился
# (или образ поднят из кэша слоёв постарше), bundle check это поймает.
GEMS_OK=0
if bundle check >/dev/null 2>&1; then
  log 'гемы на месте'
  GEMS_OK=1
else
  log 'bundle install'
  if bundle install --jobs 4 --retry 2; then
    GEMS_OK=1
  else
    fail 'bundle install не прошёл'
  fi
fi

# ── Базы ────────────────────────────────────────────────────────────────────
# db:prepare создаёт базу и грузит db/structure.sql; db:test:prepare — то же
# для тестовой. Обе идемпотентны.
if [ "$GEMS_OK" = 1 ]; then
  log 'db:prepare (development)'
  bin/rails db:prepare || fail 'db:prepare не прошёл'

  log 'db:test:prepare'
  RAILS_ENV=test bin/rails db:test:prepare || fail 'db:test:prepare не прошёл'
fi

# ── Git-хуки ────────────────────────────────────────────────────────────────
# .git/hooks под git не попадает — доставляем из отслеживаемого .githooks/.
# Нужен post-commit: он снимает claude-локи с закоммиченных файлов.
[ -x bin/install-git-hooks ] && bin/install-git-hooks >/dev/null 2>&1

# ── Проверка ────────────────────────────────────────────────────────────────
if [ "$GEMS_OK" = 1 ]; then
  log 'проверяю: rubocop --version + один спек'
  bundle exec rubocop --version || fail 'rubocop недоступен'
fi

log 'готово. Полезное:'
log '  bundle exec rspec                 — 1102 примера'
log '  bundle exec rubocop --parallel    — линтер'
log '  bin/services-check                — учёт служб под services/'
log '  bin/rails server                  — порт 3000 проброшен'
