# CLAUDE.md — АН «Виктори» Real Estate Platform

Rails 8.1.3.1 / Ruby 3.3.6 / PostgreSQL 15+ + PostGIS + pgvector. Russian-language real estate platform. **PRODUCTION** at https://victory62.org.

## Где брать контекст (memory-bank)

Этот файл — тонкий хаб. Содержательное — рядом, читай по теме:

- `.claude/memory/activeContext.md` — текущая ветка, фаза, что в фокусе сейчас (обновляется неделями).
- `.claude/memory/systemPatterns.md` — конвенции (enums `_prefix`, soft-delete `deleted_at`, frozen literals, single quotes, dd.MM.yy даты, service-object pattern).
- `.claude/memory/techContext.md` — стек, ENV vars, команды (`rspec`, `rubocop`, миграции, Sidekiq, cron).
- `.claude/memory/progress.md` — что в проде, что отключено (Devise off!), что заглушка, аспирационные роуты, известный tech-debt.
- `.claude/repo-index.md` — компактный индекс «файл → классы» (~5k токенов, читай первым).
- `.claude/repo-map.md` — полный сигнатурный дамп (~190k токенов, on-demand для глубокого ныряния).
- Обновить оба: `bundle exec rake repo:map`.

## 3 жёстких правила (не нарушай, не спрашивая)

1. **Soft delete**: `deleted_at` + `default_scope { not_deleted }`. Никакого `paranoia` gem. Доступ к удалённым — `.unscoped`.
2. **Enums** — всегда с `_prefix: true`. Русский перевод значений — в комментарии рядом.
3. **Даты в коде/UI/сообщениях** — европейский `dd.MM.yy`. Не ISO, не US.

## Главное про auth

**Devise отключен**. `current_user` → `nil`, `user_signed_in?` → `false`. Admin-доступ — query-param `?token=$ADMIN_TOKEN`. Не предполагай, что юзер залогинен.

## Стратегический вектор (24 мес)

`.claude/memory/strategicVector.md` (короткое propagating-резюме) + `.claude/plans/_shared/splendid-imagining-lerdorf.md` (мастер-документ). Все решения прогоняй через 3 пиллара: **frictionless concierge / deep expertise / AI×human**. Усиливает 2+ — делаем; ослабляет хотя бы один — переформулируем.

## Параллельные сессии Claude Code

Над этим репо работают **4 сессии** (см. `.claude/sessions/README.md`):

| Session | Назначение | Worktree |
|---|---|---|
| **victory** | Rails-сервер :3000, Edit/RSpec/runner | `/home/q/victory-victory` |
| **chat** | Site-chatbot dev + planning | `/home/q/victory-chat` |
| **seo** | SEO meta / JSON-LD / sitemap / Lighthouse | `/home/q/victory-seo` |
| **upgrade** | Rails/Ruby EOL upgrades (Rails 8.1.3.1 в проде c 08.08.26) | `/home/q/victory-upgrade` |

Все 4 сессии — Ruby **3.3.6**. Идентичность — из marker-файла `.claude-session` в корне worktree (auto; override через `export CLAUDE_SESSION`).

🚨 **`/home/q/victory` = main checkout, ТОЛЬКО deploy/merge — НЕ активная разработка.** Это live-prod bind-mount (`victory-web-1` → `/app`, `RAILS_ENV=development` + code-reload): правка там мгновенно уходит на живой сайт. См. `.claude/sessions/README.md` + skill `session-coordination`.

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
- **PR → main** — единственный путь в прод. CI gate: rubocop + brakeman + bundler-audit + (скоро) rspec all green.
- 🚨 **Code-review на diff — обязательный этап каждого PR, а не опция.** Запускать самому, не спрашивая разрешения и не предлагая как вариант: PR не считается готовым, пока ревью не пройдено и блокеры не закрыты. Порядок: код → CI зелёный → ревью → правки по находкам → merge.
  Вызов: `pr-review-toolkit:code-reviewer`. Файл `.claude/agents/code-reviewer.md` существует, но как тип субагента **не зарегистрирован** — `subagent_type: 'code-reviewer'` падает с `Agent type not found`.
  Ревьюеру давать: команду для получения diff, ссылку на план, список намеренных решений (чтобы не оспаривал уже обдуманное), что уже проверено (спеки/линтеры — чтобы не тратил проход), и способ запустить код (`bin/rb`, см. `.claude/plans/seo/a2-phase2-detail.md`). Ревью, которое гоняет код, находит то, что чтение не находит: так был пойман сид, молча плодивший дубли.
- **Hot-fix** — отдельная feature branch → PR → fast review → merge. Не push direct.

См. `.claude/memory/strategicVector.md` секция «Infrastructure decision 04.06.26» для trigger metrics когда вернуться к разговору о микросервисах/K8s (сейчас 0/7 triggered).

## MCP-серверы (`.mcp.json`)

`serena` (LSP-навигация), `postgres` (read-only схема/SELECT), `github` (PR/issues), `rails-guides`.
Команда `/mcp` в Claude Code показывает статус. Установка: см. `.claude/memory/techContext.md`.

## Routing & delegation — авто-выбор агента/скилла

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
