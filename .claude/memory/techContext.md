# techContext.md — стек и инфра

## Стек

| Слой | Технология |
|------|-----------|
| Web framework | Rails **8.1.3.1** (в проде с 08.08.26; `load_defaults` пока 7.1) |
| Language | Ruby **3.4.10** — только в контейнере, через `bin/rb`. На хосте менеджера версий нет (ни chruby, ни rbenv, ни mise), системный ruby 3.3.8 не совпадает с пином Gemfile, поэтому `bundle`/`rspec`/`bin/rails` напрямую в worktree не работают |
| Database | PostgreSQL 15+ (с PostGIS + pgvector) |
| Server | Puma 6.x, порт **3000** в Docker (reverse-proxy → 443 в проде) |
| CSS | Tailwind CSS (`tailwindcss-rails`) |
| JS bundling | Importmap + Stimulus + Turbo (Hotwire) |
| Auth | Devise (**отключен**) |
| Search | PgSearch (full-text, Russian dictionary) |
| Pagination | Kaminari |
| Background jobs | Sidekiq 7 + sidekiq-cron — **активны в проде** (контейнер `victory-sidekiq-1`), расписание в `config/sidekiq_cron.yml` |
| API | Rack::CORS, jbuilder, JWT (для `/api/v1/`) |
| Geocoding | Geocoder gem |
| Scheduling | Whenever (cron) |
| WebSockets | Action Cable |
| File uploads | Active Storage |
| Testing | RSpec, FactoryBot, Shoulda Matchers, DatabaseCleaner, Capybara (selenium_chrome_headless для JS-спеков) |

## Module name

`ViktoryRealty` — главный модуль (см. `config/application.rb`).

## Локализация / TZ

- `Faker::Config.locale = 'ru'` для тестов.
- Default locale: `:ru`. Locale files: `config/locales/ru.yml`, `config/locales/devise.ru.yml`.
- Timezone: Moscow (`config.time_zone = 'Moscow'`).

## ENV vars

| Variable | Default | Описание |
|----------|---------|---------|
| `RAILS_ENV` | `development` | окружение |
| `PORT` | `5000` (старое) / `3000` (Docker) | порт сервера |
| `DATABASE_URL` | — | полный PG URL (production) |
| `DATABASE_HOST` | `localhost` | DB host |
| `DATABASE_PORT` | `5432` | DB port |
| `DATABASE_USERNAME` | `postgres` | DB user |
| `DATABASE_PASSWORD` | `''` | DB password |
| `REDIS_URL` | `redis://localhost:6379/0` | Redis (Sidekiq + cache) |
| `RAILS_MAX_THREADS` | `5` | thread count / DB pool |
| `WEB_CONCURRENCY` | `1` | Puma workers |
| `ACTION_CABLE_URL` | `ws://localhost:3000/cable` | WS endpoint |
| `CORS_ORIGINS` | `*` | allowed origins (CSV) |
| `APP_HOST` | `localhost` | hostname |
| `APP_PROTOCOL` | `http` | scheme |
| `JWT_SECRET_KEY` | (credentials) | JWT signing |
| `ASSET_HOST` | — | CDN |
| `LOG_LEVEL` | `debug`/`info` | logger verbosity |
| `SESSION_TIMEOUT` | `1800` | session expiry (sec) |
| `ADMIN_TOKEN` | — | query-param admin guard (Admin::Reviews, Admin::Articles) |
| `TELEGRAM_BOT_TOKEN` | — | основной TG-бот сайта (`@anvictorybot`) |
| `TELEGRAM_STAFF_CHAT_ID` | `-1003937910508` (dev+owner) | куда уходят отчёты/уведомления |
| `TOPNLAB_API_KEY` | — | ключ CRM; без него `Topnlab::Client` кидает `Error` на init |
| `TOPNLAB_BASE_URL` | — | база API (`agencies-p.topnlab.ru`); тоже обязательна |
| `YANDEX_AI_STUDIO_API_KEY` + `YANDEX_CLOUD_FOLDER_ID` | — | Vision OCR для document intake |
| `YANDEX_WEBMASTER_TOKEN` + `YANDEX_WEBMASTER_USER_ID` | — | Webmaster API (digest, recrawl) |

## DB и миграции

- DB-имена: `viktory_realty_development`, `viktory_realty_test`, `viktory_realty_production`.
- Расширения: `postgis`, `vector` (pgvector), `pg_trgm`, `unaccent`.
- ~13 базовых миграций; новые — по фазам.

## Команды

### Сервер
```bash
bundle exec rails server -p 5000 -b 0.0.0.0  # legacy
bin/rails server                              # Docker prod: :3000
```

### БД
```bash
bin/rails db:create
bin/rails db:migrate
bin/rails db:seed
bin/rails db:reset    # drop + create + migrate + seed
```

### Тесты
```bash
bundle exec rspec
bundle exec rspec spec/models/property_spec.rb
bundle exec rspec --format documentation
```

### Lint
```bash
bundle exec rubocop
bundle exec rubocop -a    # safe autocorrect
bundle exec rubocop -A    # unsafe autocorrect
```

### Sidekiq (когда нужно)
```bash
bundle exec sidekiq -C config/sidekiq.yml
```
Очереди по приоритету: `critical` → `mailers` → `default` → `scheduled` → `low_priority`.

### Cron (Whenever)
```bash
bundle exec whenever --update-crontab
bundle exec whenever --clear-crontab
```
Расписание:
- ежечасно: `SendViewingRemindersJob`
- 03:00: `UpdatePropertyStatisticsJob`
- 10:00: `PropertyValuationFollowUpJob`

### Переезд базы на bookworm — что сделать при пересборке прод-образа

С PR #42 `Dockerfile.postgres` строится от `postgres:15-bookworm`, а не от
`postgis/postgis:15-3.5` (у bullseye 07.09.26 протух `Release` debian-security и
сборка перестала проходить). Мажор PostgreSQL прежний, каталог данных и volume
`pgdata` совместимы, но **одной пересборки мало**.

| | Было | Стало |
|---|---|---|
| PostgreSQL | 15.13 | 15.19 |
| PostGIS | 3.5.2 | 3.6.4 |
| pgvector | 0.8.2 | 0.8.6 |
| glibc | 2.31 | 2.36 |

Смена glibc меняет порядок сортировки: у `viktory_realty_test` в `datcollversion`
записано `2.31`, новый образ даёт `2.36`. Индексы по тексту, построенные под
старой библиотекой, надо перестроить — иначе поиск и уникальные ограничения
могут повести себя неверно. После `docker compose up -d --build db`:

```sql
REINDEX DATABASE viktory_realty_development;
ALTER DATABASE viktory_realty_development REFRESH COLLATION VERSION;
SELECT postgis_extensions_upgrade();
ALTER EXTENSION vector UPDATE;
```

⚠️ `REINDEX DATABASE` держит блокировки — гнать в окно простоя, не на живом
трафике. Проверить результат: `SELECT postgis_full_version();` не должен просить
upgrade, а `datcollversion` должен стать `2.36`.

Ещё одно следствие: базовый образ больше не создаёт `postgis` в свежей базе сам
(в `postgis/postgis` это делал initdb-скрипт, теперь в новой базе только
`plpgsql`). Схемы это не касается — `db/structure.sql` создаёт все семь
расширений, — но `bin/backup verify` теперь проверяет `postgis` осмысленно.

Соседние сессии: `pgdata` в стеке `bin/rb` создан старым образом; 15.19 поверх
каталога 15.13 стартует штатно, при странностях — `bin/rb --nuke`.

### Деплой смены Ruby/Rails — пересборка прод-образов

Прод (`/home/q/victory`, compose-проект `victory`) монтирует код bind-mount'ом с
code-reload, поэтому merge в main обновляет код сразу, а **гемы и рантайм — нет**:
они живут в образах `victory-web`/`victory-sidekiq` и в named-volume
`victory_bundle` (`/usr/local/bundle`, каталог `ruby/<ABI>`). Volume перекрывает
образ: без пересоздания новый Ruby не увидит ни одного гема и `bundle exec`
упадёт на старте. Отработано дважды: 08.08.26 (Rails 8.1.3.1) и 07.09.26 (Ruby 3.3.6 → 3.4.10).
Правки ниже — из второго прогона.

```bash
cd /home/q/victory
# 1. откат-теги
/usr/bin/docker tag victory-web victory-web:pre-ruby34
/usr/bin/docker tag victory-sidekiq victory-sidekiq:pre-ruby34
# 2. ПРЕДПОЛЁТ: ff-only пройдёт только если локальная main — предок origin/main.
#    07.09.26 не прошёл бы: на проде висел коммит из ОТКРЫТОГО PR (SECURITY.md),
#    ветка разошлась. Проверить и, если разошлась, выровнять reset'ом —
#    но сперва убедиться, что коммит цел на удалённой ветке своего PR.
git fetch origin
git merge-base --is-ancestor HEAD origin/main && echo ff-ok || git branch -r --contains HEAD
# 3. свежий main + сборка (старые контейнеры пока служат)
git pull --ff-only origin main    # либо: git reset --hard origin/main
/usr/bin/docker compose build web sidekiq
# 4. свап (даунтайм ~30-60с) — БЕЗ ПАУЗЫ после шага 3, см. предупреждение ниже
/usr/bin/docker compose stop web sidekiq
/usr/bin/docker compose rm -f web sidekiq
/usr/bin/docker volume rm victory_bundle
/usr/bin/docker compose up -d web sidekiq
# 5. verify
/usr/bin/docker compose exec web ruby -v            # 3.4.10
/usr/bin/docker compose logs web | grep 'Booted'    # Rails 8.1.3.1
curl -sI https://victory62.org | head -1            # 200
/usr/bin/docker compose logs --tail=50 sidekiq      # cron-джобы идут
```

🚨 **Окно уязвимости между шагами 3 и 4.** Как только новый `Gemfile` ляжет в
bind-mount, рантайм контейнера перестанет ему соответствовать. Работающий Rails
это переживёт — bundler своё уже отработал, — но у `web` и `sidekiq` политика
`restart=unless-stopped`, и любой рестарт в этом окне (ребут хоста, OOM,
падение) вернёт контейнер, который не загрузится. Проверено 07.09.26 в
контейнере 3.3.6 против Gemfile 3.4.10:

```
Bundler::RubyVersionMismatch: Your Ruby version is 3.3.6, but your Gemfile specified 3.4.10
```

Сжать окно сборкой образа заранее (`--build-arg RUBY_VERSION=…`) получится не
всегда: `ARG RUBY_VERSION` в `Dockerfile` появился только в PR #14, на более
старом чекауте флаг молча проигнорируется. Поэтому шаги 3 и 4 идут подряд.

🚨 **Откат — это дерево И образы, одних тегов мало.** Образы `pre-*` несут
прежний Ruby, а дерево после шага 3 требует нового: вернуть только образы —
получить тот же `RubyVersionMismatch`, но уже с обеих сторон.

```bash
git -C /home/q/victory reset --hard <коммит перед апгрейдом>   # для 3.4.10 это 5831765
/usr/bin/docker tag victory-web:pre-ruby34 victory-web
/usr/bin/docker tag victory-sidekiq:pre-ruby34 victory-sidekiq
# далее тот же свап с volume rm
```

Миграций смена Ruby не несёт, но накопившиеся коммиты могут: перед деплоем
сверить `git diff --name-only <прод> origin/main -- db/migrate/`. 07.09.26 там
было пусто (113 файлов с обеих сторон), поэтому шага с `db:migrate` в процедуре
нет — он не универсален.

⚠️ `victory-rubybox` (образ для `bin/rb`) имеет энтрипойнт, ждущий Postgres:
любой `docker run` по нему без `--entrypoint` виснет молча.

**Последние два шага — обязательны, иначе состояние прода снова станет
невидимым:**

```bash
bin/prod-mark            # отметить в GitHub, что именно выкачено
```

`bin/prod-mark` двигает ветку `prod` на выкаченный коммит и ставит тег
`deploy/<dd.MM.yy-HHmm>` с метаданными (Ruby, образ, хост). Без этого GitHub
о выкатке не знает: мерж в `main` и деплой — независимые события, и отличить
«лежит в main» от «работает на сайте» неоткуда. Ровно так 07.09.26 прод
незаметно отстал на 33 коммита.

Ветку `prod` тянет обычный `git fetch`, а `.git` у всех worktree общий —
поэтому `session-start.sh` показывает состояние прода каждой сессии и считает,
сколько коммитов ждёт выкатки. Скрипт отказывается писать при расхождениях
(грязный прод-чекаут, коммит вне `origin/main`) — это осознанно: врущая
отметка хуже отсутствующей. Осмотреть без записи — `bin/prod-mark --check`,
продавить — `--force`.

Затем: обновить строку про прод в `progress.md` (таблица «что в проде»).

## Replit-специфика

`config.hosts.clear` в development разрешает все хосты. Порт 5000 жёстко прибит под Replit proxy. Не удалять — нужно для dev-окружения.

## MCP / Claude Code инфра (Phase 1)

- `.mcp.json` в корне — конфиг 4 MCP-серверов: `serena`, `postgres`, `github`, `rails-guides`.
  MCP `postgres` поднимается контейнером `node:20-alpine` в docker-сети `victory_default`
  — по одному на сессию, безымянные, накапливаются после ребутов.
- `.claude/memory/` — этот memory-bank.
- `.claude/repo-index.md` — компактный индекс «файл → классы» (~5k токенов, читать первым).
- `.claude/repo-map.md` — полный сигнатурный дамп (~190k, on-demand). Оба: `rake repo:map`.
- `.claude/agents/` — проектные субагенты; routing-таблица — `.claude/docs/delegation-map.md`.
- `~/.claude-shared/` — межсессионный обмен: `inbox/`, `events/`, `locks/`.
- `.remember/logs/` — дневной журнал remember-плагина (лежит в main checkout).

Установленные плагины (user-level, не в репо): superpowers, context7, ruby-lsp, pyright-lsp, remember, code-review, feature-dev, telegram, vercel, figma, firecrawl, и др. См. `/home/q/.claude/plugins/installed_plugins.json`.
