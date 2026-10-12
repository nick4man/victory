# AGENTS.md — АН «Виктори» Real Estate Platform

Этот файл — стартовая точка для AI-агентов. Читатель ничего не знает о проекте:
здесь собран минимум, необходимый, чтобы не сломать что-то с первой правкой.
Детали по темам — в memory-bank (см. раздел «Где брать контекст»).

⚠️ Корневые `*.md` (`STATUS.md`, `SUMMARY.md`, `FINAL_REPORT.md`, `CURRENT_STATE.md`,
шесть `DEPLOYMENT*.md`, `ROADMAP.md` и др.) — исторический шум, местами полугодовой
давности. **Источник правды — `.claude/memory/` и этот файл.**

## Обзор проекта

Русскоязычная digital-платформа агентства недвижимости АН «Виктори» (Рязань).
**Production: https://victory62.org.** Публичный сайт, JSON API, админка, два
Telegram-бота, AI-функции (чат-бот сайта, оценка объектов, LLM-цепочки).

Стек:

| Слой | Технология |
|---|---|
| Framework | Rails **8.1.3.1** (`load_defaults` пока 7.1) |
| Язык | Ruby **3.4.10** (пин в `Gemfile`, `.ruby-version`, `mise.toml`, `Dockerfile`) |
| БД | PostgreSQL 15 + **PostGIS 3.6** + **pgvector 0.8.6** (образ `Dockerfile.postgres`) |
| Server | Puma 7.2, порт 3000 в Docker |
| Фон | Sidekiq 7 + sidekiq-cron (`config/sidekiq.yml`, `config/sidekiq_cron.yml`) |
| Frontend | Importmap + Stimulus + Turbo (Hotwire), Tailwind (`tailwindcss-rails`), ERB. Webpack/esbuild нет |
| JS-инструменты | `package.json` — **только dev**: Figma Code Connect и Playwright (визуальные регрессии) |
| Поиск | Ransack + PgSearch (русский словарь) |
| Модуль приложения | `ViktoryRealty` (`config/application.rb`) |
| Локаль / TZ | `ru` / Europe/Moscow |

## Архитектура — большая картина

Rails-монолит. Четыре входа, и только первый — «сайт»:

| Вход | Где | Аутентификация |
|---|---|---|
| Публичный сайт | `landing#index` + `properties`/`news`/`valuations`/`cabinet`, `config/routes.rb` (~891 строка) | нет (Devise выключен) |
| JSON API | `namespace :api { namespace :v1 }` | JWT |
| Админка | `namespace :admin` | query-param `?token=$ADMIN_TOKEN` |
| Вебхуки | `app/controllers/webhooks/` — `topnlab`, `topnlab_reports`, `telegram`, `news_ingest`, `yookassa`, `amocrm`, `zhk_ingest` | у каждого свой секрет из ENV; **при пустом ENV контроллер отказывает, а не пропускает** |

Ключевые инварианты:

- **Каталог объектов не наш.** Источник правды — внешняя CRM Topnlab; `Property` —
  проекция, наполняемая `TopnlabSyncJob` (каждые 30 мин) и соседними sync-джобами.
  При неполном обходе архивация пропускается, иначе каталог схлопывается.
- **Доменная логика — в `app/services/`** (~69 каталогов/файлов: `llm/`, `telegram/`,
  `topnlab/`, `crm/`, `audit_engine/`, `mortgage/`, `property_dossier/`…), не в моделях
  и не в контроллерах. Plain-Ruby класс с `initialize` + `call`. Не путать с
  верхнеуровневым `services/` (см. ниже).
- **Два Telegram-бота из одного Rails**: `app/services/telegram/work_bot/` (сотрудники —
  фактический CRM-канал: команды, задачи, дайджесты, эскалации) и
  `telegram/client_bot/` (клиенты). Общий вход — `Telegram::InboundProcessor`.
  Вебхук Telegram идёт через Cloudflare-релей `tg-webhook-relay/` (обход блокировки
  TG IP на хост-уровне).
- **LLM — free-first цепочка**: `app/services/llm/omni_client.rb`
  (`DEFAULT_CHAINS[:chat]` / `[:analysis]`, платный Sonnet последний). Перестановка
  платной модели вверх по цепочке = деньги, молча. Tool-calling — `app/services/chat_tools/`
  + `Llm::ToolRunner`.
- **Эмбеддинги** — pgvector + gem `neighbor`, таблицы `*_embedding`, наполняются
  `EmbedXxxJob`.
- Гео-запросы — PostGIS (`earth_distance` / `ll_to_earth`) **сырым SQL**, AR-адаптер
  остаётся `postgresql`.

### Планировщик один, и он в репозитории

- **`config/sidekiq_cron.yml`** — ~22 боевые задачи (Topnlab sync, дайджесты, cleanup).
  Время в MSK, зависит от `TZ` контейнера. Единственное расписание, которое едет
  вместе с кодом. Добавляя периодику — сюда.
- Системный crontab хоста — 5 записей (Yandex.Webmaster ×3, `kpi:phase_a`,
  `bin/lock-clean`), правится `crontab -e`, **не** в репозитории.
- 🚨 `config/schedule.rb` удалён 12.09.26 — гема `whenever` в `Gemfile` нет, ни одна
  его строка никогда не выполнялась. Не воскрешать. Часть старых задач
  (`SendViewingRemindersJob`, `UpdatePropertyStatisticsJob`) в текущем виде вредны —
  разбор всех 19 записей в `CLAUDE.md`, секция «Планировщик один».

## Где ты: две машины, Ruby не везде

🚨 **Репозиторий работает с двух хостов, различай их по `hostname`, не по пути**
(`~` и относительные пути одинаковы на обеих):

| Хост (`hostname`) | Ruby | Как гонять |
|---|---|---|
| **`victory`** — прод-хост (здесь живёт сайт, docker, worktree) | только в контейнере, менеджера версий на хосте нет | **только через `bin/rb`**: `bin/rb bundle exec rubocop`, `bin/rb --db bundle exec rspec` |
| **openclaw-машина** (main checkout в `/opt/.openclaw/victory`) | нет вообще — ни ruby, ни bundle, ни контейнеров | никак. Ruby-команды не запускать |

Не отчитывайся «тесты прошли», не прогнав их там, где Ruby есть.

✅ С cutover'а 12.10.26 **живого bind-mount больше нет**: прод-стек работает из
образов GHCR, `/home/q/victory` — ops-каталог (compose, `.env*`, `bin/*`), правки
файлов там на сайт не попадают сами. Источник правды по worktree —
`git worktree list`, не таблицы в доках.

## Команды

На прод-хосте `victory` всё Ruby — через `bin/rb` (контейнер с целевым Ruby):

```bash
bin/rb bundle install
bin/rb --db bundle exec rspec                       # полный прогон (~1100 примеров)
bin/rb --db bundle exec rspec spec/models/property_spec.rb       # файл
bin/rb --db bundle exec rspec spec/models/property_spec.rb:42    # пример
bin/rb bundle exec rubocop --parallel               # + -a safe / -A unsafe
bin/rb bundle exec brakeman --exit-on-warn --quiet --format text
bin/rb bundle exec bundle-audit update && bundle exec bundle-audit check
bin/rb bin/rails db:migrate                         # db:create / db:seed / db:reset
bin/rb bundle exec sidekiq -C config/sidekiq.yml
bin/rb bundle exec rake repo:map                    # регенерация repo-index/repo-map
```

Работает на любой машине (нужен только python3):

```bash
python3 bin/services-check                          # правила служб services/ (джоб в CI)
cd services/urgent-news-collector && python3 -m unittest \
  test_urgent_relevance test_classify_retry test_model_chains -v  # 46 тестов, без сети и БД
```

Визуальные регрессии (Playwright, снапшоты `tests/visual/*-snapshots/` **коммитятся**):

```bash
npm run vr:test      # проверка против базовых (нужен Rails dev-сервер на :3000)
npm run vr:update    # переснять базовые — ревью диффа перед коммитом обязателен
npm run vr:ui        # интерактивный UI
```

Полный список ENV и rake-задач — `.claude/memory/techContext.md` и `lib/tasks/*.rake`
(~31 файл).

## Конвенции кода (3 жёстких правила — не нарушай, не спрашивая)

1. **Soft delete**: колонка `deleted_at` + `default_scope { not_deleted }`. Никакого
   `paranoia`/`discard` gem. Доступ к удалённым — `.unscoped`.
2. **Enums** — всегда с `_prefix: true`; русский перевод значений — в комментарии рядом.
3. **Даты в коде/UI/сообщениях** — европейский `dd.MM.yy`. Не ISO, не US. (Единственное
   из трёх правил, действующее и в Python-сервисах.)

Остальные (полный текст — `.claude/memory/systemPatterns.md`):

- Каждый `.rb` начинается с `# frozen_string_literal: true`; строки — **single quotes**
  (RuboCop-enforced, target Ruby 3.2 намеренно, max line 120, max method 25).
- Service objects возвращают Result-hash (`{ ok:, value:, error: }`) или domain-объект;
  вызов `Service.new(...).call`. Callbacks в моделях минимальны.
- Цены — всегда `record.price_formatted` (строка с `₽`), никаких ручных
  `number_to_currency`. Money — `decimal`, не `float`. Гибкие настройки — `jsonb`.
- Пользовательские строки — `I18n.t()`, default locale `:ru`.
- JSON-ответы контроллеров — `render_success` / `render_error` (консистентный формат).
- JS: Stimulus-конвенции (`static targets`, `connect()`/`disconnect()`), в ERB —
  `data-controller`/`data-action`. Runtime-ассеты — Importmap (`config/importmap.rb`
  нет намеренно — inline-module pattern в `app/views/layouts/application.html.erb`).
- НЕ комментим что делает код; только **почему**, если неочевидно.
- Rails-конвенции НЕ переносятся в Python-сервисы под `services/`.

## Аутентификация — текущее состояние

**Devise отключен.** `current_user` → `nil`, `user_signed_in?` → `false`. Admin-доступ —
query-param `?token=$ADMIN_TOKEN`. Не предполагай, что юзер залогинен. Перед включением
Devise — вернуть gem в Gemfile и пройти ревью.

## Тестирование

- **RSpec** (~1100 примеров): `spec/models`, `spec/services` (основная масса — доменная
  логика живёт в сервисах), `spec/requests` (включая `spec/requests/webhooks/`,
  `spec/requests/admin/`), `spec/jobs`, `spec/mailers`. FactoryBot + Faker (locale `ru`),
  Shoulda Matchers, DatabaseCleaner. Сеть в спеках закрыта **WebMock**, ActiveJob на
  `:test`. Схема тестовой БД требует `postgis` + `vector` + `pg_trgm` + `unaccent`
  (`db/structure.sql`) — поэтому CI и `bin/rb` поднимают свой образ `Dockerfile.postgres`.
- **Playwright visual regression** (`tests/visual/`) — снапшоты коммитятся как
  визуальный контракт; `test-results/` в gitignore.
- **Python**: юнит-тесты `services/urgent-news-collector` (без сети и БД).

### CI и PR-процесс

- **`main` = production. Никаких direct push to main.** Работа — в `dev/<session>` или
  feature-ветках (`claude/<task>`, `test/<smth>`). Путь в прод — только PR → main.
- **CD (с 11.10.26)**: merge в `main` → `build.yml` собирает и пушит образы
  `ghcr.io/nick4man/victory-*:sha-<7>` (тег `<VERSION>` — при изменении файла VERSION)
  и автоматически выкатывает на staging. **Прод не едет сам**: выкатка —
  workflow `Deploy production` (Approve в environment `production`) или
  `bin/rollout <тег>` на прод-хосте (см. «Деплой»).
- На PR приезжают проверки:
  - `.github/workflows/lint.yml` — RuboCop, Brakeman (`--exit-on-warn`), bundler-audit,
    `services-check` (python3), RSpec (свой PostGIS+pgvector образ);
  - `.github/workflows/build.yml` — сборка prod-образа web + `zeitwerk:check` в
    `RAILS_ENV=production` (без push в реестр; службы `services/*` — при изменениях
    их каталогов);
  - CodeQL (`ruby` / `python` / `javascript-typescript` / `actions`) — GitHub code
    scanning default setup, **файла в репозитории нет**;
  - GitGuardian Security Checks — GitHub App.
- `.github/workflows/claude.yml` и `kimi.yml` — боты по `@claude`/`@kimi` в
  issue/PR-комментариях; в PR-проверки **не входят**.
- 🚨 **Code-review на diff — обязательный этап каждого PR.** Порядок: код → CI зелёный →
  ревью → правки → merge. Ревьюеру давать: команду для diff, ссылку на план, список
  намеренных решений, что уже проверено, способ запустить код.
- 🚨 Зависимые слои (миграция → сервис → UI) или diff > ~500 строк / ~10 файлов —
  **стек PR** через `gh stack` (skill `gh-stack`), не один большой PR.
- ⚠️ `git push` по HTTPS в этом окружении виснет по таймауту (300 с). Лечение:
  `git config http.version HTTP/1.1` (один раз на репозиторий) или флаг
  `git -c http.version=HTTP/1.1 push …`.
- Git-метаданные worktree — относительные (`extensions.relativeWorktrees`); **требуется
  git ≥ 2.48** на любой машине, читающей репозиторий (в прод-контейнерах git 2.39.5 —
  git-команды внутри `/app` падают, потребителей там нет).

## `services/` — подсистемы вне Rails

Не путать с `app/services/`. Архитектура — **один репозиторий, много маленьких служб**
(`services/README.md`):

| Служба | Язык | Назначение |
|---|---|---|
| `audit-engine/` | Python (FastAPI) | инвестиционный аудит (sidecar через Faraday+Stoplight); перенос не завершён |
| `urgent-news-collector/` | Python | конвейер новостей: срочные + дайджест + ставки банков; контейнер `conveyor` (профиль `conveyor`), переезд с chat-хоста — cutover B pending |
| `content-publisher/` | Python | Telegram-публикатор очереди новостей (`publisher`, профиль `conveyor`) |
| `zhk-registry/` | Python | реестр ЖК; контейнер в боевом compose, единственный вход — вебхук `/webhooks/zhk_ingest` |
| `chat-host-cron/` | bash | cron-обвязка чат-хоста (скрипт-контракт, монтируется в `conveyor`) |
| `web-comparables/` | текст скилла, кода нет | подбор аналогов |
| `tg-webhook-relay/` (корень, не `services/`) | Cloudflare Worker | релей Telegram-вебхуков → `victory62.org/webhooks/telegram` |

Четыре правила (проверяются `python3 bin/services-check` на каждый PR):

1. у каждого каталога под `services/` есть `SERVICE.md` (манифест живёт внутри службы);
2. владелец всегда `victory`; внешний источник — в `ported_from`, никогда в `owner`;
3. службы не знают друг о друге (`depends_on: none`) — связь только через контракт
   (вебхук, HTTP, формат файла); импорт соседней службы или Rails-кода роняет проверку;
4. незавершённый перенос обязан иметь дату `repatriate_by`.

🚨 **openclaw — архив целиком** (и репозиторий `nick4man/openclaw`, и каталог
`/opt/.openclaw/.openclaw/**` на диске): только чтение. Синк-скрипты отключены
(`sync-check.sh`, `upstream-sync.sh`), запреты продублированы в `.claude/settings.json`
→ `permissions.deny`.

## Безопасность

- Вебхук-контроллеры требуют свой секрет из ENV; **пустой ENV = отказ**, не пропуск.
  Не «чинить» это поведение.
- Admin-доступ — только `?token=$ADMIN_TOKEN`; `require_admin!` / `require_agent!`
  (Pundit отключен, политик нет).
- Sentry подключается только при заданном `SENTRY_DSN`; PII strip через `before_send`
  в `config/initializers/sentry.rb`.
- В `Gemfile` много явных security floor-пинов (rack, nokogiri, jwt, faraday, json, …)
  против CVE в transitive deps — комментарии рядом объясняют почему; не снижать.
- Безопасность гоняется в CI: Brakeman (`--exit-on-warn`), bundler-audit, CodeQL,
  GitGuardian. Локально — те же команды через `bin/rb`.
- LLM cost discipline: free-first цепочка провайдеров, платные модели — только
  last-resort.

## Параллельные сессии и локи

- Правка файла автоматически ставит лок в `tmp/claude-locks/`; попытка тронуть файл,
  занятый другой сессией, отклоняется (`pre-edit-lock.sh`, exit 2). Снятие: коммит,
  TTL 2 ч, `bin/lock-clean --release <путь>`, `CLAUDE_LOCK_BYPASS=1` — разовый обход.
  Занятое: `bin/check-cross-worktree-locks`.
- Полномочия сессий — `.claude/docs/session-authority.md`; межсессионная почта —
  `bin/claude-inbox`; снимок по worktree — `bin/session-status`.
- Мастер-документы в `.claude/plans/_shared/` меняются **только через PR**.
- `PostToolUse`-хук гоняет `rubocop -a` в фоне на каждый изменённый `*.rb` — файл может
  измениться после твоей правки, это не «второй редактор».

## Где брать контекст (memory-bank)

Этот файл — хаб. Содержательное — рядом, читай по теме:

- `.claude/memory/activeContext.md` — текущая ветка, фаза, что в фокусе.
- `.claude/memory/systemPatterns.md` — конвенции кода (полный текст).
- `.claude/memory/techContext.md` — стек, ENV vars, команды, деплой-процедуры, runbook'и.
- `.claude/memory/progress.md` — что в проде, что отключено, tech-debt.
- `.claude/memory/strategicVector.md` — стратегический вектор; решения прогоняй через
  3 пиллара: **frictionless concierge / deep expertise / AI×human**.
- `.claude/repo-index.md` — компактный индекс «файл → классы» (~5k токенов, читай
  первым при навигации); `.claude/repo-map.md` — полный дамп (~190k, on-demand).
  Обновить оба: `bundle exec rake repo:map`.
- `.claude/docs/reglament/` — бизнес-регламенты агентства (источник требований к
  work-bot, Task/SLA, Nextcloud-путям).
- `.claude/docs/delegation-map.md` — routing-таблица домен → агент/скилл
  (`.claude/agents/*.md` — это файлы-инструкции, не значения `subagent_type`).
- `docs/documentation-rules.md` — правила ведения документации (иерархия источников
  правды, куда писать новый документ, стиль, процесс изменения).
- `CLAUDE.md` — исходный хаб проекта (содержит разборы исторических кейсов: удалённый
  schedule.rb, инцидент с тильдой в git-метаданных и т.п.).

## Деплой и инфраструктура (кратко)

- **Код едет в образах** (с релиза 1.0, 11.10.26): `ghcr.io/nick4man/victory-{web,conveyor,publisher,zhk-registry}`,
  теги `sha-<7>` и `<VERSION>`. Сборка — в CI (`build.yml`) на merge в `main`;
  локальный fallback — `bin/release --push`; довесить `<VERSION>` на собранный
  CI sha-образ — `bin/release --from-ci`.
- **Выкатка на прод** (cutover 1.0 выполнен 12.10.26, прод на образах): Actions →
  `Deploy production` → Approve в environment `production` → SSH `bin/prod-gate` →
  `bin/rollout <тег>` на хосте `victory` (бэкап → pull → health → `bin/smoke` →
  `bin/prod-mark` → внешние проверки с раннера). Вручную на хосте — тот же
  `bin/rollout`. Runbook — `docs/runbooks/deploy-pipeline.md`, откат —
  `docs/runbooks/release.md`.
- **Staging**: хост vps1 (`ssh deploy`), compose-проект `victory-staging`
  (`docker-compose.staging.yml`, `RAILS_ENV=staging`, свои тома/БД/storage).
  Автовыкатка из CI: `bin/deploy-gate` (SSH forced command) → `bin/staging-rollout`;
  после — внешний smoke + Playwright из Actions. Данные — `bin/staging-reset`
  из gpg-дампа прода. Runbook — `docs/runbooks/staging.md`.
- Бэкап — `bin/backup` + systemd-таймер (`deploy/systemd/`, конфиг
  `/etc/victory-backup/backup.env`, пример — `config/backup.env.example`).
- Процедуры смены Ruby/Rails, переезда БД на bookworm, restore — в
  `.claude/memory/techContext.md` и `docs/runbooks/`.
