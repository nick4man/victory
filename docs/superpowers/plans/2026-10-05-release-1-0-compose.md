# Релиз 1.0: единый compose, production-образы, снимок состояния — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Зафиксировать текущее состояние кода как релиз `v1.0.0`: собрать все службы (Rails web + sidekiq, конвейер новостей, реестр ЖК, audit-engine) в один `docker-compose.yml` с отдельным образом на каждую службу, перевести прод с bind-mount в `RAILS_ENV=development` на неизменяемый production-образ, и написать спеку для агентов на openclaw-машине, чьи копии служб остаются работать в тестовом режиме до отключения.

**Architecture:** Один compose-файл в корне, у каждой службы свой образ `ghcr.io/nick4man/victory-<служба>:<тег>` и своя переменная тега (`WEB_TAG`, `CONVEYOR_TAG`, `ZHK_TAG`), по умолчанию равная общей `VICTORY_TAG`. Это даёт модульность: обновить одну службу = поменять один тег и выполнить `docker compose up -d --no-deps <служба>`, остальные контейнеры не трогаются. Python-службы работают по расписанию внутри своего контейнера (supercronic), а не в crontab хоста; службы, чьи данные ещё живут на openclaw (конвейер) или в архиве (audit-engine), объявлены в compose под `profiles` и не стартуют, пока их явно не включат. Переключение прода идёт через контрольный стек `victory-rc` на том же хосте (другой compose-проект, порт 3001, копия БД из бэкапа), и только после его прогона — замена боевых контейнеров в проекте `victory` с сохранением томов `pgdata`/`redisdata` и каталога `storage/`.

**Tech Stack:** Docker 29 / Compose v5.5 (`include:`, `profiles`, вложенные дефолты `${A:-${B:-x}}`), Ruby 3.4.10 / Rails 8.1.3.1, sprockets + tailwindcss-rails (`assets:precompile`), Python 3.12-slim + supercronic, PostgreSQL 15 + PostGIS + pgvector (`Dockerfile.postgres`), GitHub Container Registry (ghcr.io).

**Spec:** `~/2026-10-05 Архитектура разработки.md` (раздел 5, «Ступень 1. Прод как прод») + голосовое ТЗ пользователя от 05.10.26, расшифровано в разделе «Решения, принятые в плане» ниже. План исполняется **только на прод-хосте `victory`** (`hostname` = `victory`): там docker, бэкапы, прод-тома и `storage/`. На openclaw-машине ни одна задача не выполняется — для неё задача 9 пишет спеку. Рабочий каталог — worktree `/home/q/victory-release` (ветка `claude/release-1.0`); внутрь `/home/q/victory` правило `Write(//home/q/victory/**)` в `.claude/settings.json` писать не даёт, и это правильно.

## Решения, принятые в плане

Расшифровка ТЗ в проверяемые решения. Если какое-то из них не совпадает с ожиданием пользователя — остановиться и спросить до начала задачи, которая на нём стоит.

| # | Решение | Из чего следует |
|---|---|---|
| Р1 | **`v1.0.0` = текущий `origin/main` (`1ca42b1`) без функциональных правок.** В релиз входят только изменения упаковки: Dockerfile, compose, `production.rb` (хосты/health), скрипты выката, документация. | «сделать снимок того, как работает сейчас» |
| Р2 | **Прод переходит на `RAILS_ENV=production` в этом релизе**, а не в следующем. Это единственное поведенческое изменение, и ради него есть задача 7 (контрольный стек) и откат в задаче 10. | «выкатываем прод версию продакшн» + раздел 3.1 архитектурного документа |
| Р3 | **Данные не переезжают.** Тома `victory_pgdata`, `victory_redisdata` и каталог `/home/q/victory/storage` (3,4 ГБ, Active Storage, в т. ч. паспорта) остаются на месте; новые контейнеры монтируют их же. База не переименовывается: production-блок `database.yml` читает `DATABASE_NAME`, туда идёт текущее имя `viktory_realty_development`. Переименование — отдельная гигиеническая задача после 1.0. | минимальный радиус поражения |
| Р4 | **Образы собираются на прод-хосте** (`docker compose build`), тегируются `1.0.0` и `sha-<7>`, пушатся в `ghcr.io/nick4man/victory-*`, если `docker login ghcr.io` проходит. Сборка в CI — следующий план. | «собрать докер… через docker compose» |
| Р5 | **Конвейер новостей и audit-engine входят в compose, но под `profiles` и выключены.** У конвейера две БД (`urgent_events` с pgvector и `posts_queue`), чьи схемы живут только на openclaw и в репозитории не описаны; у audit-engine живой контейнер поднят из архива. Образ конвейера собирается и тестируется здесь (задача 4), включение — после того как openclaw-агенты пришлют схему (задача 9). Это и есть «они продолжают работать в тестовом режиме, пока я их не заглушу». | ТЗ + `services/urgent-news-collector/CLAUDE.md`, секция «Две чужие БД» |
| Р6 | **Реестр ЖК включается сразу** (`profiles` нет): его единственная зависимость — вебхук Rails, схема в `db/`. Крон-строка из crontab хоста при этом **убирается**, иначе обход пойдёт дважды. | `services/zhk-registry/SERVICE.md` |
| Р7 | **`chat-host-cron/post_news_to_victory.sh` не становится образом.** Он подключается в контейнер конвейера файлом (`volumes:` в compose, read-only) и переменной `MIRROR_SCRIPT` — это уже существующий контракт между службами, а `bin/services-check` запрещает ссылаться на соседнюю службу изнутри каталога службы; compose в корне под проверку не попадает. | правило 3 `services/README.md` |
| Р8 | **Простой при переключении допустим** (30–60 с: стоп старых web/sidekiq → старт новых). Выкатка без простоя (Kamal / `kamal-proxy`) — ступень 2, отдельный план. | раздел 5 архитектурного документа |
| Р9 | **`bin/deploy` не переписывается.** Он завязан на ff-merge чекаута и bind-mount; после 1.0 этот путь перестаёт быть продом. Появляется короткий `bin/rollout <тег>` (задача 6), `bin/deploy` помечается как устаревший. Удаление — в следующем плане вместе с CI. | 555 строк, не трогать в релизе-снимке |
| Р10 | **Порт 3000 остаётся опубликован на интерфейсе хоста**, но через переменную `WEB_BIND` (по умолчанию `0.0.0.0`), чтобы следующий план закрыл его одной строкой в `.env`. Traefik на VDS ходит на этот хост по сети, и какой именно интерфейс он использует, из репозитория не видно — проверить до сужения (раздел 7 архитектурного документа). | не менять то, что не проверено |

## Global Constraints

- Ruby **3.4.10**, образ `ruby:3.4.10-slim-bookworm`; `postgresql-client-15` пинован мажором (см. комментарий в текущем `Dockerfile`).
- PostgreSQL-образ прода — `viktory-postgres-pgvector:pg15-postgis36` из `Dockerfile.postgres`; в compose менять нельзя, иначе compose пересоздаст контейнер `db`.
- Три жёстких правила репозитория для Ruby-кода (soft delete, `_prefix: true`, даты `dd.MM.yy`). В этом плане Ruby-правка одна — `config/environments/production.rb`; frozen string literal, одинарные кавычки.
- Python-службы: `bin/services-check` должен проходить после каждой задачи (`python3 bin/services-check`); внутри каталога службы нельзя упоминать имя соседней службы и импортировать `app/`.
- Секреты: `.env`, `.env.production`, `.env.rc`, `.env.conveyor`, `.env.zhk` не коммитятся (`.gitignore`); читать их только через `grep -o '^KEY='` или `sed 's/=.*/=…/'`. В план и в коммиты значения не попадают.
- Все даты в документах, тегах и комментариях — `dd.MM.yy`.
- Коммиты — на ветке `claude/release-1.0` в `/home/q/victory-release`, в прод только через PR в `main` и обязательное `/code-review`.
- Ничего не выполнять в `/home/q/victory` (main checkout = живой прод), кроме задачи 10 (переключение), где это сказано явно.

## Review Focus

Что спека подразумевает, но ни один автотест не ловит; тест на каждый пункт добавлен в задачу-владельца.

1. **Health-check из контейнера и с хоста (`Host: 127.0.0.1:3000`) под `RAILS_ENV=production`** — `config.hosts` в `production.rb` пропускает только `victory62.org` и поддомены, значит docker healthcheck, `bin/rollout` и Traefik-проверки получат 403 «Blocked host», а `force_ssl` ещё и перекинет на https. Ожидание: `/health*` отвечает 200 по http с любым Host. → задача 1, шаг 2; задача 2, шаг 6.
2. **Вебхук `POST /webhooks/zhk_ingest` изнутри docker-сети (`Host: web:3000`)** — та же блокировка хостов, иначе реестр ЖК «работает», а Rails молча отвечает 403. Ожидание: `RAILS_EXTRA_HOSTS=web` пропускает. → задача 5, шаг 7; задача 7, шаг 7.
3. **Отсутствие `assets:precompile` или пустой `public/assets`** — в production `config.assets.compile = false`, страница откроется без CSS (Tailwind) и будет выглядеть «работает», пока не посмотришь глазами. Ожидание: в образе есть `public/assets/tailwind-*.css`, а главная RC-стека ссылается на него и он отдаётся 200. → задача 2, шаг 5; задача 7, шаг 6.
4. **Имя базы при смене окружения** — development-блок игнорирует `DATABASE_NAME` и берёт `viktory_realty_development`; production-блок берёт `DATABASE_NAME`, по умолчанию `viktory_realty_production`. Если в `.env` стоит другое имя, новый web на старте выполнит `db:prepare`, **создаст пустую базу** и сайт поднимется пустым — без ошибки. Ожидание: перед переключением имя сверено, `db:prepare` видит существующие таблицы. → задача 7, шаги 3 и 5; задача 10, шаг 2.
5. **Двойной прогон расписания** — пока контейнер `zhk-registry` работает, а строка в crontab хоста не удалена, обход идёт дважды и шлёт две сводки; у конвейера то же самое с openclaw-кроном, если включить профиль раньше, чем заглушат ту копию. Ожидание: после задачи 10 в `crontab -l` нет строки `zhk-registry`, профиль `conveyor` выключен. → задача 10, шаг 6; задача 9 (спека).

---

## Структура файлов

| Файл | Действие | За что отвечает |
|---|---|---|
| `VERSION` | создать | единственное место с номером релиза (`1.0.0`) |
| `config/environments/production.rb` | изменить | `/health*` без проверки хоста и без редиректа на https; `RAILS_EXTRA_HOSTS`; лог в stdout |
| `Dockerfile` | переписать | multi-stage: `base` → `build` → `dev` (прежнее поведение для `bin/rb`) и `prod` (gems без dev/test, `assets:precompile`, непривилегированный пользователь) |
| `.dockerignore` | изменить | не тащить в образ `storage/`, `spec/`, `tests/`, `docs/`, корневые `*.md`, `services/` |
| `docker-compose.yml` | переписать | боевой стек: образы с тегами, тома, healthcheck'и, `include:` audit, профили |
| `docker-compose.dev.yml` | создать | override, воспроизводящий сегодняшнее поведение (bind-mount, `RAILS_ENV=development`, `target: dev`) — для сессий разработки и как путь отката |
| `docker-compose.ruby.yml` | изменить | `target: dev` у службы `ruby`, иначе `bin/rb` соберёт prod-образ без dev-гемов |
| `docker-compose.audit.yml` | изменить | `profiles: [audit]`, `AUDIT_DB_PASSWORD` без `:?` |
| `services/urgent-news-collector/Dockerfile` | создать | образ конвейера: python 3.12, requirements, supercronic, тесты на этапе сборки |
| `services/urgent-news-collector/crontab.docker` | создать | расписание для supercronic, пути контейнера, вывод в stdout |
| `services/urgent-news-collector/schema/README.md` | создать | куда класть DDL двух БД конвейера |
| `services/urgent-news-collector/SERVICE.md` | изменить | `deploy:` → compose-служба `conveyor`, профиль |
| `services/zhk-registry/Dockerfile` | создать | образ реестра ЖК |
| `services/zhk-registry/crontab.docker` | создать | расписание для supercronic |
| `services/zhk-registry/SERVICE.md`, `crontab.example` | изменить | `deploy:` → compose-служба; пометка «на хосте строку убрать» |
| `services/README.md` | изменить | добавить `zhk-registry` в таблицу, раздел «Упаковка» |
| `.env.conveyor.example`, `.env.zhk.example` | создать | формы env-файлов служб (ключи без значений) |
| `.gitignore` | изменить | `.env.conveyor`, `.env.zhk`, `.env.rc`, `.env.deploy` |
| `bin/release` | создать | собрать все образы, навесить теги `<версия>` и `sha-<7>`, при наличии логина — push |
| `bin/rollout` | создать | выкатить тег: бэкап → `compose pull/up` → health → `bin/smoke` → `bin/prod-mark` |
| `bin/smoke` | создать | 8–9 HTTP-проверок стека по базовому URL; используется для RC и после переключения |
| `docs/runbooks/release.md` | создать | как собрать релиз, как обновить одну службу, как откатить |
| `docs/runbooks/cutover-1.0.md` | создать | пошаговое переключение прода 1.0 с точками невозврата и откатом; результат прогона RC |
| `docs/specs/2026-10-05-openclaw-services-test-mode.md` | создать | спека для агентов openclaw-машины |
| `bin/deploy` | изменить | шапка: устарел с 1.0, указать на `bin/rollout` |
| `CLAUDE.md`, `.claude/memory/techContext.md`, `.claude/memory/activeContext.md`, `.github/workflows/claude.yml` | изменить | деплой через образы; `RAILS_ENV=production`; таблица служб; противоречие «автодеплой» убрать |

---

### Task 1: `VERSION` и production.rb под работу за Traefik и внутри docker-сети

**Files:**
- Create: `VERSION`
- Modify: `config/environments/production.rb`
- Test: `ruby -c` в контейнере; поведение — задача 2, шаг 6 (RSpec грузит `test`-окружение и до production-конфига не доходит)

**Interfaces:**
- Produces: переменная окружения `RAILS_EXTRA_HOSTS` (список через запятую), которую задачи 3 и 5 выставляют в `web,localhost,127.0.0.1`; пути `/health`, `/health/database`, `/admin/health.json` отвечают по http без проверки Host.

- [ ] **Step 1: Файл версии**

```bash
cd /home/q/victory-release
git status -sb | head -1     # ## claude/release-1.0...origin/main
printf '1.0.0\n' > VERSION
```

- [ ] **Step 2: Исключить `/health*` из проверки хоста и из принудительного https, добавить дополнительные хосты**

В `config/environments/production.rb` найти блок

```ruby
  app_domain = ENV.fetch('APP_DOMAIN', 'victory62.org')
  config.hosts = [
    app_domain,
    "www.#{app_domain}",
    /.*\.#{Regexp.escape(app_domain)}/
  ]
```

и заменить на

```ruby
  app_domain = ENV.fetch('APP_DOMAIN', 'victory62.org')
  config.hosts = [
    app_domain,
    "www.#{app_domain}",
    /.*\.#{Regexp.escape(app_domain)}/
  ]
  # Имена, под которыми приложение видят соседи по docker-сети и сам хост:
  # `web` — для служб из services/ (zhk-registry шлёт вебхук на http://web:3000),
  # `127.0.0.1` — для bin/rollout и healthcheck. Список через запятую; без него
  # Rails отвечает 403 «Blocked host», и вебхук «работает», ничего не доставляя.
  config.hosts += ENV.fetch('RAILS_EXTRA_HOSTS', '').split(',').map(&:strip).reject(&:empty?)
  # /health* проверяют docker healthcheck и Traefik — у них Host произвольный и
  # схема http. Без исключений первый получает 403, второй — 301 на https.
  health_path = ->(request) { request.path.start_with?('/health') }
  config.host_authorization = { exclude: health_path }
  config.ssl_options = { redirect: { exclude: health_path } }
```

- [ ] **Step 3: Проверить, что файл остаётся валидным Ruby**

Ruby на хосте нет; синтаксис проверяется в контейнере базового образа:

```bash
/usr/bin/docker run --rm -v "$PWD/config:/app/config:ro" ruby:3.4.10-slim-bookworm ruby -c /app/config/environments/production.rb
```

Expected: `Syntax OK`

- [ ] **Step 4: Коммит**

```bash
git add VERSION config/environments/production.rb
git commit -m "release 1.0: VERSION и production.rb для работы за Traefik и в docker-сети

/health* без проверки Host и без редиректа на https; RAILS_EXTRA_HOSTS
для обращений из docker-сети (web) и с хоста (127.0.0.1).

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Multi-stage Dockerfile — стадии `dev` (как сейчас) и `prod` (код в образе, ассеты собраны)

**Files:**
- Modify: `Dockerfile`
- Modify: `.dockerignore`
- Modify: `docker-compose.ruby.yml` (служба `ruby`: `target: dev`)
- Test: сборка обеих стадий и `bin/rails runner` внутри prod-образа

**Interfaces:**
- Produces: образ со стадией `prod` (по умолчанию), `WORKDIR /app`, пользователь `app` (uid 1000), `ENTRYPOINT /app/bin/docker-entrypoint`, `CMD bin/rails server -b 0.0.0.0 -p 3000`; стадия `dev` — прежнее поведение для `bin/rb` и `docker-compose.dev.yml`.

- [ ] **Step 1: Переписать `Dockerfile`**

```dockerfile
# Прод фиксирован на 3.4.10 (значение по умолчанию — сборка без --build-arg
# остаётся прежней). upgrade-сессия подменяет версию через RUBY_TARGET.
#
# Стадии:
#   base       — рантайм-пакеты, общие для всех;
#   build      — компиляторы, bundle install со всеми группами;
#   dev        — то, что было единственным образом до 1.0: все гемы, без
#                ассетов, без USER — под bind-mount и bin/rb
#                (docker-compose.ruby.yml, docker-compose.dev.yml: target: dev);
#   prod-build — гемы без development/test, assets:precompile;
#   prod       — код внутри, только runtime, user app. Стадия последняя,
#                поэтому `docker build .` без --target даёт её.
ARG RUBY_VERSION=3.4.10

FROM ruby:${RUBY_VERSION}-slim-bookworm AS base
ENV LANG=C.UTF-8 \
    TZ=Europe/Moscow \
    BUNDLE_PATH=/usr/local/bundle \
    BUNDLE_JOBS=4 \
    BUNDLE_RETRY=3
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
        libpq5 \
        libyaml-0-2 \
        libvips42 \
        # Мажорная версия пинуется намеренно: db/structure.sql грузится и
        # дампится через psql/pg_dump, а сервер у нас pg15. Метапакет
        # postgresql-client при бампе базового образа молча уедет на 16/17.
        postgresql-client-15 \
        curl \
        tzdata && \
    rm -rf /var/lib/apt/lists/*
WORKDIR /app

FROM base AS build
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
        build-essential \
        libpq-dev \
        libyaml-dev \
        git && \
    rm -rf /var/lib/apt/lists/*
COPY Gemfile Gemfile.lock ./
RUN bundle install

# dev: прежний единственный образ. Гемы development/test на месте, ассеты не
# собраны (в development их собирает tailwindcss-rails на лету), root — потому
# что код приезжает bind-mount'ом и compose подставляет user: UID:GID сам.
FROM build AS dev
COPY . .
RUN mkdir -p tmp/pids log storage
EXPOSE 3000
ENTRYPOINT ["/app/bin/docker-entrypoint"]
CMD ["bin/rails", "server", "-b", "0.0.0.0", "-p", "3000"]

# prod-build: убрать dev/test-гемы и собрать ассеты. SECRET_KEY_BASE_DUMMY —
# штатный способ Rails запустить precompile без настоящего секрета.
FROM build AS prod-build
RUN bundle config set --local without 'development test' && \
    bundle install && \
    bundle clean --force && \
    rm -rf "${BUNDLE_PATH}"/ruby/*/cache
COPY . .
RUN SECRET_KEY_BASE_DUMMY=1 RAILS_ENV=production bin/rails assets:precompile && \
    rm -rf node_modules tmp/cache

FROM base AS prod
ENV RAILS_ENV=production \
    BUNDLE_WITHOUT="development test" \
    BUNDLE_DEPLOYMENT=1
RUN groupadd --gid 1000 app && useradd --uid 1000 --gid app --create-home app
COPY --from=prod-build --chown=app:app /usr/local/bundle /usr/local/bundle
COPY --from=prod-build --chown=app:app /app /app
RUN mkdir -p tmp/pids tmp/sockets log storage && chown -R app:app tmp log storage
USER app
EXPOSE 3000
ENTRYPOINT ["/app/bin/docker-entrypoint"]
CMD ["bin/rails", "server", "-b", "0.0.0.0", "-p", "3000"]
```

- [ ] **Step 2: Дополнить `.dockerignore`**

Добавить в конец файла:

```
# Не относится к рантайму Rails — в образ не едет (1.0)
storage/*
!storage/.keep
spec
tests
docs
services
tg-webhook-relay
attached_assets
public/assets
*.md
!README.md
```

Строка `storage/*` важна отдельно: иначе `COPY . .` на прод-хосте затащит в образ 3,4 ГБ клиентских документов.

- [ ] **Step 3: Указать стадию `dev` для ruby-box**

В `docker-compose.ruby.yml`, служба `ruby`, блок `build:`:

```yaml
    build:
      context: .
      target: dev
      args:
        RUBY_VERSION: ${RUBY_TARGET:-3.4.10}
```

- [ ] **Step 4: Собрать обе стадии**

```bash
cd /home/q/victory-release
/usr/bin/docker build --target dev  -t victory-web:dev-check  .
/usr/bin/docker build --target prod -t victory-web:prod-check .
```

Expected: оба `docker build` завершаются `exit 0`. На шаге `assets:precompile` в логе есть строка вида `Writing /app/public/assets/tailwind-<hash>.css`.

- [ ] **Step 5: Проверить содержимое prod-образа (ассеты, пользователь, отсутствие dev-гемов и storage)**

```bash
/usr/bin/docker run --rm victory-web:prod-check sh -c '
  id -u;
  ls public/assets | grep -c "^tailwind-.*\.css$";
  ls storage | wc -l;
  bundle list 2>/dev/null | grep -c -E "^  \* (rubocop|rspec-core|brakeman) " || true'
```

Expected, четыре строки: `1000`, `1` (или больше), `0`, `0`.

- [ ] **Step 6: Проверить production-конфиг из задачи 1 внутри образа**

Rails грузится без БД (`DATABASE_URL` на несуществующий хост, `rails runner` до соединения не доходит):

```bash
/usr/bin/docker run --rm \
  -e SECRET_KEY_BASE=check -e DATABASE_URL=postgresql://x@db.invalid/x \
  -e REDIS_URL=redis://redis.invalid:6379/0 -e RAILS_EXTRA_HOSTS=web,127.0.0.1 \
  -e OMNIROUTE_BASE_URL=http://llm.invalid/v1 -e OMNIROUTE_API_KEY=x -e TELEGRAM_BOT_TOKEN=x \
  victory-web:prod-check bin/rails runner '
    hosts = Rails.application.config.hosts
    puts hosts.include?("web") && hosts.include?("127.0.0.1")
    req = ActionDispatch::Request.new(Rack::MockRequest.env_for("/health/database"))
    puts Rails.application.config.host_authorization[:exclude].call(req)
    puts Rails.application.config.ssl_options.dig(:redirect, :exclude).call(req)
    puts Rails.env'
```

Expected: `true`, `true`, `true`, `production`. Если `runner` падает на инициализаторе, который требует переменную, — добавить её заглушку в `-e` (так же, как делает `lint.yml` для RSpec), и записать её в задачу 3 как обязательный ключ `.env`.

- [ ] **Step 7: Убедиться, что `bin/rb` всё ещё собирает dev-стадию**

```bash
/usr/bin/docker compose -f docker-compose.ruby.yml config | grep -A3 'build:' | grep target
```

Expected: `target: dev`

- [ ] **Step 8: Коммит**

```bash
git add Dockerfile .dockerignore docker-compose.ruby.yml
git commit -m "release 1.0: multi-stage Dockerfile — стадии dev (как было) и prod

prod: код в образе, гемы без development/test, assets:precompile,
пользователь app (1000). dev — прежнее поведение для bin/rb и bind-mount.
.dockerignore не пускает storage/ и тесты в образ.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: Боевой `docker-compose.yml` + override `docker-compose.dev.yml`

**Files:**
- Modify: `docker-compose.yml` (полная замена)
- Modify: `docker-compose.audit.yml`
- Create: `docker-compose.dev.yml`
- Test: `docker compose config` в трёх режимах; сравнение службы `db` с сегодняшним прод-стеком

**Interfaces:**
- Consumes: стадии `dev`/`prod` из задачи 2; `RAILS_EXTRA_HOSTS` из задачи 1.
- Produces: переменные `REGISTRY` (по умолчанию `ghcr.io/nick4man`), `VICTORY_TAG` (по умолчанию `1.0.0`), `WEB_TAG`, `CONVEYOR_TAG`, `ZHK_TAG`, `WEB_BIND`, `WEB_PORT`, `STORAGE_DIR`, `GIT_COMMIT_SHA`; имена служб `db`, `redis`, `web`, `sidekiq`; профиль `audit`. Задачи 4–5 добавляют `conveyor`, `news-db`, `zhk-registry` по этой же схеме.

- [ ] **Step 1: Переписать `docker-compose.yml`**

```yaml
# Боевой стек АН «Виктори». Один файл — все службы, у каждой свой образ и свой тег.
#
#   docker compose up -d                       # web, sidekiq, db, redis, zhk-registry
#   docker compose --profile conveyor up -d    # + конвейер новостей (после переезда его БД)
#   docker compose --profile audit up -d       # + audit-engine (после репатриации, см. VENDOR.md)
#
# Теги: общий VICTORY_TAG (из .env.deploy, по умолчанию 1.0.0) и по-службный
# override — WEB_TAG / CONVEYOR_TAG / ZHK_TAG. Обновить одну службу:
#   ZHK_TAG=1.0.1 docker compose up -d --no-deps --pull always zhk-registry
# Остальные контейнеры не пересоздаются. Подробно — docs/runbooks/release.md.
#
# Разработка (bind-mount, RAILS_ENV=development, как было до 1.0):
#   docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d
#
# Имя проекта задано явно: тома pgdata/redisdata называются victory_pgdata и
# victory_redisdata — это сегодняшние прод-тома, их нельзя потерять при
# переезде с bind-mount. Контрольный стек поднимается с -p victory-rc и
# получает свои тома.
name: victory

include:
  # audit-engine: четыре контейнера и внутренняя сеть, все под профилем audit
  # (живой контейнер пока поднят из архива openclaw на хосте chat — VENDOR.md).
  - docker-compose.audit.yml

x-rails: &rails
  image: ${REGISTRY:-ghcr.io/nick4man}/victory-web:${WEB_TAG:-${VICTORY_TAG:-1.0.0}}
  build:
    context: .
    target: prod
    args:
      RUBY_VERSION: 3.4.10
  restart: unless-stopped
  env_file:
    - .env
  environment:
    # Переопределяет RAILS_ENV=development из .env: environment: сильнее env_file.
    RAILS_ENV: production
    RAILS_LOG_TO_STDOUT: '1'
    RAILS_SERVE_STATIC_FILES: '1'
    RAILS_EXTRA_HOSTS: web,localhost,127.0.0.1
    PUMA_STDOUT_LOG: /dev/stdout
    PUMA_STDERR_LOG: /dev/stderr
    GIT_COMMIT_SHA: ${GIT_COMMIT_SHA:-}
  volumes:
    # Active Storage (3,4 ГБ, в т.ч. паспорта) — тот же каталог, что и до 1.0.
    # Не named volume: иначе данные пришлось бы переносить, а это релиз-снимок.
    - ${STORAGE_DIR:-./storage}:/app/storage
    - rails_tmp:/app/tmp
    - rails_log:/app/log
  depends_on:
    db:
      condition: service_healthy
    redis:
      condition: service_healthy

services:
  db:
    # Образ и теги ровно те же, что до 1.0: compose не должен увидеть разницу и
    # пересоздать контейнер базы.
    build:
      context: .
      dockerfile: Dockerfile.postgres
    image: viktory-postgres-pgvector:pg15-postgis36
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
    volumes:
      - pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 5s
      timeout: 3s
      retries: 20

  redis:
    image: redis:7-alpine
    restart: unless-stopped
    volumes:
      - redisdata:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 3s
      retries: 10

  web:
    <<: *rails
    ports:
      # WEB_BIND сужается до внутреннего интерфейса следующим планом, после
      # проверки, с какого адреса ходит Traefik (архитектурный документ, раздел 7).
      - "${WEB_BIND:-0.0.0.0}:${WEB_PORT:-3000}:3000"
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://127.0.0.1:3000/health/database"]
      interval: 15s
      timeout: 5s
      retries: 5
      start_period: 90s

  sidekiq:
    <<: *rails
    command: ["bundle", "exec", "sidekiq", "-C", "config/sidekiq.yml"]
    # YAML-якорь не сливает хэши, поэтому environment: повторён целиком;
    # SKIP_DB_PREPARE только здесь — миграции гонит web на старте, как и до 1.0.
    environment:
      RAILS_ENV: production
      RAILS_LOG_TO_STDOUT: '1'
      RAILS_EXTRA_HOSTS: web,localhost,127.0.0.1
      SKIP_DB_PREPARE: "1"
      GIT_COMMIT_SHA: ${GIT_COMMIT_SHA:-}
    depends_on:
      db:
        condition: service_healthy
      redis:
        condition: service_healthy
      web:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "ps -o args= -p 1 | grep -q sidekiq"]
      interval: 30s
      timeout: 5s
      retries: 3

volumes:
  pgdata:
  redisdata:
  rails_tmp:
  rails_log:
```

- [ ] **Step 2: Перевести службы audit-engine под профиль**

В `docker-compose.audit.yml` каждой из четырёх служб (`audit-postgres`, `audit-redis`, `audit-api`, `audit-mc-worker`) добавить первой строкой внутри службы:

```yaml
    profiles: [audit]
```

Заменить шапку-комментарий «Compose with the main file: …» на:

```yaml
# Подключается из docker-compose.yml через include:, все службы под профилем
# audit — живой контейнер audit-v2-api пока поднят из архива openclaw на хосте
# chat (VENDOR.md), здесь стек стартует только явно:
#   docker compose --profile audit up -d
```

Переменная `${AUDIT_DB_PASSWORD:?…}` с `:?` упадёт при любом `docker compose config`, даже без профиля. В двух местах заменить `${AUDIT_DB_PASSWORD:?AUDIT_DB_PASSWORD must be set in .env.audit}` на `${AUDIT_DB_PASSWORD:-}` и добавить к `audit-postgres` комментарий `# пустой пароль = стек не настроен; проверка переехала в docs/runbooks/release.md`.

- [ ] **Step 3: Создать `docker-compose.dev.yml`**

```yaml
# Override для разработки и для отката с 1.0: воспроизводит стек, каким он был
# до релиза — код bind-mount'ом, RAILS_ENV=development, стадия dev.
#
#   docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d
#
# В проде НЕ использовать с 1.0; оставлен как путь отката (docs/runbooks/cutover-1.0.md).
services:
  web:
    image: victory-web:dev
    build:
      target: dev
    user: "${UID:-1000}:${GID:-1000}"
    environment:
      RAILS_ENV: development
      RAILS_LOG_TO_STDOUT: ''
      RAILS_SERVE_STATIC_FILES: ''
      PUMA_STDOUT_LOG: ''
      PUMA_STDERR_LOG: ''
    volumes:
      - ./:/app
      - bundle:/usr/local/bundle
      - rails_tmp:/app/tmp
      - rails_log:/app/log
    healthcheck:
      disable: true
    tty: true
    stdin_open: true

  sidekiq:
    image: victory-web:dev
    build:
      target: dev
    user: "${UID:-1000}:${GID:-1000}"
    environment:
      RAILS_ENV: development
      SKIP_DB_PREPARE: "1"
    volumes:
      - ./:/app
      - bundle:/usr/local/bundle
      - rails_tmp:/app/tmp
      - rails_log:/app/log
    depends_on:
      web:
        condition: service_started
    healthcheck:
      disable: true

volumes:
  bundle:
```

- [ ] **Step 4: Проверить, что все три конфигурации собираются**

```bash
cd /home/q/victory-release
cp .env.example .env.compose-check
/usr/bin/docker compose --env-file .env.compose-check config --quiet && echo PROD_OK
/usr/bin/docker compose --env-file .env.compose-check --profile audit config --quiet && echo PROFILES_OK
/usr/bin/docker compose --env-file .env.compose-check -f docker-compose.yml -f docker-compose.dev.yml config --quiet && echo DEV_OK
/usr/bin/docker compose --env-file .env.compose-check config --services | sort | tr '\n' ' '; echo
rm .env.compose-check
```

Expected: `PROD_OK`, `PROFILES_OK`, `DEV_OK`; список служб без профилей: `db redis sidekiq web`.

- [ ] **Step 5: Убедиться, что контейнер `db` в проде не будет пересоздан**

```bash
diff <(git show origin/main:docker-compose.yml | sed -n '/^  db:/,/^  redis:/p') \
     <(sed -n '/^  db:/,/^  redis:/p' docker-compose.yml)
```

Expected: пустой вывод.

- [ ] **Step 6: Проверить тег web и per-service override**

```bash
cp .env.example .env.compose-check
/usr/bin/docker compose --env-file .env.compose-check config | grep 'image: ghcr'
WEB_TAG=sha-abc1234 /usr/bin/docker compose --env-file .env.compose-check config | grep 'victory-web:'
rm .env.compose-check
```

Expected: сначала две строки `image: ghcr.io/nick4man/victory-web:1.0.0` (web и sidekiq), затем две с `:sha-abc1234`.

- [ ] **Step 7: Коммит**

```bash
git add docker-compose.yml docker-compose.dev.yml docker-compose.audit.yml
git commit -m "release 1.0: единый docker-compose.yml на образах, dev-override для отката

Образы ghcr.io/nick4man/victory-*, общий VICTORY_TAG и per-service теги,
storage/ прежним каталогом, тома victory_pgdata/redisdata без изменений.
audit-engine подключён через include: под профилем audit.
docker-compose.dev.yml — стек в прежнем виде (bind-mount, development).

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: Образ конвейера новостей (`conveyor`) под профилем

**Files:**
- Create: `services/urgent-news-collector/Dockerfile`
- Create: `services/urgent-news-collector/crontab.docker`
- Create: `services/urgent-news-collector/schema/README.md`
- Create: `.env.conveyor.example`
- Modify: `services/urgent-news-collector/SERVICE.md` (поле `deploy`)
- Modify: `docker-compose.yml` (службы `conveyor`, `news-db`), `.gitignore`
- Test: 46 unittest внутри сборки образа; `supercronic -test`; `docker compose config` с профилем; `bin/services-check`

**Interfaces:**
- Consumes: схему compose из задачи 3; контракт `MIRROR_SCRIPT` → `services/chat-host-cron/post_news_to_victory.sh` (Р7).
- Produces: образ `${REGISTRY}/victory-conveyor:${CONVEYOR_TAG}`, служба `conveyor` (профиль `conveyor`), служба `news-db` (тот же профиль), env-файл `.env.conveyor`; каталог `services/urgent-news-collector/schema/` — пустой до прихода дампа от openclaw (задача 9), оттуда `news-db` подхватывает `*.sql` через `/docker-entrypoint-initdb.d`.

- [ ] **Step 1: Dockerfile конвейера**

`services/urgent-news-collector/Dockerfile`:

```dockerfile
# Конвейер новостей как контейнер. Расписание — supercronic (crontab.docker),
# а не crontab хоста: служба едет с кодом и тегом образа.
#
# Контекст сборки — каталог службы (compose: build.context). Соседние службы
# здесь не упоминаются намеренно (правило 3 services/README.md): скрипт зеркала
# на сайт подключает compose томом и переменной MIRROR_SCRIPT.
FROM python:3.12-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    TZ=Europe/Moscow \
    CONVEYOR_HOME=/opt/conveyor

# bash, jq, curl нужны скрипту зеркала; postgresql-client — pg_isready/psql
# для диагностики из контейнера (psycopg2-binary сам ничего не требует).
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends bash curl jq tzdata postgresql-client-15 && \
    rm -rf /var/lib/apt/lists/*

# supercronic — cron для контейнеров: пишет в stdout, пробрасывает окружение,
# не требует root. Версия и сумма пинуются; при обновлении сверить с
# https://github.com/aptible/supercronic/releases
ARG SUPERCRONIC_VERSION=v0.2.33
ARG SUPERCRONIC_SHA256
ADD https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-amd64 /usr/local/bin/supercronic
RUN if [ -n "$SUPERCRONIC_SHA256" ]; then echo "${SUPERCRONIC_SHA256}  /usr/local/bin/supercronic" | sha256sum -c -; fi && \
    chmod +x /usr/local/bin/supercronic

WORKDIR ${CONVEYOR_HOME}
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .
# Тесты — часть сборки: образ с красными тестами не существует.
RUN python3 -m unittest test_urgent_relevance test_classify_retry test_model_chains

RUN groupadd --gid 1000 app && useradd --uid 1000 --gid app --create-home app && \
    mkdir -p logs notifications published state mirror && chown -R app:app ${CONVEYOR_HOME}
USER app

CMD ["supercronic", "-passthrough-logs", "/opt/conveyor/crontab.docker"]
```

- [ ] **Step 2: Расписание для контейнера**

`services/urgent-news-collector/crontab.docker`:

```
# Расписание конвейера внутри контейнера (supercronic). Зеркало crontab.example:
# те же интервалы, пути /opt/conveyor, логи в stdout контейнера.
# flock оставлен: холодный старт коллектора может идти дольше 30 минут.
*/30 * * * * flock -n /tmp/urgent_collector.lock python3 /opt/conveyor/urgent_collector.py
2,17,32,47 * * * * flock -n /tmp/urgent_trigger.lock python3 /opt/conveyor/urgent_trigger.py
0 6-20 * * 1 flock -n /tmp/weekly_digest.lock python3 /opt/conveyor/weekly_digest_trigger.py
0 6-12 * * 2 flock -n /tmp/weekly_digest.lock python3 /opt/conveyor/weekly_digest_trigger.py
0 7 * * 2,4 python3 /opt/conveyor/bank_rates_trigger.py
```

- [ ] **Step 3: Форма env-файла**

`.env.conveyor.example` (в корне, рядом с `.env.example`; ключи — те, что читают `urgent_collector.py`, `urgent_trigger.py`, `content_db_utils.py`, `pipeline_utils.py`):

```
# Конвейер новостей (services/urgent-news-collector) в контейнере conveyor.
# Скопировать в .env.conveyor и заполнить. Значения — из /opt/victory-conveyor/.env
# на openclaw-машине (спека docs/specs/2026-10-05-openclaw-services-test-mode.md).

# --- БД событий (urgent_events, pgvector) — служба news-db в compose ---
NEWS_DB_HOST=news-db
NEWS_DB_PORT=5432
NEWS_DB_NAME=
NEWS_DB_USER=
NEWS_DB_PASSWORD=

# --- БД очереди постов (posts_queue, system_flags). До переезда очереди это
#     та же news-db; потребитель очереди (постер в Telegram) живёт на openclaw ---
DB_HOST=news-db
DB_NAME=
DB_USER=
DB_PASSWORD=

# --- LLM-шлюз. На openclaw это 127.0.0.1:20128; из контейнера localhost не виден —
#     тот же адрес, что OMNIROUTE_BASE_URL в .env Rails ---
OMNIROUTE_BASE_URL=
OMNIROUTE_API_KEY=
GEMINI_EMBEDDING_API_KEY=

# --- Зеркало на сайт: вебхук Rails изнутри docker-сети ---
VICTORY_NEWS_URL=http://web:3000/webhooks/news_ingest
VICTORY_NEWS_TOKEN=
MIRROR_SCRIPT=/opt/conveyor/mirror/post_news_to_victory.sh

# --- Модель и окна (дефолты в коде, менять не обязательно) ---
URGENT_COLLECTOR_MODEL=
URGENT_MAX_AGE_HOURS=
SEEN_HEADLINE_WINDOW_DAYS=
```

- [ ] **Step 4: Службы в `docker-compose.yml`**

Добавить в `services:` после `sidekiq`:

```yaml
  # --- Конвейер новостей. Профиль conveyor: БД urgent_events/posts_queue пока на
  # openclaw, схема приедет в services/urgent-news-collector/schema/*.sql (спека
  # docs/specs/2026-10-05-openclaw-services-test-mode.md). До этого не стартует.
  news-db:
    profiles: [conveyor]
    build:
      context: .
      dockerfile: Dockerfile.postgres
    image: viktory-postgres-pgvector:pg15-postgis36
    restart: unless-stopped
    env_file:
      - .env.conveyor
    environment:
      POSTGRES_DB: ${NEWS_DB_NAME:-news}
      POSTGRES_USER: ${NEWS_DB_USER:-news}
      POSTGRES_PASSWORD: ${NEWS_DB_PASSWORD:-}
    volumes:
      - newsdb:/var/lib/postgresql/data
      - ./services/urgent-news-collector/schema:/docker-entrypoint-initdb.d:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${NEWS_DB_USER:-news} -d ${NEWS_DB_NAME:-news}"]
      interval: 5s
      timeout: 3s
      retries: 20

  conveyor:
    profiles: [conveyor]
    image: ${REGISTRY:-ghcr.io/nick4man}/victory-conveyor:${CONVEYOR_TAG:-${VICTORY_TAG:-1.0.0}}
    build:
      context: ./services/urgent-news-collector
    restart: unless-stopped
    env_file:
      - .env.conveyor
    volumes:
      # Контракт двух служб (MIRROR_SCRIPT) собирается здесь, а не в образе —
      # services-check запрещает службе ссылаться на соседку.
      - ./services/chat-host-cron/post_news_to_victory.sh:/opt/conveyor/mirror/post_news_to_victory.sh:ro
      - conveyor_state:/opt/conveyor/state
      - conveyor_published:/opt/conveyor/published
      - conveyor_notifications:/opt/conveyor/notifications
      - conveyor_logs:/opt/conveyor/logs
    depends_on:
      news-db:
        condition: service_healthy
      web:
        condition: service_healthy
```

В `volumes:` в конце файла добавить:

```yaml
  newsdb:
  conveyor_state:
  conveyor_published:
  conveyor_notifications:
  conveyor_logs:
```

Каталог схемы с описанием:

```bash
mkdir -p services/urgent-news-collector/schema
cat > services/urgent-news-collector/schema/README.md <<'EOF'
# schema/ — DDL двух БД конвейера

Сюда кладутся `*.sql` (schema-only, `pg_dump --schema-only --no-owner`) для таблиц
`urgent_events` (pgvector), `posts_queue`, `system_flags`. Контейнер `news-db`
выполняет их при первом старте (`/docker-entrypoint-initdb.d`).

Пока каталог пуст — профиль `conveyor` включать нельзя: коллектор упадёт на
первом INSERT. Дамп присылают агенты openclaw-машины по спеке
`docs/specs/2026-10-05-openclaw-services-test-mode.md`.
EOF
```

В `.gitignore`, раздел «Ignore environment variables», добавить строки `.env.conveyor` и `.env.zhk`.

- [ ] **Step 5: Обновить `SERVICE.md`**

В `services/urgent-news-collector/SERVICE.md` строку `deploy:` заменить на:

```
deploy: compose-служба conveyor (профиль conveyor) в корневом docker-compose.yml; до переезда БД — ./deploy.sh в /opt/victory-conveyor на openclaw, см. docs/specs/2026-10-05-openclaw-services-test-mode.md
```

- [ ] **Step 6: Собрать образ — тесты идут внутри сборки; запинить сумму supercronic**

```bash
cd /home/q/victory-release
/usr/bin/docker build -t victory-conveyor:check services/urgent-news-collector
/usr/bin/docker run --rm victory-conveyor:check sha256sum /usr/local/bin/supercronic
```

Expected: в логе `Ran 46 tests` … `OK`, сборка `exit 0`; вторая команда печатает сумму. Вписать её в `Dockerfile` как значение по умолчанию: `ARG SUPERCRONIC_SHA256=<сумма>` — и пересобрать: `sha256sum -c` в логе даёт `OK`.

- [ ] **Step 7: Проверить расписание, границы служб, профиль**

```bash
/usr/bin/docker run --rm victory-conveyor:check supercronic -test /opt/conveyor/crontab.docker
python3 bin/services-check
git check-ignore .env.conveyor .env.zhk
cp .env.example .env.compose-check; touch .env.conveyor
/usr/bin/docker compose --env-file .env.compose-check --profile conveyor config --services | grep -cE '^(conveyor|news-db)$'
rm .env.compose-check
```

Expected: `crontab is valid` (5 записей); services-check зелёный; `check-ignore` печатает оба имени; последняя строка `2`. Пустой `.env.conveyor` оставить до задачи 9.

- [ ] **Step 8: Коммит**

```bash
git add services/urgent-news-collector/Dockerfile services/urgent-news-collector/crontab.docker \
        services/urgent-news-collector/schema/README.md services/urgent-news-collector/SERVICE.md \
        .env.conveyor.example docker-compose.yml .gitignore
git commit -m "release 1.0: конвейер новостей как служба conveyor (профиль, выключен)

Образ python:3.12 + supercronic, 46 тестов в сборке. news-db под схему
urgent_events/posts_queue, которую пришлют с openclaw. Зеркало на сайт —
томом из chat-host-cron (контракт MIRROR_SCRIPT).

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: Образ реестра ЖК (`zhk-registry`) — включён по умолчанию

**Files:**
- Create: `services/zhk-registry/Dockerfile`
- Create: `services/zhk-registry/crontab.docker`
- Create: `.env.zhk.example`
- Modify: `services/zhk-registry/SERVICE.md`, `services/zhk-registry/crontab.example`
- Modify: `docker-compose.yml`
- Test: unittest внутри сборки; `supercronic -test`; `services-check`; запрос с `Host: web` — в задаче 7

**Interfaces:**
- Consumes: `RAILS_EXTRA_HOSTS=web` (задачи 1/3) — вебхук идёт на `http://web:3000`.
- Produces: образ `${REGISTRY}/victory-zhk-registry:${ZHK_TAG}`, служба `zhk-registry` без профиля; env `.env.zhk` с `VICTORY_BASE_URL=http://web:3000`.

- [ ] **Step 1: Dockerfile реестра**

`services/zhk-registry/Dockerfile` (значение `SUPERCRONIC_SHA256` по умолчанию — та же сумма, что получена в задаче 4, шаг 6: один бинарь, одна версия):

```dockerfile
# Реестр новостроек как контейнер: еженедельный обход по supercronic.
FROM python:3.12-slim-bookworm

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    TZ=Europe/Moscow

RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends tzdata && \
    rm -rf /var/lib/apt/lists/*

ARG SUPERCRONIC_VERSION=v0.2.33
ARG SUPERCRONIC_SHA256
ADD https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-amd64 /usr/local/bin/supercronic
RUN if [ -n "$SUPERCRONIC_SHA256" ]; then echo "${SUPERCRONIC_SHA256}  /usr/local/bin/supercronic" | sha256sum -c -; fi && \
    chmod +x /usr/local/bin/supercronic

WORKDIR /opt/zhk-registry
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .
RUN python3 -m unittest discover -v

RUN groupadd --gid 1000 app && useradd --uid 1000 --gid app --create-home app
USER app

CMD ["supercronic", "-passthrough-logs", "/opt/zhk-registry/crontab.docker"]
```

- [ ] **Step 2: Расписание**

`services/zhk-registry/crontab.docker`:

```
# Обход справочника ЖК — раз в неделю, ночь с понедельника на вторник (MSK).
# Зеркало crontab.example; вывод — в stdout контейнера (MAILTO заменяют
# docker-логи и алерты следующего плана).
0 3 * * 2 flock -n /tmp/zhk-registry.lock python3 /opt/zhk-registry/run.py
```

- [ ] **Step 3: Форма env-файла**

`.env.zhk.example`:

```
# Реестр ЖК (services/zhk-registry) в контейнере zhk-registry.
# Скопировать в .env.zhk. Токен — тот же, что ZHK_INGEST_TOKEN в .env Rails.
VICTORY_BASE_URL=http://web:3000
ZHK_INGEST_TOKEN=
CRAWLER_CONTACT=info@victory62.org
# DRY_RUN=1 — обход без единого POST (проверка селекторов); в проде пусто.
DRY_RUN=
```

- [ ] **Step 4: Служба в `docker-compose.yml`**

Добавить в `services:` после `sidekiq` (перед блоком конвейера):

```yaml
  # --- Реестр ЖК. Без профиля: зависит только от вебхука Rails. Крон-строка из
  # crontab хоста после переключения убирается (cutover-1.0.md), иначе обход
  # пойдёт дважды.
  zhk-registry:
    image: ${REGISTRY:-ghcr.io/nick4man}/victory-zhk-registry:${ZHK_TAG:-${VICTORY_TAG:-1.0.0}}
    build:
      context: ./services/zhk-registry
    restart: unless-stopped
    env_file:
      - .env.zhk
    depends_on:
      web:
        condition: service_healthy
```

- [ ] **Step 5: Пометить старый путь и обновить манифест**

В `services/zhk-registry/crontab.example` первой строкой:

```
# ⚠️ С релиза 1.0 обход идёт в контейнере zhk-registry (crontab.docker). Эта
# форма — для хоста без docker; на прод-хосте строку из crontab -e УБРАТЬ.
```

В `SERVICE.md` строку `deploy:` заменить на:

```
deploy: compose-служба zhk-registry в корневом docker-compose.yml (образ victory-zhk-registry, supercronic по crontab.docker)
```

- [ ] **Step 6: Собрать и проверить**

```bash
cd /home/q/victory-release
/usr/bin/docker build -t victory-zhk-registry:check services/zhk-registry
/usr/bin/docker run --rm victory-zhk-registry:check supercronic -test /opt/zhk-registry/crontab.docker
python3 bin/services-check
cp .env.example .env.compose-check; touch .env.zhk
/usr/bin/docker compose --env-file .env.compose-check config --services | sort | tr '\n' ' '; echo
rm .env.compose-check
```

Expected: в сборке `OK` от unittest; `crontab is valid`; services-check зелёный; список служб: `db redis sidekiq web zhk-registry`.

- [ ] **Step 7: Проверка против живого стека — выполняется в задаче 7, шаг 7**

Команда, которой задача 7 убедится, что `Host: web` проходит и вебхук отвечает контроллером, а не блокировкой хоста:

```bash
/usr/bin/docker run --rm --network victory-rc_default curlimages/curl:8.10.1 \
  -s -o /dev/null -w '%{http_code} %{content_type}\n' -X POST http://web:3000/webhooks/zhk_ingest
```

Expected (в задаче 7): код `401` или `403` с `content_type` `application/json…`; `403 text/html` = «Blocked host».

- [ ] **Step 8: Коммит**

```bash
git add services/zhk-registry/Dockerfile services/zhk-registry/crontab.docker \
        services/zhk-registry/SERVICE.md services/zhk-registry/crontab.example \
        .env.zhk.example docker-compose.yml
git commit -m "release 1.0: реестр ЖК как служба zhk-registry в compose

Образ python:3.12 + supercronic, тесты в сборке, вебхук на http://web:3000.
Крон-строка хоста помечена к удалению при переключении.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: `bin/release`, `bin/rollout`, `bin/smoke`, runbook релиза

**Files:**
- Create: `bin/release`, `bin/rollout`, `bin/smoke`
- Create: `docs/runbooks/release.md`
- Modify: `bin/deploy` (шапка: устарел), `services/README.md`, `.gitignore` (`.env.rc`, `.env.deploy`)
- Test: `bash -n`, `shellcheck` (если есть), `bin/release --check`, `bin/smoke` против текущего прода (только GET)

**Interfaces:**
- Consumes: `VERSION`, имена образов и переменные тегов из задачи 3, `bin/prod-mark` (есть), `bin/backup` (есть).
- Produces: `bin/release [--push] [--check]` → теги `<VERSION>` и `sha-<7>` на `victory-web`, `victory-conveyor`, `victory-zhk-registry`; `bin/rollout <тег> [--yes] [--services a,b] [--skip-backup]`; `bin/smoke <base_url> [admin_token]` с кодом возврата 0/1; файл `.env.deploy` с `VICTORY_TAG`/`GIT_COMMIT_SHA` рядом с боевым `.env`.

- [ ] **Step 1: `bin/release`**

```bash
#!/usr/bin/env bash
# bin/release — собрать образы всех служб и навесить теги релиза.
#
#   bin/release            собрать, тегировать <VERSION> и sha-<7>
#   bin/release --push     + push в ${REGISTRY:-ghcr.io/nick4man}
#   bin/release --check    только показать, что будет собрано
#
# Версия — файл VERSION в корне; sha — HEAD текущего чекаута. Собирать из
# чистого дерева на нужном коммите: образ с незакоммиченными правками
# получит тег коммита, в котором их нет.
set -euo pipefail

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
cd "$ROOT"
DOCKER="${DOCKER_BIN:-/usr/bin/docker}"
REGISTRY="${REGISTRY:-ghcr.io/nick4man}"
VERSION=$(tr -d '[:space:]' < VERSION)
SHA=$(git rev-parse --short=7 HEAD)
PUSH=0; CHECK=0
for a in "$@"; do case "$a" in --push) PUSH=1;; --check) CHECK=1;; *) echo "неизвестный флаг $a" >&2; exit 2;; esac; done

[ -z "$(git status --porcelain)" ] || { echo "дерево не чистое — закоммить или отложить правки" >&2; exit 2; }

# служба compose → имя образа
declare -A IMAGES=(
  [web]=victory-web
  [conveyor]=victory-conveyor
  [zhk-registry]=victory-zhk-registry
)

echo "релиз $VERSION (sha-$SHA) → $REGISTRY"
for svc in "${!IMAGES[@]}"; do
  echo "  $svc → $REGISTRY/${IMAGES[$svc]}:{$VERSION,sha-$SHA}"
done
[ "$CHECK" = 1 ] && exit 0

# Пустые env-файлы служб нужны compose'у даже для build (env_file обязан существовать).
touch .env.conveyor .env.zhk
export VICTORY_TAG="$VERSION" GIT_COMMIT_SHA="$SHA"
# --profile conveyor: иначе compose не видит службу под профилем и не соберёт её.
"$DOCKER" compose --profile conveyor build --pull web conveyor zhk-registry

for svc in "${!IMAGES[@]}"; do
  img="$REGISTRY/${IMAGES[$svc]}"
  "$DOCKER" tag "$img:$VERSION" "$img:sha-$SHA"
  if [ "$PUSH" = 1 ]; then
    "$DOCKER" push "$img:$VERSION"
    "$DOCKER" push "$img:sha-$SHA"
  fi
done
echo "готово: $VERSION / sha-$SHA$([ "$PUSH" = 1 ] && echo ', запушено' || echo ', локально')"
```

- [ ] **Step 2: `bin/smoke`**

```bash
#!/usr/bin/env bash
# bin/smoke <base_url> [admin_token] — проверки живого стека, код 0/1.
# Ловит то, что ломается при смене окружения: хосты, https-редирект, ассеты,
# БД, админка, вебхук с неверным токеном, sitemap, robots.
set -uo pipefail
BASE="${1:?usage: bin/smoke <base_url> [admin_token]}"; TOKEN="${2:-}"
BODY=$(mktemp); trap 'rm -f "$BODY"' EXIT
fail=0
check() { # имя, ожидаемый код (regex), url, [curl-опции...]
  local name=$1 want=$2 url=$3; shift 3
  local code
  code=$(curl -s -o "$BODY" -w '%{http_code}' --max-time 20 -H 'X-Forwarded-Proto: https' "$@" "$url")
  if [[ "$code" =~ ^($want)$ ]]; then echo "ok   $code $name"; else echo "FAIL $code $name ($url)"; fail=1; fi
}
check 'health'            200     "$BASE/health"
check 'health/database'   200     "$BASE/health/database"
check 'главная'           200     "$BASE/"
css=$(grep -o '/assets/tailwind-[^"]*\.css' "$BODY" | head -1)
if [ -n "$css" ]; then check 'tailwind css' 200 "$BASE$css"; else echo 'FAIL --- на главной нет /assets/tailwind-*.css'; fail=1; fi
check 'каталог'           200     "$BASE/properties"
check 'sitemap'           200     "$BASE/sitemap.xml"
check 'robots'            200     "$BASE/robots.txt"
check 'вебхук без токена' '401|403' "$BASE/webhooks/zhk_ingest" -X POST -H 'Content-Type: application/json' -d '{}'
if [ -n "$TOKEN" ]; then check 'admin health' 200 "$BASE/admin/health.json?token=$TOKEN"; fi
if [ "$fail" = 0 ]; then echo 'SMOKE OK'; else echo 'SMOKE FAILED'; exit 1; fi
```

- [ ] **Step 3: `bin/rollout`**

Сначала узнать, как `bin/backup` делает дамп только БД: `grep -nE '^\s*(db|database)\)' /home/q/victory-release/bin/backup | head -3`. Ниже используется `bin/backup db`; если подкоманда называется иначе — подставить её.

```bash
#!/usr/bin/env bash
# bin/rollout <тег> [--yes] [--services web,sidekiq] [--skip-backup]
#
# Выкатить образы заданного тега в боевой compose-проект `victory`:
#   1. предполёт — хост victory, .env на месте, образы с тегом доступны (pull,
#      при неудаче — локальная сборка);
#   2. бэкап БД (bin/backup db) — всегда, кроме --skip-backup;
#   3. docker compose up -d — только перечисленные службы (по умолчанию все без
#      профилей); db/redis не трогаются, если их конфиг не менялся;
#   4. health + bin/smoke + sidekiq жив;
#   5. bin/prod-mark — ветка prod и тег deploy/<дата>.
#
# Откат = bin/rollout <предыдущий тег>. Миграции назад не едут — см.
# docs/runbooks/release.md, раздел «Откат».
#
# Тег пишется в .env.deploy (VICTORY_TAG=…), compose читает его через --env-file
# поверх .env: так состояние «что выкачено» лежит в файле рядом со стеком, а не
# в истории shell. Override на службу (WEB_TAG=…) тоже живёт там и сильнее тега
# из аргумента.
set -euo pipefail

TAG="${1:?usage: bin/rollout <тег> [--yes] [--services a,b] [--skip-backup]}"; shift
YES=0; SERVICES=''; SKIP_BACKUP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --yes) YES=1;; --skip-backup) SKIP_BACKUP=1;;
    --services) SERVICES="${2//,/ }"; shift;;
    *) echo "неизвестный флаг $1" >&2; exit 2;;
  esac; shift
done

[ "$(hostname)" = victory ] || { echo "выкатка только на прод-хосте victory (сейчас: $(hostname))" >&2; exit 2; }
PROD_DIR="${VICTORY_PROD_DIR:-/home/q/victory}"
cd "$PROD_DIR"
DOCKER="${DOCKER_BIN:-/usr/bin/docker}"
[ -f .env ] || { echo "нет $PROD_DIR/.env" >&2; exit 2; }
touch .env.deploy .env.zhk .env.conveyor
PREV=$(grep -E '^VICTORY_TAG=' .env.deploy | cut -d= -f2- || true)
compose() { VICTORY_TAG="$TAG" "$DOCKER" compose --env-file .env --env-file .env.deploy "$@"; }

echo "выкатка $TAG (сейчас: ${PREV:-не записано}) в $PROD_DIR, службы: ${SERVICES:-все}"
if [ "$YES" != 1 ]; then read -r -p 'продолжить? [y/N] ' ans; [ "$ans" = y ] || exit 1; fi

# 1. образы
# shellcheck disable=SC2086
compose pull $SERVICES || compose build $SERVICES

# 2. бэкап
[ "$SKIP_BACKUP" = 1 ] || bin/backup db

# 3. up — сохраняем per-service override, переписываем общий тег и sha
{ grep -vE '^(VICTORY_TAG|GIT_COMMIT_SHA)=' .env.deploy || true; } > .env.deploy.new
printf 'VICTORY_TAG=%s\nGIT_COMMIT_SHA=%s\n' "$TAG" "$(git rev-parse --short=7 HEAD)" >> .env.deploy.new
mv .env.deploy.new .env.deploy
# shellcheck disable=SC2086
compose up -d --remove-orphans $SERVICES

# 4. проверки
for i in $(seq 1 30); do
  curl -fsS --max-time 5 http://127.0.0.1:3000/health/database >/dev/null 2>&1 && break
  sleep 3
  [ "$i" = 30 ] && { echo 'health не поднялся за 90 с — docker compose logs web' >&2; exit 1; }
done
ADMIN_TOKEN=$(grep -E '^ADMIN_TOKEN=' .env | cut -d= -f2- || true)
bin/smoke http://127.0.0.1:3000 "$ADMIN_TOKEN"
sleep "${SIDEKIQ_SETTLE:-30}"
compose ps --status running --services | grep -qx sidekiq || { echo 'sidekiq не работает' >&2; exit 1; }

# 5. отметка
bin/prod-mark --force
echo "выкачено $TAG (было: ${PREV:-—})"
```

- [ ] **Step 4: Шапка `bin/deploy` и `.gitignore`**

После первой строки `#!/usr/bin/env bash` в `bin/deploy` вставить:

```bash
# ⚠️ УСТАРЕЛ с релиза 1.0 (05.10.26): прод работает на образах, не на bind-mount.
# Выкатка — bin/rollout <тег>, сборка — bin/release, процедура — docs/runbooks/release.md.
# Этот скрипт оставлен для стека docker-compose.dev.yml (откат) и будет удалён
# вместе с переездом CI (следующий план).
```

В `.gitignore`, раздел «Ignore environment variables»: добавить `.env.rc` и `.env.deploy`.

- [ ] **Step 5: `docs/runbooks/release.md`**

```markdown
# Релиз и выкатка (с 1.0, 05.10.26)

Прод — compose-проект `victory` в `/home/q/victory` на хосте `victory`. Код
живёт в образах, не в чекауте; чекаут нужен ради `docker-compose.yml`, `.env*`,
`storage/` и скриптов `bin/`.

## Собрать релиз

1. На ветке релиза: `printf '1.0.1\n' > VERSION`, коммит, PR в `main`, ревью, merge.
2. На прод-хосте, в чекауте `main` на нужном коммите: `bin/release --push`
   (`--check` — только показать). Образы:
   `ghcr.io/nick4man/victory-{web,conveyor,zhk-registry}:{<версия>,sha-<7>}`.
3. Тег в git: `git tag -a v<версия> -m 'release <версия>' && git -c http.version=HTTP/1.1 push origin v<версия>`.

## Выкатить

`bin/rollout <версия>` — бэкап → pull → `compose up -d` → health → `bin/smoke` → `bin/prod-mark`.
Простой web ≈ 30–60 с (стоп старого контейнера, старт нового, `db:prepare`).

## Обновить одну службу

Общий тег лежит в `.env.deploy` (`VICTORY_TAG`). Override на службу — своя переменная:

| Служба | Переменная | Образ |
|---|---|---|
| web + sidekiq | `WEB_TAG` | victory-web |
| conveyor | `CONVEYOR_TAG` | victory-conveyor |
| zhk-registry | `ZHK_TAG` | victory-zhk-registry |

Пример — выкатить новый реестр ЖК, не трогая сайт:

```bash
echo 'ZHK_TAG=1.0.1' >> .env.deploy
bin/rollout 1.0.0 --services zhk-registry --skip-backup
```

`bin/rollout` принимает общий тег первым аргументом; override из `.env.deploy`
сильнее него и переживает следующие выкатки. Вернуть службу на общий тег —
удалить строку из `.env.deploy`.

## Откат

`bin/rollout <предыдущая версия>`. Теги прошлых релизов — `git tag -l 'v*'` и
`docker image ls ghcr.io/nick4man/victory-web`. Миграции назад не едут: если
релиз менял схему, сначала `docker compose exec web bin/rails db:rollback`
в контейнере нового образа, потом rollout старого. Бэкап перед каждой выкаткой
— `bin/backup`, восстановление — `restore.md`.

## Профили

- `conveyor` — конвейер новостей; включать после появления
  `services/urgent-news-collector/schema/*.sql` и заполненного `.env.conveyor`:
  `docker compose --profile conveyor up -d`.
- `audit` — audit-engine; `.env.audit` с `AUDIT_DB_PASSWORD` обязателен (compose
  его больше не требует сам — проверять руками), стек пока живёт в архиве на хосте chat.
```

- [ ] **Step 6: `services/README.md` — таблица и упаковка**

В таблицу служб добавить строку `| \`zhk-registry/\` | Python | свой, перенос не нужен | — |`, а после раздела «Проверка» — раздел:

```markdown
## Упаковка (с 1.0)

Каждая исполняемая служба — свой образ и своя служба в корневом
`docker-compose.yml`: `conveyor` (профиль `conveyor`), `zhk-registry`,
audit-engine через `include:` под профилем `audit`. Расписание — `crontab.docker`
внутри образа (supercronic), а не crontab хоста. `chat-host-cron` образом не
становится: его единственный файл подключается в `conveyor` томом (контракт
`MIRROR_SCRIPT`). Как обновить одну службу — `docs/runbooks/release.md`.
```

- [ ] **Step 7: Проверить скрипты**

```bash
cd /home/q/victory-release
chmod +x bin/release bin/rollout bin/smoke
bash -n bin/release && bash -n bin/rollout && bash -n bin/smoke && echo SYNTAX_OK
command -v shellcheck >/dev/null && shellcheck bin/release bin/rollout bin/smoke || echo 'shellcheck нет — пропущено'
bin/release --check
bin/smoke https://victory62.org
git check-ignore .env.rc .env.deploy
```

Expected: `SYNTAX_OK`; `bin/release --check` печатает три строки образов с `1.0.0` и текущим sha; `bin/smoke` против живого сайта: `health`, `главная`, `каталог`, `sitemap`, `robots`, `вебхук без токена` — `ok`; `tailwind css` на сегодняшнем dev-проде **может** быть `FAIL` (в development ассеты отдаются другим путём) — ожидаемо, записывается в результат задачи; на RC-стеке (задача 7) обязан быть `ok`. `check-ignore` печатает оба имени.

- [ ] **Step 8: Коммит**

```bash
git add bin/release bin/rollout bin/smoke bin/deploy docs/runbooks/release.md services/README.md .gitignore
git commit -m "release 1.0: bin/release, bin/rollout, bin/smoke и runbook релиза

release собирает и тегирует образы (<версия>, sha-<7>), rollout выкатывает
тег в проект victory с бэкапом, health, smoke и prod-mark; smoke — 9 проверок.
bin/deploy помечен устаревшим.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: Контрольный стек `victory-rc` на том же хосте

Проверяет production-режим на копии боевой базы до того, как трогать прод. Выполняется на хосте `victory` из `/home/q/victory-release`, **не** из `/home/q/victory`.

**Files:**
- Create (вне git): `.env.rc`
- Create: `docs/runbooks/cutover-1.0.md` (раздел «Прогон RC»; процедура — задача 8)
- Test: `bin/smoke http://127.0.0.1:3001`

**Interfaces:**
- Consumes: всё из задач 1–6.
- Produces: подтверждение, что production-образ работает на реальных данных; список проблем для задач 8 и 10.

- [ ] **Step 1: Свежий дамп прод-базы**

```bash
cd /home/q/victory && bin/backup db
grep -nE 'BACKUP_ROOT=|^\s*log .*дамп' /home/q/victory/bin/backup | head -3
```

`bin/backup` печатает путь к дампу — записать его в переменную `DUMP` текущей shell-сессии.

- [ ] **Step 2: `.env.rc` — копия боевого `.env` с переопределениями**

Боевой `.env` не читать в чат. Собрать файл командами, которые не выводят значения:

```bash
cd /home/q/victory-release
cp /home/q/victory/.env .env.rc
sed -i -E 's/^RAILS_ENV=.*/RAILS_ENV=production/' .env.rc
cat >> .env.rc <<'EOF'

# --- RC override (контрольный стек, не прод) ---
WEB_PORT=3001
WEB_BIND=127.0.0.1
DISABLE_SSL=true
STORAGE_DIR=/home/q/victory-rc-storage
SENTRY_DSN=
VICTORY_TAG=1.0.0
EOF
mkdir -p /home/q/victory-rc-storage
cp .env.zhk.example .env.zhk
grep -E '^(DATABASE_NAME|POSTGRES_DB)=' .env.rc
grep -oE '^(TELEGRAM_[A-Z_]*ENABLED|TOPNLAB_SYNC_ENABLED|SMTP_ADDRESS|TOPNLAB_API_KEY|TELEGRAM_BOT_TOKEN)=' .env.rc
```

Expected: `DATABASE_NAME=viktory_realty_development` (имя БД — не секрет; Review Focus #4). Если другое — `sed -i -E 's/^DATABASE_NAME=.*/DATABASE_NAME=viktory_realty_development/' .env.rc` и записать ту же правку для боевого `.env` в предусловия `cutover-1.0.md`.

⚠️ RC-sidekiq с боевым `.env` **будет выполнять боевые джобы**: Topnlab sync, Telegram, письма. По второму `grep` решить, какие исходящие каналы выключаются в `.env.rc` до старта (обнулить `TOPNLAB_API_KEY=`, `TELEGRAM_BOT_TOKEN=not-a-token`, `SMTP_ADDRESS=smtp.invalid`): записать список в `cutover-1.0.md`, раздел «Прогон RC». Sidekiq в RC поднимается только на шаге 8 и сразу гасится.

- [ ] **Step 3: Собрать образы и поднять базу RC**

```bash
cd /home/q/victory-release
export GIT_COMMIT_SHA=$(git rev-parse --short=7 HEAD)
touch .env.conveyor
/usr/bin/docker compose -p victory-rc --env-file .env.rc build web zhk-registry
/usr/bin/docker compose -p victory-rc --env-file .env.rc up -d db redis
/usr/bin/docker compose -p victory-rc --env-file .env.rc exec -T db sh -c 'until pg_isready -U "$POSTGRES_USER"; do sleep 1; done'
```

Восстановить дамп (формат `pg_dump -Fc`, как делает `bin/backup`):

```bash
/usr/bin/docker compose -p victory-rc --env-file .env.rc exec -T db sh -c \
  'pg_restore -U "$POSTGRES_USER" -d viktory_realty_development --no-owner --no-privileges' < "$DUMP"
/usr/bin/docker compose -p victory-rc --env-file .env.rc exec -T db sh -c \
  'psql -U "$POSTGRES_USER" -d viktory_realty_development -Atc "select count(*) from properties"'
```

Expected: число объектов > 100 (сейчас 118). Если дамп — plain SQL (`.sql.gz`), вместо `pg_restore …` — `gunzip -c "$DUMP" | docker compose … exec -T db sh -c 'psql -U "$POSTGRES_USER" -d viktory_realty_development'`. Если базы `viktory_realty_development` в RC-контейнере нет (её создаёт `POSTGRES_DB` из `.env.rc`) — создать: `createdb -U "$POSTGRES_USER" viktory_realty_development`.

- [ ] **Step 4: Поднять web RC**

```bash
/usr/bin/docker compose -p victory-rc --env-file .env.rc up -d web
/usr/bin/docker compose -p victory-rc --env-file .env.rc logs web 2>&1 | grep -E 'Puma started|Created database|NoDatabaseError|PendingMigration|Blocked host|Error' | head
```

Expected: `Puma started. Environment: production`; **нет** `Created database` (Review Focus #4: если есть — стек поднялся на пустой базе: `down -v`, исправить `DATABASE_NAME`, повторить с шага 3), нет `NoDatabaseError`, нет `PendingMigrationError`.

- [ ] **Step 5: Smoke**

```bash
ADMIN_TOKEN=$(grep -E '^ADMIN_TOKEN=' .env.rc | cut -d= -f2-)
bin/smoke http://127.0.0.1:3001 "$ADMIN_TOKEN"
curl -s -H 'X-Forwarded-Proto: https' http://127.0.0.1:3001/ | grep -c 'tailwind-'
```

Expected: `SMOKE OK`, все 9 строк `ok`, включая `tailwind css` и `admin health`; счётчик ≥ 1.

- [ ] **Step 6: Карточка объекта и время старта**

```bash
slug=$(/usr/bin/docker compose -p victory-rc --env-file .env.rc exec -T db sh -c \
  'psql -U "$POSTGRES_USER" -d viktory_realty_development -Atc "select slug from properties where deleted_at is null and slug is not null limit 1"')
curl -s -o /dev/null -w '%{http_code}\n' -H 'X-Forwarded-Proto: https' "http://127.0.0.1:3001/properties/$slug"
/usr/bin/docker compose -p victory-rc --env-file .env.rc ps web --format '{{.Status}}'
```

Expected: `200`; статус `Up … (healthy)`. Если колонка называется иначе (`friendly_id`) — взять `id` и путь `/properties/<id>`.

- [ ] **Step 7: Проверка хостов из docker-сети и zhk-registry в DRY_RUN (Review Focus #2)**

```bash
/usr/bin/docker run --rm --network victory-rc_default curlimages/curl:8.10.1 \
  -s -o /dev/null -w '%{http_code} %{content_type}\n' -X POST http://web:3000/webhooks/zhk_ingest
/usr/bin/docker compose -p victory-rc --env-file .env.rc run --rm \
  -e VICTORY_BASE_URL=http://web:3000 -e DRY_RUN=1 -e ZHK_INGEST_TOKEN=x zhk-registry \
  python3 run.py 2>&1 | tail -5
```

Expected: `401 application/json…` или `403 application/json…` (ответ контроллера; `403 text/html` = «Blocked host», `RAILS_EXTRA_HOSTS` не доехал); второй вывод содержит `DRY_RUN` и сводку по источникам без traceback.

- [ ] **Step 8: Sidekiq — короткий старт**

```bash
/usr/bin/docker compose -p victory-rc --env-file .env.rc up -d sidekiq
sleep 40
/usr/bin/docker compose -p victory-rc --env-file .env.rc logs sidekiq 2>&1 | grep -E 'Booted|Sidekiq [0-9]|Error' | head -5
/usr/bin/docker compose -p victory-rc --env-file .env.rc exec -T web bin/rails runner 'puts Sidekiq::Cron::Job.count'
/usr/bin/docker compose -p victory-rc --env-file .env.rc stop sidekiq
```

Expected: `Booted Rails 8.1… in production`, без `Error`; `22` задач; sidekiq остановлен.

- [ ] **Step 9: Записать результат и погасить RC**

Создать `docs/runbooks/cutover-1.0.md` с разделом:

```markdown
## Прогон RC — <dd.MM.yy HH:MM>

- образ: victory-web sha-<7>, `.env.rc` от боевого `.env` + override (WEB_PORT=3001, DISABLE_SSL, STORAGE_DIR, SENTRY_DSN пуст)
- выключено в .env.rc для RC: <список ключей>
- bin/smoke: <9/9 ok | что FAIL и как починено>
- карточка объекта: 200; web healthy через <N> с
- Host: web → <код content_type>; zhk-registry DRY_RUN: <ok | что не так>
- sidekiq: booted, 22 cron-задачи
- найдено и исправлено: <список или «ничего»>
```

Затем:

```bash
/usr/bin/docker compose -p victory-rc --env-file .env.rc down
# тома RC оставить до переключения (быстрый повторный прогон); удалить после задачи 10:
#   docker compose -p victory-rc --env-file .env.rc down -v && rm -rf /home/q/victory-rc-storage
```

- [ ] **Step 10: Коммит**

```bash
git add docs/runbooks/cutover-1.0.md
git commit -m "release 1.0: прогон контрольного стека victory-rc — результат в cutover-1.0.md

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: Runbook переключения и документация репозитория

**Files:**
- Modify: `docs/runbooks/cutover-1.0.md` (процедура над разделом «Прогон RC»)
- Modify: `CLAUDE.md`, `.claude/memory/techContext.md`, `.claude/memory/activeContext.md`
- Modify: `.github/workflows/claude.yml` (строка 73 — системный промпт)
- Test: проверка ссылок на файлы

**Interfaces:**
- Consumes: результаты задачи 7.
- Produces: процедура, которую выполняет задача 10; документация, по которой работают агенты после 1.0.

- [ ] **Step 1: `docs/runbooks/cutover-1.0.md` — процедура**

Над разделом «Прогон RC» вставить:

```markdown
# Переключение прода на релиз 1.0 (production-образы)

Хост `victory`, каталог `/home/q/victory` (main checkout, он же compose-проект
`victory`). Простой ≈ 1 мин. Выполнять в тихое время (ночь MSK). Topnlab sync
идёт каждые 30 мин — начать сразу после очередного:
`docker compose logs --since 30m sidekiq | grep TopnlabSyncJob | tail -1`.

## Предусловия

- [ ] PR ветки `claude/release-1.0` слит в `main`, CI зелёный, `/code-review` пройдено.
- [ ] Прогон RC из этого файла — `SMOKE OK`, не старше 3 дней.
- [ ] `git -C /home/q/victory status` чистый; после `git pull --ff-only` чекаут на релизном коммите.
- [ ] `.env` в `/home/q/victory`: `DATABASE_NAME=viktory_realty_development`
      (`grep -E '^DATABASE_NAME=' .env`), `ADMIN_TOKEN` и `SECRET_KEY_BASE` присутствуют
      (`grep -cE '^(ADMIN_TOKEN|SECRET_KEY_BASE)=' .env` → 2).
- [ ] `.env.zhk` создан из `.env.zhk.example`, `ZHK_INGEST_TOKEN` равен значению в `.env`
      (сравнить без вывода: `diff <(grep -oE '^ZHK_INGEST_TOKEN=.*' .env | cut -d= -f2-) <(grep -oE '^ZHK_INGEST_TOKEN=.*' .env.zhk | cut -d= -f2-) && echo same`).
- [ ] Образы собраны: `bin/release --check` показывает 1.0.0 и sha релизного коммита;
      `docker image ls ghcr.io/nick4man/victory-web` содержит `1.0.0`.
- [ ] Свежий бэкап: `bin/backup` (БД + секреты) — не старше часа.

## Переключение

1. Точек невозврата нет: всё ниже откатывается командами из раздела «Откат».
2. Остановить старые web и sidekiq (освобождает :3000) — сайт недоступен с этого момента:
   `docker compose stop web sidekiq`
3. Выкатить: `bin/rollout 1.0.0 --yes --skip-backup` (бэкап сделан в предусловиях).
   Скрипт ждёт health, гонит `bin/smoke`, проверяет sidekiq, ставит `bin/prod-mark`.
4. Снаружи: `curl -sI https://victory62.org | head -1` → `200`; открыть главную и
   карточку объекта в браузере — стили на месте.
5. Логи 5 минут: `docker compose logs -f --since 5m web sidekiq` — без `Blocked host`, без 500.
6. Убрать крон реестра ЖК с хоста: `crontab -l > ~/crontab.bak.$(date +%d.%m.%y) && crontab -l | grep -v zhk-registry | crontab -`;
   проверить `crontab -l | grep -c zhk` → `0`.
7. Контейнер `zhk-registry` жив: `docker compose ps zhk-registry` → `running`.
8. Тег релиза: `git tag -a v1.0.0 -m 'release 1.0.0: production-образы, единый compose' && git -c http.version=HTTP/1.1 push origin v1.0.0`.

## Откат (к стеку до 1.0)

```bash
cd /home/q/victory
docker compose stop web sidekiq zhk-registry
docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d web sidekiq
curl -fsS http://127.0.0.1:3000/health/database
```

Данные не трогались (тома и `storage/` общие), миграций в 1.0 нет — откат без
восстановления БД. Крон реестра вернуть строкой из `services/zhk-registry/crontab.example`
(из `~/crontab.bak.<дата>`).

## После

- Через сутки: `docker compose ps` — все `healthy`; `docker compose logs --since 24h sidekiq | grep -ci error`.
- Снести RC: `docker compose -p victory-rc --env-file /home/q/victory-release/.env.rc down -v; rm -rf /home/q/victory-rc-storage`.
- Следующий план: CI на ветке `dev`, dev-машина, `WEB_BIND` на внутренний интерфейс, переименование БД, Kamal.
```

- [ ] **Step 2: `CLAUDE.md`**

1. В шапке после первого абзаца добавить: «С релиза **v1.0.0** (05.10.26) прод работает в `RAILS_ENV=production` на образах `ghcr.io/nick4man/victory-*`; сборка — `bin/release`, выкатка — `bin/rollout <тег>`, процедура — `docs/runbooks/release.md`.»
2. Секция «Branch discipline», пункт `main`: фразу «прод-чекаут (он же main checkout) обновляют руками, и 07.09.26 он отставал на 33 коммита. Процедура — `.claude/memory/techContext.md`, секция «Деплой смены Ruby/Rails»» заменить на «выкатка — `bin/rollout <тег>` после `bin/release` на прод-хосте; `bin/deploy` устарел. Процедура — `docs/runbooks/release.md`».
3. Секция «Параллельные сессии», абзац «🚨 `/opt/.openclaw/victory` = main checkout … уходит на живой сайт»: дописать «**На прод-хосте `victory` с 1.0 это не так**: код живёт в образе, правка чекаута на сайт не попадает до `bin/rollout`. Чекаут остаётся местом compose-файла, `.env*`, `storage/` и скриптов — писать туда всё равно нельзя.»
4. Таблица `services/`: строка `| \`zhk-registry/\` | Python, еженедельный обход новостроек → \`POST /webhooks/zhk_ingest\` | свой |`. В секцию «Планировщик один» — абзац: «Python-службы с 1.0 идут по `crontab.docker` внутри своих контейнеров (supercronic); crontab хоста для них больше не используется.»

- [ ] **Step 3: `.claude/memory/activeContext.md` и `techContext.md`**

- `activeContext.md:16`: `main = прод, деплой автоматический` → `main = прод; выкатка ручная: bin/release → bin/rollout <тег> (с v1.0.0, 05.10.26)`.
- `techContext.md`: в таблице стека `Puma 6.x` → `Puma 7.2`; `Scheduling | Whenever (cron)` → `Scheduling | sidekiq-cron (config/sidekiq_cron.yml) + supercronic в контейнерах служб`; перед секцией `### Обычный деплой — bin/deploy` вставить `### Релиз и выкатка (с 1.0) — см. docs/runbooks/release.md`, а саму секцию озаглавить `### Обычный деплой — bin/deploy (устарел с 1.0)`.

- [ ] **Step 4: `.github/workflows/claude.yml`**

В строке 73: `main — это прод с автодеплоем:` → `main — это прод, выкатка ручная (bin/rollout):`. По памяти проекта workflow действует только после мержа в `main` — правка едет тем же PR.

- [ ] **Step 5: Проверить ссылки в документах**

```bash
cd /home/q/victory-release
for f in docs/runbooks/release.md docs/runbooks/cutover-1.0.md CLAUDE.md; do
  grep -oE '(docs/[a-zA-Z0-9_./-]+\.md|bin/[a-z-]+|services/[a-z-]+/[A-Za-z.]+)' "$f" | sort -u | while read -r p; do [ -e "$p" ] || echo "$f → нет файла $p"; done
done
```

Expected: пустой вывод (кроме `docs/specs/...` до задачи 9 — её файл появится следующей задачей).

- [ ] **Step 6: Коммит**

```bash
git add docs/runbooks/cutover-1.0.md CLAUDE.md .claude/memory/activeContext.md .claude/memory/techContext.md .github/workflows/claude.yml
git commit -m "release 1.0: runbook переключения и документация под образы

cutover-1.0.md — предусловия, переключение, откат. CLAUDE.md/techContext/
activeContext/claude.yml: деплой ручной через bin/rollout, prod на образах,
противоречие «автодеплой» убрано.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 9: Спека для агентов openclaw-машины — службы в тестовом режиме

**Files:**
- Create: `docs/specs/2026-10-05-openclaw-services-test-mode.md`
- Test: `services-check`; в спеке нет присвоений токенам

**Interfaces:**
- Produces: документ, который openclaw-сессия читает из `main` (там sparse-checkout — в спеке сказано, что добавить). Ответные артефакты: PR с `services/urgent-news-collector/schema/*.sql` и `services/urgent-news-collector/CONSUMERS.md`.

- [ ] **Step 1: Написать спеку**

```markdown
# Службы на openclaw-машине после релиза 1.0: тестовый режим до отключения

Дата: 05.10.26. Адресат: сессии Claude Code на openclaw-машине (main checkout
`/opt/.openclaw/victory`, worktree `victory-urgent-collector`). Исполнять там;
Ruby на той машине нет и не нужен.

## Что произошло

Релиз `v1.0.0` собрал все службы репозитория в один `docker-compose.yml` на
прод-хосте `victory`. Конвейер новостей (`services/urgent-news-collector`) там
теперь есть как контейнер `conveyor`, **но выключен** (профиль `conveyor`):
его две БД — `urgent_events` (pgvector) и `posts_queue`/`system_flags` — живут
только на вашей машине, их схемы в репозитории нет, а потребитель `posts_queue`
(постер в Telegram) в репозиторий не входит вовсе.

## Что НЕ делать

- Не останавливать и не менять crontab `/opt/victory-conveyor` — конвейер
  остаётся боевым публикатором новостей на сайт и в канал, пока владелец
  (q) не скажет «глушим». Это и есть «тестовый режим»: работает, как работал,
  но считается временным.
- Не менять `VICTORY_NEWS_URL`/`VICTORY_NEWS_TOKEN`: зеркало на сайт идёт в
  прод-вебхук, он идемпотентен по `event_id`.
- Не писать в `/opt/.openclaw/.openclaw/**` (архив, решение 11.09.26).

## Что сделать (PR в main, ветка `claude/conveyor-schema`)

1. `git sparse-checkout add docs services/chat-host-cron` — чтобы видеть эту спеку и скрипт зеркала.
2. Снять схемы обеих БД **без данных и без владельцев** и положить в
   `services/urgent-news-collector/schema/`:
   ```bash
   pg_dump --schema-only --no-owner --no-privileges -h <NEWS_DB_HOST> -p <NEWS_DB_PORT> -U <NEWS_DB_USER> <NEWS_DB_NAME> \
     -t urgent_events > services/urgent-news-collector/schema/10-urgent_events.sql
   pg_dump --schema-only --no-owner --no-privileges -h <DB_HOST> -U <DB_USER> <DB_NAME> \
     -t posts_queue -t system_flags > services/urgent-news-collector/schema/20-posts_queue.sql
   ```
   Первой строкой каждого файла добавить `CREATE EXTENSION IF NOT EXISTS vector;`
   (контейнер `news-db` собран из `Dockerfile.postgres`, расширение есть).
   В файлах не должно быть паролей, `ALTER … OWNER TO`, `\connect`. Проверка:
   `grep -niE 'password|owner to|\\connect' services/urgent-news-collector/schema/*.sql` — пусто.
3. Написать `services/urgent-news-collector/CONSUMERS.md`: кто читает
   `posts_queue` и `system_flags` (путь скрипта, крон-строка, какой бот
   публикует, в какой канал), кто ещё пишет в `urgent_events`. Без токенов.
4. Перечислить **имена** переменных из `/opt/victory-conveyor/.env`
   (`sed 's/=.*/=/' /opt/victory-conveyor/.env`) и сверить с
   `.env.conveyor.example` в корне репозитория: чего там не хватает —
   добавить в example тем же PR, с комментарием, зачем ключ.
5. Записать текущие размеры: `select count(*) from urgent_events`,
   `select count(*) from posts_queue` — в `CONSUMERS.md`, с датой. Нужно,
   чтобы при переезде данных понимать, всё ли переехало.
6. Открыть PR, запросить ревью (`/code-review`), в описании сослаться на эту спеку.

## Что будет дальше (делает хост victory, не вы)

- Заполнение `.env.conveyor` значениями из вашего `.env` — владелец передаёт их
  вне git.
- `docker compose --profile conveyor up -d` на `victory`; первый прогон с
  пустым `VICTORY_NEWS_TOKEN`: зеркало пишет `VICTORY_NEWS_TOKEN not set; skipping`,
  посты в `posts_queue` идут в **свою** `news-db`, а не в вашу — дублей в канале не будет.
- Перенос данных `urgent_events` (дедупликация по заголовкам зависит от истории)
  — `pg_dump --data-only`, отдельной задачей.
- Команда «глушим»: вы комментируете строки crontab (сначала
  `crontab -l > ~/crontab.bak.<dd.MM.yy>`), файлы в `/opt/victory-conveyor` не трогаете.
  Потребитель `posts_queue` — отдельное решение после `CONSUMERS.md`.

## audit-engine

Живой контейнер `audit-v2-api` поднят из архива на хосте `chat` (`VENDOR.md`).
В compose 1.0 он есть под профилем `audit` и выключен. От вас — ничего; срок
репатриации `31.03.27` в `SERVICE.md` остаётся.
```

- [ ] **Step 2: Проверить**

```bash
cd /home/q/victory-release
python3 bin/services-check
grep -cE '[A-Z_]*TOKEN=[^<]' docs/specs/2026-10-05-openclaw-services-test-mode.md
```

Expected: services-check зелёный; `0`.

- [ ] **Step 3: Коммит**

```bash
git add docs/specs/2026-10-05-openclaw-services-test-mode.md
git commit -m "release 1.0: спека для openclaw — конвейер в тестовом режиме, схема БД в PR

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

- [ ] **Step 4: Передать спеку openclaw-сессии (после мержа PR)**

`bin/claude-inbox send victory-urgent-collector "Прочитай docs/specs/2026-10-05-openclaw-services-test-mode.md в origin/main и выполни раздел «Что сделать»"` (точный синтаксис — `bin/claude-inbox --help`).

---

### Task 10: PR, ревью, сборка релиза, переключение

Ручные шаги с проверкой на каждом; выполняет сессия на хосте `victory` **в присутствии владельца**.

**Files:** новых нет; выполняется `docs/runbooks/cutover-1.0.md`.

- [ ] **Step 1: PR и ревью**

```bash
cd /home/q/victory-release
git -c http.version=HTTP/1.1 push -u origin claude/release-1.0
gh pr create --base main --title 'release 1.0: единый compose, production-образы, снимок состояния' --body "$(cat <<'EOF'
Релиз-снимок `v1.0.0` без функциональных изменений: multi-stage Dockerfile (dev/prod),
единый docker-compose.yml на образах ghcr.io/nick4man/victory-*, службы conveyor
(профиль) и zhk-registry, bin/release / bin/rollout / bin/smoke, runbook'и, спека
для openclaw. План: docs/superpowers/plans/2026-10-05-release-1-0-compose.md.
Прогон контрольного стека — docs/runbooks/cutover-1.0.md.

Намеренные решения — раздел «Решения, принятые в плане» (Р1–Р10).

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
gh pr checks --watch
```

Expected: 11 проверок зелёные. Затем `/code-review <PR#> high`, правки по находкам, merge.

- [ ] **Step 2: Предусловия из `cutover-1.0.md`**

Пройти чеклист «Предусловия» целиком. Отдельно — Review Focus #4:

```bash
cd /home/q/victory && git pull --ff-only && grep -E '^DATABASE_NAME=' .env
```

Expected: `DATABASE_NAME=viktory_realty_development`. Иначе — исправить в `.env` до шага 4.

- [ ] **Step 3: Собрать релиз на релизном коммите**

```bash
cd /home/q/victory && bin/release --check && bin/release --push
```

Если `docker push` падает с `denied` — `docker login ghcr.io -u nick4man` с PAT `write:packages` (значение вводится интерактивно, в чат не попадает), либо продолжить без push: `bin/rollout` при неудачном `pull` соберёт образы локально (так заложено).

- [ ] **Step 4: Переключение**

Выполнить раздел «Переключение» из `cutover-1.0.md`, шаги 2–8, по одному, фиксируя время каждого.

- [ ] **Step 5: Внешняя проверка**

```bash
bin/smoke https://victory62.org "$(grep -E '^ADMIN_TOKEN=' /home/q/victory/.env | cut -d= -f2-)"
curl -s https://victory62.org/ | grep -c 'tailwind-'
```

Expected: `SMOKE OK`; счётчик ≥ 1.

- [ ] **Step 6: Расписание без дублей (Review Focus #5)**

```bash
crontab -l | grep -c 'zhk-registry'
/usr/bin/docker compose -p victory ps --services --status running | sort | tr '\n' ' '; echo
```

Expected: `0`; `db redis sidekiq web zhk-registry` (без `conveyor`, без `audit-*`).

- [ ] **Step 7: Тег и отметка**

`bin/rollout` уже вызвал `bin/prod-mark`; остаётся `git tag -a v1.0.0 …` из runbook'а (шаг 8). Проверка: `git ls-remote --tags origin | grep -c 'v1.0.0'` → `1`.

- [ ] **Step 8: Закрыть план**

Дописать в `docs/runbooks/cutover-1.0.md` раздел «Выполнено <dd.MM.yy HH:MM>» с длительностью простоя и найденными проблемами; обновить `.claude/memory/activeContext.md` («в проде v1.0.0, production-образы»); отправить спеку openclaw (задача 9, шаг 4). Это отдельный маленький PR `claude/post-release-1.0-notes`.

---

## Self-review

**Покрытие ТЗ.** «Снимок состояния / зафиксировать релиз» — Р1, задачи 1, 10 (тег `v1.0.0`). «Собрать докер через docker compose, каждая служба отдельно, в том числе новостник» — задачи 2–5 (отдельные образы web/conveyor/zhk-registry, audit через include). «Выкатить production 1.0» — Р2, задачи 7, 10. «Спека для агентов на другой машине, службы продолжают работать в тестовом режиме» — Р5, задача 9. «Продумать модульность, чтобы безболезненно обновлять модули» — per-service теги и `--no-deps`/`--services` в задачах 3 и 6 (`release.md`). «CI/CD с веткой dev, тестовый образ, dev-машина с ограничением по IP, возможный перенос прода на VPS» — **намеренно вне этого плана**: это отдельная подсистема, не дающая работающего софта без релиза 1.0; её решения зафиксированы как совместимые (образы с тегом `sha-<7>` уже строятся — CI будет публиковать их же; `WEB_BIND` готов к сужению; `docker-compose.dev.yml` — заготовка dev-стека). Следующий план пишется после того, как 1.0 в проде.

**Плейсхолдеры.** `$DUMP`, `<NEWS_DB_HOST>` и подобные — параметры, которые знает только исполнитель на месте и которые нельзя записать в репозиторий (пути к бэкапу, хосты чужой БД); каждый сопровождается командой, как его получить. `SUPERCRONIC_SHA256` вычисляется в задаче 4, шаг 6, и затем пинуется — процедура, не пропуск.

**Согласованность имён.** `RAILS_EXTRA_HOSTS` (задачи 1, 3, 7), `WEB_TAG`/`CONVEYOR_TAG`/`ZHK_TAG`/`VICTORY_TAG` (3, 4, 5, 6), `STORAGE_DIR`/`WEB_BIND`/`WEB_PORT` (3, 7), `.env.deploy` (6, 8, 10), имена служб `web sidekiq db redis zhk-registry conveyor news-db` (3–7, 10), `bin/smoke <base> [token]` (6, 7, 10), `/opt/conveyor/mirror/post_news_to_victory.sh` (4: Dockerfile создаёт `mirror/`, compose монтирует туда, `.env.conveyor.example` указывает `MIRROR_SCRIPT`) — сверены.

**Review Focus.** #1 → задача 1 шаг 2 + задача 2 шаг 6 + `bin/smoke` health с `127.0.0.1`; #2 → задача 5 шаг 7 / задача 7 шаг 7; #3 → задача 2 шаг 5, `bin/smoke` «tailwind css», задача 7 шаг 5; #4 → задача 7 шаги 2, 4 и задача 10 шаг 2; #5 → задача 10 шаг 6 и спека задачи 9.

**Что план не проверяет и говорит об этом честно:** запуск RSpec (Ruby здесь только в контейнере; CI гонит полный прогон на PR — задача 10, шаг 1); реальную работу конвейера в контейнере против живых БД (невозможно до схемы с openclaw); интерфейс, с которого Traefik ходит на хост (Р10).
