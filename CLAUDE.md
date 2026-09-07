# CLAUDE.md — АН «Виктори» Real Estate Platform

Rails 8.1.3.1 / Ruby 3.3.6 / PostgreSQL 15+ + PostGIS + pgvector. Russian-language real estate platform. **PRODUCTION** at https://victory62.org.

⚠️ Ruby: рантайм **3.3.6** (`Gemfile`, `.ruby-version`). `mise.toml` устарел (заявляет 3.2.2) — не верь ему. `.rubocop.yml` намеренно таргетирует 3.2 как нижнюю границу.

## Где брать контекст (memory-bank)

Этот файл — тонкий хаб. Содержательное — рядом, читай по теме:

- `.claude/memory/activeContext.md` — текущая ветка, фаза, что в фокусе сейчас (обновляется неделями).
- `.claude/memory/systemPatterns.md` — конвенции (enums `_prefix`, soft-delete `deleted_at`, frozen literals, single quotes, dd.MM.yy даты, service-object pattern).
- `.claude/memory/techContext.md` — стек, ENV vars, команды (`rspec`, `rubocop`, миграции, Sidekiq, cron).
- `.claude/memory/progress.md` — что в проде, что отключено (Devise off!), что заглушка, аспирационные роуты, известный tech-debt. ⚠️ Секция tech-debt устарела: спеков **90**, а не 5; rubocop/brakeman/bundler-audit в `Gemfile` уже есть.
- `.claude/repo-index.md` — компактный индекс «файл → классы» (~5k токенов, читай первым).
- `.claude/repo-map.md` — полный сигнатурный дамп (~190k токенов, on-demand для глубокого ныряния).
- Обновить оба: `bundle exec rake repo:map`.

⚠️ Корневые `*.md` (`STATUS.md`, `SUMMARY.md`, `FINAL_REPORT.md`, `CURRENT_STATE.md`, шесть `DEPLOYMENT*.md`, …) — исторический шум, местами полугодовой давности. Источник правды — `.claude/memory/`.

## 3 жёстких правила (не нарушай, не спрашивая)

1. **Soft delete**: `deleted_at` + `default_scope { not_deleted }`. Никакого `paranoia` gem. Доступ к удалённым — `.unscoped`.
2. **Enums** — всегда с `_prefix: true`. Русский перевод значений — в комментарии рядом.
3. **Даты в коде/UI/сообщениях** — европейский `dd.MM.yy`. Не ISO, не US.

## Главное про auth

**Devise отключен**. `current_user` → `nil`, `user_signed_in?` → `false`. Admin-доступ — query-param `?token=$ADMIN_TOKEN`. Не предполагай, что юзер залогинен.

## Архитектура — большая картина

Rails-монолит. Четыре входа, и только первый — «сайт»:

| Вход | Где | Аутентификация |
|---|---|---|
| Публичный сайт | `landing#index` + `properties`/`news`/`valuations`/`cabinet`, ~891 строка `config/routes.rb` | нет (Devise off) |
| JSON API | `namespace :api { namespace :v1 }` | JWT |
| Админка | `namespace :admin` | `?token=$ADMIN_TOKEN` |
| Вебхуки | `app/controllers/webhooks/` — `topnlab`, `telegram`, `news_ingest`, `yookassa`, `amocrm` | у каждого свой секрет из ENV; при пустом ENV контроллер отказывает, а не пропускает |

Что нужно знать до первой правки:

- **Каталог объектов не наш.** Источник правды — внешняя CRM Topnlab; `Property` — проекция, которую наполняют `TopnlabSyncJob` (каждые 30 мин) и соседние sync-джобы. Инвариант: при неполном обходе архивация пропускается, иначе каталог схлопывается.
- **Доменная логика — в `app/services/` (~260 файлов), не в моделях и не в контроллерах.** Plain-Ruby класс с `call`, см. `systemPatterns.md`. Не путать с верхнеуровневым `services/`.
- **Два Telegram-бота из одного Rails**: `telegram/work_bot/` (сотрудники — фактический CRM-канал: команды, задачи, дайджесты, эскалации) и `telegram/client_bot/` (клиенты). Общий вход — `Telegram::InboundProcessor`.
- **LLM — free-first цепочка**, `Llm::OmniClient` (`DEFAULT_CHAINS[:chat]` / `[:analysis]`, платный Sonnet последний). Tool-calling — `app/services/chat_tools/` + `Llm::ToolRunner`. Перестановка модели вверх по цепочке = деньги, молча.
- **Эмбеддинги** — pgvector + gem `neighbor`, таблицы `*_embedding`, наполняются `EmbedXxxJob`.

### Два планировщика, и это не опечатка

| | Что |
|---|---|
| `config/sidekiq_cron.yml` | 22 задачи внутри Sidekiq — **боевое** расписание (Topnlab sync, дайджесты, SLA, cleanup). Время в MSK, зависит от `TZ` контейнера |
| `config/schedule.rb` | whenever → системный crontab, ~17 записей |

Они пересекаются (`RefreshTopnlabStatsJob` объявлен в обоих), а последняя строка `schedule.rb` зашита на `cd /home/q/victory` — путь, которого больше нет. Добавляя периодику, по умолчанию бери `sidekiq_cron.yml` и проверь, нет ли дубля.

## Команды

🚨 **Ruby есть не на каждой машине — сначала пойми, где ты.** Репозиторий работает с двух хостов, и они не похожи:

| Хост | Ruby | Как гонять |
|---|---|---|
| worktree в `/home/q/victory-*` | в контейнере, менеджера версий на хосте нет | **только через `bin/rb`**: `bin/rb bundle exec rubocop`, `bin/rb --db bundle exec rspec` |
| worktree в `/opt/.openclaw/` | нет вообще: ни `ruby`, ни `bundle` в PATH, ни контейнеров, ни rails-образа | никак — Ruby-команды не запускать, `post-edit-rubocop.sh` там молчаливый no-op |

Не отчитывайся «тесты прошли», не прогнав их там, где Ruby есть.

Работает прямо здесь — только Python-сервис:

```bash
cd services/urgent-news-collector && python3 -m unittest test_urgent_relevance -v   # 26 тестов, без сети и БД
```

Остальное — там, где есть Ruby (CI гоняет только первый блок):

```bash
bundle exec rubocop --parallel        # + -a safe / -A unsafe autocorrect
bundle exec brakeman --exit-on-warn --quiet --format text
bundle exec bundle-audit update && bundle exec bundle-audit check

bundle exec rspec                                  # 1102 примера, гоняются и в CI
bundle exec rspec spec/models/property_spec.rb     # один файл
bundle exec rspec spec/models/property_spec.rb:42  # один пример

bin/rails db:migrate                  # db:create / db:seed / db:reset
bundle exec sidekiq -C config/sidekiq.yml
bundle exec rake repo:map             # регенерация repo-index.md + repo-map.md
```

Полный список ENV и rake-задач — `.claude/memory/techContext.md` и `lib/tasks/*.rake` (31 файл).

## `services/` — подсистемы вне Rails

Не путать с `app/services/` (Ruby service objects, ~260 файлов). Верхний уровень:

| Каталог | Язык |
|---|---|
| `audit-engine/` | Python (FastAPI), вендорится извне — см. `VENDOR.md` |
| `chat-host-cron/` | bash |
| `urgent-news-collector/` | Python, конвейер новостей — читай его `CLAUDE.md`. Владелец кода — victory, но `pipeline_utils.py` + `content_db_utils.py` вендорятся из openclaw: `VENDOR.md` + `sync-check.sh` |
| `web-comparables/` | не код, один `SKILL.md` |

🚨 Rails-конвенции сюда НЕ переносятся: skill `victory-rails-conventions` и правила 1–2 выше — только для Ruby. Из трёх жёстких правил в Python-сервисы едет одно: даты `dd.MM.yy`.

## Хуки (`.claude/settings.json`)

`PostToolUse` на Edit|Write запускает `rubocop -a` **в фоне** на каждый `*.rb`: там, где Ruby установлен, файл меняется уже после твоей правки — не ищи «второго редактора». В окружении без bundler хук молча ничего не делает (см. «Команды»). `PreToolUse` предупреждает о локах в `tmp/claude-locks/`. `SessionStart` печатает routing и inbox.

## Стратегический вектор (24 мес)

`.claude/memory/strategicVector.md` (короткое propagating-резюме) + `.claude/plans/_shared/splendid-imagining-lerdorf.md` (мастер-документ). Все решения прогоняй через 3 пиллара: **frictionless concierge / deep expertise / AI×human**. Усиливает 2+ — делаем; ослабляет хотя бы один — переформулируем.

## Параллельные сессии Claude Code

Worktree сейчас **два**. Источник правды — `git worktree list`, не эта таблица:

| Worktree | Ветка | Назначение |
|---|---|---|
| `/opt/.openclaw/victory` | `main` | ТОЛЬКО deploy/merge |
| `/opt/.openclaw/victory-urgent-collector` | `feat/urgent-news-collector` | Python-конвейер новостей |

🚨 **В `victory-urgent-collector` включён sparse-checkout** (06.09.26): на диске только
`services/urgent-news-collector/`, `app/controllers/webhooks/` (контракт вебхука) и `.claude/`
плюс корневые файлы — 175 файлов вместо 1490. Rails-дерева здесь нет **намеренно**: это не
битый клон и не пропажа, Ruby на этой машине всё равно не запускается. Нужен другой каталог —
`git sparse-checkout add app/services`, вернуть всё — `git sparse-checkout disable`. Настройка
per-worktree (`extensions.worktreeConfig`), main checkout не затронут.

🚨 **`/opt/.openclaw/victory` = main checkout, НЕ активная разработка.** Это live-prod bind-mount (`victory-web-1` → `/app`, `RAILS_ENV=development` + code-reload): правка там мгновенно уходит на живой сайт.

⚠️ **Таблица выше — про openclaw-машину.** На хосте `/home/q` живут пять своих worktree (`victory`, `-victory`, `-chat`, `-seo`, `-upgrade`) — схема «4 сессии» из `.claude/sessions/README.md` там не историческая, а рабочая. Пути в `.mcp.json` и `.claude/hooks/session-start.sh` ведут именно туда: на openclaw они мёртвые (MCP `postgres` и `rails-guides` не поднимаются — это сломанный путь, а не отсутствующая возможность), на `/home/q` — живые. Проверяй `git worktree list`, а не память.

### Локи — автоматические и блокирующие (с 08.08.26)

Правка файла ставит лок в `tmp/claude-locks/` **автоматически** (`post-edit-lock.sh`). Попытка тронуть файл, занятый другой сессией, **отклоняется** (`pre-edit-lock.sh`, exit 2) — руками ничего создавать не нужно. Ключ лока — путь, а не имя файла.

Снятие: коммит (`post-commit` освобождает закоммиченные файлы), TTL 2ч, `bin/lock-clean --release <путь>` для точечного снятия, `CLAUDE_LOCK_BYPASS=1` — разовый обход. Посмотреть занятое: `bin/check-cross-worktree-locks`.

### Полномочия и наблюдатель

**`.claude/docs/session-authority.md`** — кто чем владеет, что обязан согласовать, чего не вправе
трогать. Единственный источник правды по полномочиям; при споре апеллируй к нему.

Живой сессии пиши напрямую (`ListAgents` → `SendMessage`), оффлайновой — `bin/claude-inbox send`.
Снимок по всем worktree — `bin/session-status`.

Агент **`session-observer`** (живёт в victory) сводит картину четырёх сессий, ловит дублирование
работы и разрешает споры о локах и очереди в `main`. Зови его перед крупной задачей — проверить,
не делает ли это уже кто-то.

### Планы — per-session

Harness пишет план в общий `~/.claude/plans/`; `plan-sync.sh` зеркалит его в `.claude/plans/<session>/` своей сессии (под git). Мастер-документы — в `.claude/plans/_shared/`, меняются **только через PR**. В чужой per-session каталог не пишем.

### Ruby — только через `bin/rb`

На хосте нет менеджера версий Ruby, системный ruby не совпадает с пином Gemfile. `bundle`, `rspec`, `bin/rails` запускай через `bin/rb` (контейнер с целевым Ruby, свой compose-проект на сессию): `bin/rb bundle install`, `bin/rb --db bundle exec rspec`. Подробности — в шапке `docker-compose.ruby.yml`.

## Branch discipline (main = prod)

- **`main`** — production. Деплоится автоматически (или через webhook) на https://victory62.org. **Никаких direct push to main.**
- **`dev/<session>`** или feature branches (`claude/<task>`, `test/<smth>`) — где работает каждая сессия. Push свободно.
- **PR → main** — единственный путь в прод. На PR приезжает **9 проверок**, и `.github/workflows/lint.yml` даёт только три из них:

  | Проверка | Откуда |
  |---|---|
  | RuboCop, Brakeman, bundler-audit | `.github/workflows/lint.yml` — единственный workflow в репозитории |
  | CodeQL + `Analyze (ruby / python / javascript-typescript / actions)` | code scanning **default setup**, включён через UI GitHub — файла в репозитории нет, `ls .github/workflows/` его не покажет |
  | GitGuardian Security Checks | GitHub App, вне репозитория |

  **RSpec — тоже джоб в `lint.yml`** (поднимает свой PostGIS+pgvector-образ, `db:test:prepare`, полный прогон). Сеть в спеках закрыта WebMock, ActiveJob на `:test`.
- 🚨 **Code-review на diff — обязательный этап каждого PR, а не опция.** Запускать самому, не спрашивая разрешения и не предлагая как вариант: PR не считается готовым, пока ревью не пройдено и блокеры не закрыты. Порядок: код → CI зелёный → ревью → правки по находкам → merge.
  Вызов: скилл `/code-review <PR#> <уровень>` — проверено на PR #27, читает diff и гоняет код сам. `pr-review-toolkit:code-reviewer` в списке типов субагентов этой сессии нет; файл `.claude/agents/code-reviewer.md` существует, но как тип субагента **не зарегистрирован** — `subagent_type: 'code-reviewer'` падает с `Agent type not found`.
  Ревьюеру давать: команду для получения diff, ссылку на план, список намеренных решений (чтобы не оспаривал уже обдуманное), что уже проверено (спеки/линтеры — чтобы не тратил проход), и способ запустить код. ⚠️ `bin/rb` работает только на хосте `/home/q` (см. «Команды»); на openclaw-машине гонять код нечем — ревью там читает diff, но не запускает. Ревью, которое гоняет код, находит то, что чтение не находит: так был пойман сид, молча плодивший дубли.
- **Hot-fix** — отдельная feature branch → PR → fast review → merge. Не push direct.
- ⚠️ `git push` по HTTPS в этом окружении виснет и отваливается по таймауту через 300 с (чтение при этом работает — `ls-remote` мгновенный). Лечится принудительным HTTP/1.1: `git -c http.version=HTTP/1.1 push …`. В конфиг не прописано — добавляй флагом или `git config http.version HTTP/1.1` локально.

См. `.claude/memory/strategicVector.md` секция «Infrastructure decision 04.06.26» для trigger metrics когда вернуться к разговору о микросервисах/K8s (сейчас 0/7 triggered).

## MCP-серверы (`.mcp.json`)

`serena` (LSP-навигация), `postgres` (read-only схема/SELECT), `github` (PR/issues), `rails-guides`.
Команда `/mcp` в Claude Code показывает статус. Установка: см. `.claude/memory/techContext.md`.

## Routing & delegation — авто-выбор агента/скилла

⚠️ Имена ниже — это файлы `.claude/agents/*.md`, а **не** значения `subagent_type`. Ни одно из 17 не зарегистрировано: `subagent_type: 'topnlab-api-expert'` падает с `Agent type not found`. Читай нужный файл как инструкцию и выполняй сам либо передавай текстом общему субагенту.

Полная routing-таблица: `.claude/docs/delegation-map.md`. **Quick reference:**

| Domain (RU + EN keywords) | → Agent / Skill |
|---|---|
| **topnlab**, МЛС sync, listings, телефония Asterisk, миграция CRM, webhooks/topnlab | `topnlab-api-expert` |
| **TG staff bot**, work_bot, escalation, topic_registry, inbox, lead_announcer | `telegram-staff-bot-dev` |
| **site chatbot**, чат-бот сайта, chat_responder, omni_client, chat_tools, free-first chain | `site-chatbot-dev` |
| **SEO**, JSON-LD, sitemap, robots, canonical, hreflang, OG, friendly_id, Schema.org | `seo-content-curator` + skill `victory-seo-checklist` |
| **property valuation**, оценка, CMA, hedonic, аналоги Avito/Cian | `property-valuation-expert` |
| **Prawn PDF**, audit_pdf, кириллица, theme, layout PDF | `pdf-report-designer` |
| **markdown → PDF → TG**, отправь в TG, оформить как PDF | `pdf-telegram-dispatcher` |
| **рефакторинг** 500+ LOC, fat model/controller, concerns, extract service, AASM | `rails-architect` |
| **код-ревью**, review the diff, audit changes, before merge, PR review, before commit | `code-reviewer` |
| **RSpec**, добавить тесты, factory нет, spec for, тесты legacy | `test-bootstrapper` + skill `rspec-bootstrap` |
| **parallel session**, lock, conflict в правках, hand-off victory↔chat↔seo | `session-coordinator` + skill `session-coordination` |
| **client document intake** — паспорт/ИНН/выписка через TG → OCR + DLP | `client-onboarding-bot` |
| **еженедельный обзор рынка**, market analytics для TG/blog/landing | `market-analytics-publisher` |
| **post-deal кейс**, case study PDF/landing/видео-сценарий | `case-study-writer` |
| **VDS Traefik/CrowdSec** — роутеры, middlewares, bouncer, cscli (`ssh vds`) | `traefik-vds-ops` + skills `traefik-config-authoring` / `crowdsec-policy-management` |
| **Nextcloud / rclone (`nxt:`)** — дозсье в облако, share-link, шаблоны, банковские программы из Офис/НЕДВИЖИМОСТЬ | `nextcloud-rclone-ops` + skill `rclone-nextcloud-patterns` |
| **Yandex.Webmaster** — SEO digest, ИКС/SQI, opportunity detection (low CTR / mid pos), recrawl, диагностика | `yandex-webmaster-seo-ops` + skill `yandex-webmaster-api-patterns` |
| Новый Ruby-код | skill `victory-rails-conventions` |
| Figma frame → ERB+Tailwind | skill `figma-to-erb-handoff` |
| Любой user-facing русский копирайт (landing/meta/TG/email/PDF) | skill `russian-real-estate-copywriting` |

### Когда НЕ делегировать

- Простой вопрос по коду («что такое X?») → direct через serena/repo-index
- Trivial fix (typo, переименование) → direct
- Ambiguous без domain-signal → попросить уточнение, не делегировать наугад
- Контекст уже в conversation → продолжай напрямую
- Read-only diagnostics (git status, ls) → direct

### Domain conflicts

- Topnlab API + TG staff bot → `topnlab-api-expert` (источник правды по API)
- chat_responder + parallel session → `session-coordinator` first (locks), потом `site-chatbot-dev`
- PDF design vs delivery → дизайн = `pdf-report-designer`; готовый PDF в TG = `pdf-telegram-dispatcher`
- Refactor + tests missing → `test-bootstrapper` сначала (safety net), потом `rails-architect`
- Refactor + review → сначала `rails-architect` (предложит план), потом `code-reviewer` (на готовый diff). НЕ инверсия.
- Domain change (Topnlab/Yandex/etc) + safety review → domain-agent делает changes, `code-reviewer` финально pass before merge
