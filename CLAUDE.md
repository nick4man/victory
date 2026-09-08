# CLAUDE.md — АН «Виктори» Real Estate Platform

Rails 8.1.3.1 / Ruby 3.4.10 / PostgreSQL 15+ + PostGIS + pgvector. Russian-language real estate platform. **PRODUCTION** at https://victory62.org.

⚠️ Ruby: рантайм **3.4.10** (`Gemfile`, `.ruby-version`, `mise.toml`, `Dockerfile`). Прод-контейнеры переезжают на 3.4.10 только после пересборки образов и пересоздания volume `victory_bundle` — процедура в `.claude/memory/techContext.md`, секция «Деплой смены Ruby/Rails». `.rubocop.yml` намеренно таргетирует 3.2 как нижнюю границу.

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
| Публичный сайт | `landing#index` + `properties`/`news`/`valuations`/`cabinet`, ~891 строка `config/routes.rb`; сюда же чат-виджет `namespace :chat` — **приоритетный канал**, см. ниже | нет (Devise off) |
| JSON API | `namespace :api { namespace :v1 }` | JWT |
| Админка | `namespace :admin` | `?token=$ADMIN_TOKEN` |
| Вебхуки | `app/controllers/webhooks/` — `topnlab`, `telegram`, `news_ingest`, `yookassa`, `amocrm` | у каждого свой секрет из ENV; при пустом ENV контроллер отказывает, а не пропускает |

Что нужно знать до первой правки:

- **Каталог объектов не наш.** Источник правды — внешняя CRM Topnlab; `Property` — проекция, которую наполняют `TopnlabSyncJob` (каждые 30 мин) и соседние sync-джобы. Инвариант: при неполном обходе архивация пропускается, иначе каталог схлопывается.
- **Доменная логика — в `app/services/` (~260 файлов), не в моделях и не в контроллерах.** Plain-Ruby класс с `call`, см. `systemPatterns.md`. Не путать с верхнеуровневым `services/`.
- **Два Telegram-бота из одного Rails**: `telegram/work_bot/` (сотрудники — фактический CRM-канал: команды, задачи, дайджесты, эскалации) и `telegram/client_bot/` (клиенты). Общий вход — `Telegram::InboundProcessor`.
- 🚨 **LLM: `DEFAULT_CHAINS` в `Llm::OmniClient` — free-first, но в проде они не используются.** `.env` задаёт `LLM_CHAIN_CHAT` / `LLM_CHAIN_ANALYSIS` / `LLM_CHAIN_STAFF_ANALYSIS`, и там **ноль** `:free`-моделей, а `:analysis` идёт Sonnet-first. Про стоимость и порядок моделей судить по `grep '^LLM_CHAIN' .env`, а не по коду. Подробности и сломанные модели — секция «Чат-виджет».
- **Эмбеддинги** — pgvector + gem `neighbor`, таблицы `*_embedding`, наполняются `EmbedXxxJob`.

### Два планировщика, и это не опечатка

| | Что |
|---|---|
| `config/sidekiq_cron.yml` | 22 задачи внутри Sidekiq — **боевое** расписание (Topnlab sync, дайджесты, SLA, cleanup). Время в MSK, зависит от `TZ` контейнера |
| `config/schedule.rb` | whenever → системный crontab, ~17 записей |

Они пересекаются (`RefreshTopnlabStatsJob` объявлен в обоих), а последняя строка `schedule.rb` зашита на `cd /home/q/victory` — путь, которого больше нет. Добавляя периодику, по умолчанию бери `sidekiq_cron.yml` и проверь, нет ли дубля.

## Чат-виджет сайта — приоритетный канал взаимодействия

**Направление (с 08.09.26): чат-виджет развивается как основной интерфейс между
клиентом и агентством.** Не «ещё одна фича сайта», а тот вход, через который
клиент должен получать подбор, оценку, аудит и живого агента, не уходя в форму
и не звоня. Владелец домена — сессия **chat** (`/home/q/victory-chat`).
Из трёх пилларов канал бьёт сразу в два: `frictionless concierge` и `AI×human`.

### Путь запроса — ответ всегда асинхронный

```
_chat_widget.html.erb (инлайновый JS, НЕ Stimulus, ActionCable c CDN)
  GET  /chat/conversation.json   → Chat::ConversationsController  (кука visitor_token 90д, сеет greeting без LLM)
  POST /chat/conversation/messages → Chat::MessagesController      (rate-limit 5/мин Redis, кап 2000 символов)
       └ Llm::ScopeGuard.classify → :injection/:off_topic отвечают статикой, LLM не зовётся
       └ :allowed → LlmReplyJob (Sidekiq)
            └ Llm::ChatResponder → Llm::ToolRunner (≤5 итераций) → Llm::OmniClient → ChatTools::Registry
       → ChatMessage(role: assistant) + broadcast в ConversationChannel
       → маркер <<<ESCALATE:…>>> → conv.escalate! + TelegramNotifyJob → staff-группа
Ответ сотрудника reply-ом в TG → Telegram::InboundProcessor → ChatMessage(role: agent) → тот же канал
```

HTTP-эндпоинт ответа бота **не возвращает** — всё доезжает по WebSocket. Ляжет
ActionCable, и посетитель не увидит ничего, хотя в БД ответ будет.

Оркестратор лежит в `app/services/llm/chat_responder.rb`, а **не** в
`chat_tools/`. Инструментов в `ChatTools::Registry::HANDLERS` — 11 публичных;
`chat_tools/staff/*` со своим реестром сайтовому боту недоступны, и эту границу
безопасности не размывать.

### Инварианты — не ломать

1. **`ScopeGuard` работает до LLM.** Любая новая проверка ввода идёт туда же, а не в промпт: это экономия токенов и единственный барьер, который нельзя обойти джейлбрейком.
2. **Обещал человека — поставь эскалацию.** Текст «позову агента» без маркера `<<<ESCALATE:>>>` не поднимает никого. Сейчас это нарушено в `Llm::ToolRunner` при исчерпании итераций.
3. **Тяжёлое — асинхронно.** Эталон — `run_investment_audit`: health-чек, джоба, сразу отдаёт `audit_url`. Анти-эталон — `estimate_property_valuation`, который синхронно тянет геокодинг и цепочку `:analysis` внутри tool-loop.
4. **Промпт кэшируется 5 минут** по ключу в `chat_responder.rb`. Правишь промпт — бампай ключ, иначе правка не видна.
5. **Контекст страницы — только через `Llm::PageContext`**, приветствия — через `Llm::PageGreeting`. Новый публичный раздел сайта без записи в эту карту получает `:other`, и бот не понимает, на какой странице стоит.

### Состояние в проде — замер 08.09.26

| Что | Значение |
|---|---|
| Диалогов за 30 дней | 3 |
| `Inquiry` из бота за всю историю / из обычной формы | 1 / 54 |
| Объектов, видимых боту (`Property.on_site`) | 17 из 127 живых |
| Ответов `model: 'fallback'` (LLM лёг) | 4 из 70 |
| Последняя правка `chat_tools/` и `llm/` | 29.05.26 / 23.05.26 |

Бот исправен, но к нему не приходят. **Поэтому расширять набор инструментов
вширь до появления телеметрии — оптимизация участка, куда никто не заходит.**

🚨 Цепочки в проде переопределены `.env`, `:free`-моделей ноль. Две модели
отвечают ошибкой на каждом вызове: `groq/llama-3.3-70b-versatile` даёт HTTP 404
и стоит **первым** в `LLM_CHAIN_CHAT`, `kr/claude-sonnet-4.5` даёт HTTP 400
«No credentials for provider: kiro». 08.09.26 цепочка `:analysis` упала
целиком. Клиент при этом не остаётся один: `Llm::ChatResponder` возвращает
`escalate: true`, и `LlmReplyJob` зовёт живого агента в TG. А вот инженерного
сигнала нет — исключение проглочено без re-raise, поэтому мимо Sentry и
`retry_on`. Сбой цепочки выглядит как обычная эскалация, и найти его можно
только по логам либо по `metadata->>'model' = 'fallback'`.

### Известные дефекты (проверены по коду и проду)

- `Llm::ScopeGuard` — паттерн `DAN` без флага `/i` против уже лоуркейснутой строки, не срабатывает никогда.
- `Llm::ToolRunner` — `tool_log` собирается и выбрасывается; в `chat_messages.metadata` пишутся только `model` и `escalate`, вопреки комментарию в коде.
- `ChatTools::GetPropertyDetails` — при пустом `user.phone` подставляет московскую заглушку, а промпт велит зачитать её клиенту.
- `ChatTools::RunInvestmentAudit` — `city: 'Рязань'` захардкожен, каталог трёхгородской.
- `PATCH /chat/conversation` реализован, но виджет его не зовёт: контакт собирается только через `qualify_lead`.
- Виджет обрабатывает лишь `type: 'message'`, события `status_changed` и `closed` игнорирует — после `/close` посетитель пишет в пустоту.
- `Chatbot::MessagesController` — публичная заглушка «Чатбот в разработке», к боевому виджету отношения не имеет.
- Спеков на публичный чат нет ни одного: покрыта только staff-сторона.

### Порядок работ

Телеметрия воронки → починка цепочек и алертинга → спеки на публичные тулы →
карта страниц в `PageContext` → новые возможности. Не наоборот.

⚠️ Ни один пункт не чинит корневое ограничение — **17 объектов на сайте**. Это
домен сессий victory (Topnlab) и seo, не chat.

### ENV чат-бота

`OMNIROUTE_*`, `LLM_CHAIN_*`, `GOOGLE_EMBEDDING_API_KEY` и `AUDIT_API_*` в
`techContext.md` отсутствуют, поэтому держи их здесь. Остальные строки таблицы
там есть — тут они ради полноты отказов, значения смотри в `techContext.md`.
Сами значения — в `.env`, в переписку их не тащить.

| Переменная | При пустом значении |
|---|---|
| `OMNIROUTE_BASE_URL`, `OMNIROUTE_API_KEY` | `Llm::OmniClient` падает на конструкторе → клиент получает fallback + автоэскалацию |
| `LLM_CHAIN_CHAT` / `_ANALYSIS` / `_STAFF_ANALYSIS` | тихий откат на `DEFAULT_CHAINS`; у `:staff_analysis` дефолта нет, подставляется `:chat` |
| `GOOGLE_EMBEDDING_API_KEY` | `semantic_search` возвращает `tool_failed`, `EmbedXxxJob` уходят в ретраи |
| `TELEGRAM_STAFF_CHAT_ID`, `TELEGRAM_BOT_TOKEN` | эскалация теряется молча: `TelegramNotifyJob` глотает ошибку |
| `AUDIT_API_BASE_URL`, `AUDIT_API_TOKEN` | `run_investment_audit` отдаёт `engine_unavailable` |
| `REDIS_URL` | rate-limit отключается молча, cost-счётчики не пишутся. ⚠️ **Пустая строка хуже отсутствия**: `config/cable.yml` берёт её через `ENV.fetch`, дефолт не подставляется, и ложится ActionCable — то есть ровно тот отказ, при котором посетитель не видит ответов |

Мёртвый груз: `LLM_MODEL_PRIMARY` и `LLM_MODEL_FALLBACK` есть в `.env`, кодом не читаются.

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

### Чат — прогон и наблюдение

🚨 **В chat-стеке `bundle exec rspec` может стереть dev-базу.** `DATABASE_URL`
побеждает `RAILS_ENV=test`, и спеки идут по `viktory_realty_development`, где
лежат живые объекты и диалоги. Единственный safeguard в `spec/rails_helper.rb`
проверяет только `Rails.env.production?`. Перед прогоном убедись, что
`DATABASE_URL` не подсунут, либо гоняй `bin/rb --db`.

Сеть в спеках закрыта: `spec/rails_helper.rb` держит
`WebMock.disable_net_connect!(allow_localhost: true)`. VCR в проекте нет, так что
стаб LLM делай через DI, как в `spec/services/llm/intent_classifier_spec.rb`.

Наблюдение за живым ботом — логов достаточно, админки для диалогов нет:

```bash
docker logs victory-sidekiq-1 --since 24h 2>&1 | grep 'Llm::OmniClient'   # какая модель ответила / какие упали
grep '^LLM_CHAIN' .env                                                    # реальные цепочки, не DEFAULT_CHAINS
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

Inbox при этом **работает на обеих машинах**: с 07.09.26 `bin/claude-inbox` и `session-start.sh` держат единую очередь в main checkout (резолв через `git --git-common-dir`), а новый worktree саморегистрируется, создав в ней свой каталог — старый жёсткий список имён больше не блокирует.

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

- **`main`** — production. **Деплой ручной, а не автоматический** — мерж в `main` до сайта не доезжает: прод-чекаут `/home/q/victory` обновляют руками, и 07.09.26 он отставал на 33 коммита. Процедура — `.claude/memory/techContext.md`, секция «Деплой смены Ruby/Rails». **Никаких direct push to main.**
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
- 🚨 **Зависимые части едут стеком PR, а не одним большим PR.** Обязательно, если верно любое из двух: (а) работа делится на слои, где следующий не собирается без предыдущего — миграция → сервис → UI; (б) diff перевалил ~500 строк или ~10 файлов. PR #16 (2532 строки, 29 файлов) — ровно этот случай.
  Инструмент — `gh stack`, правила в skill `gh-stack`: `gh stack init <ветки снизу вверх>` → `gh stack submit --open` → `gh stack sync` после каждой правки и после каждого мержа. Ручная цепочка `gh pr create --base` **стек на GitHub не создаёт** — выходят несвязанные PR, а `sync` заменяет весь ручной `rebase --onto` + `pr edit --base`.
  Ревью остаётся обязательным — отдельно на каждый PR стека, снизу вверх.
  ⚠️ Без TTY `submit` создаёт **черновики** (нужен `--open`), а `merge` без номера PR сливает **весь** стек, включая неотревьюенные слои.
  ⚠️ **Предусловие:** `submit`/`sync`/`push` пушат внутри себя и флаг `-c http.version=HTTP/1.1` принять не могут, поэтому попадут под тот же HTTPS-таймаут (см. ниже). Один раз на репозиторий: `git config http.version HTTP/1.1`. Ожидание по механике таймаута, живым `submit` не проверялось.
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
| **site chatbot**, чат-бот сайта, chat_responder, omni_client, chat_tools, page_context, воронка виджета | `site-chatbot-dev` — сперва прочитай секцию «Чат-виджет сайта» выше |
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
| **стек PR**, зависимые PR, цепочка PR, `gh pr create --base`, `rebase --onto` | skill `gh-stack` |
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
