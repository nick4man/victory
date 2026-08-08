# .claude/sessions/ — inter-session coordination

**4 параллельные Claude Code сессии** работают на repo victory62. С 04.06.26 — **per-session git worktrees** (раньше shared `/home/q/victory` → branch-checkout collisions).

| Session | Purpose | Worktree path | Branch | Ruby |
|---|---|---|---|---|
| **victory** | Rails dev (migrations, controllers, models, specs). Dev-server :3000 | `/home/q/victory-victory` | `dev/victory` или `claude/<task>` | **3.3.6** |
| **chat** | Site-chatbot dev + planning + TG via curl | `/home/q/victory-chat` | `dev/chat` | **3.3.6** |
| **seo** | SEO meta / JSON-LD / sitemap / Lighthouse | `/home/q/victory-seo` | `dev/seo` | **3.3.6** |
| **upgrade** | Rails/Ruby EOL upgrades (Rails 8.1 landed 08.08.26) | `/home/q/victory-upgrade` | `dev/upgrade` или `test/<eol>` | **3.3.6** |

> 🚨 **`/home/q/victory` — main checkout, ТОЛЬКО deploy/merge.** Это **live-prod bind-mount**: `victory-web-1` монтирует его в `/app` (`RAILS_ENV=development`, code-reload), поэтому **любая правка там мгновенно попадает на живой сайт**. Никакой активной разработки — работай в своём `/home/q/victory-<session>`. Все 4 сессии на Ruby **3.3.6** (после EOL-апгрейда; старое разделение chruby 3.2.2 / system 3.3 устарело).

## Worktree setup (run once)

Если worktrees ещё не созданы:

```bash
cd /home/q/victory
git worktree add /home/q/victory-victory  -b dev/victory  origin/main
git worktree add /home/q/victory-chat     -b dev/chat     origin/main
git worktree add /home/q/victory-seo      -b dev/seo      origin/main
git worktree add /home/q/victory-upgrade  -b dev/upgrade  origin/main
git worktree list                                          # подтвердить 5 checkout'ов
# marker-файл идентичности в каждый worktree:
for s in victory chat seo upgrade; do echo "$s" > /home/q/victory-$s/.claude-session; done
echo main > /home/q/victory/.claude-session
```

Каждая сессия открывает свой terminal:

```bash
cd /home/q/victory-chat          # ← cd в свой worktree; identity берётся из .claude-session
claude --resume chat
```

## Session identity — `.claude-session` marker (auto)

Идентичность сессии — из файла **`.claude-session`** в корне worktree (`victory|chat|seo|upgrade`; в main-checkout — `main`). Это durable source of truth: SessionStart-hook — подпроцесс и **не может** экспортировать env в сессию, поэтому каждый потребитель (`session-start.sh`, `bin/claude-inbox`, lock-скрипты) читает marker сам.

- Hook печатает `Session` + `Worktree` + guard'ы: запуск в main-checkout → 🚨 prod-warning; `CLAUDE_SESSION` ≠ marker → mismatch-warning (запустил сессию в чужом worktree).
- Override: `export CLAUDE_SESSION=<session>` перекрывает marker (нужно редко).
- Marker **gitignored** (`/.claude-session`) — значения per-worktree, общий tracked-файл конфликтовал бы.

## Per-worktree gotchas

| Что | Поведение | Замечание |
|---|---|---|
| `.git/` | shared | Single repo, single config, single refs |
| `tmp/` (cache, locks, sessions) | **per-worktree** | Lock files изолированы |
| `.claude/sessions/inbox/` | **per-worktree** (gitignored) | Cross-worktree messages — use git, not inbox |
| `Gemfile.lock` | shared (committed) | **Только victory делает `bundle install`** — иначе race |
| `node_modules/` | per-worktree (gitignored) | Каждый worktree может install отдельно |
| Disk usage | 4× checkouts | ~1-2 GB each — OK |

## Inbox protocol (same-worktree only)

### Структура

```
.claude/sessions/inbox/
├── victory/      # messages FOR victory session (в любом worktree)
│   ├── 2026-05-14T08-30_from-chat_new-tool.md
│   └── archive/
├── chat/
│   └── archive/
├── seo/
│   └── archive/
└── upgrade/
    └── archive/
```

Inbox files gitignored, structure через `.gitkeep`.

### Cross-worktree?

Inbox **не пересекает** worktrees — каждый worktree имеет свой `inbox/` dir. Для cross-worktree hand-off **используй git** (commit → push → merge), не inbox.

### Message format

```yaml
---
from: chat
to: victory
created: 2026-05-14T08:30:00+03:00
priority: normal           # low | normal | high
related_files:
  - app/services/chat_tools/find_similar_news.rb
---

## Что сделано
[2-3 строки summary]

## TODO для receiver
- [ ] migration X
- [ ] bin/rails db:migrate
- [ ] spec для Y
```

### CLI (`bin/claude-inbox`)

```bash
bin/claude-inbox send victory "стук-стук, нужна migration для news_embeddings"
bin/claude-inbox list                  # pending FOR my session в текущем worktree
bin/claude-inbox read <id>             # display by timestamp prefix
bin/claude-inbox done <id>             # move to archive/
```

## SessionStart hook integration

Когда `$CLAUDE_SESSION` set:

1. Печатает `Session: <id>` + worktree path в header
2. Сканирует `inbox/<id>/*.md`, count + headlines первых 3 (FIFO by mtime)
3. Сканирует `tmp/claude-locks/*.lock`, подсвечивает stale (empty или > 2ч)
4. Печатает KPI snapshot из `kpi-cache.txt` (если свежий)
5. Показывает routing matrix (delegation-map.md quick-ref)

Если `$CLAUDE_SESSION` unset — секции inbox / session-identity skipped, hook продолжает работать.

## KPI cache (Phase A snapshot)

`kpi-cache.txt` — текстовый dump из `bundle exec rake kpi:phase_a`. Cron в `config/sidekiq_cron.yml` обновляет every 6h (см. host crontab также).

```bash
# Manual refresh (только в victory worktree — нужен Rails 3.2.2 chruby):
cd /home/q/victory-victory   # или wherever victory worktree
bundle exec rake kpi:phase_a > .claude/sessions/kpi-cache.txt
```

Hook читает этот файл и печатает в SessionStart output. Stale (> 24ч) — предупреждение в hook.

Содержимое:
- Premium-сегмент counts
- SEO coverage %
- Inquiry pipeline (open / stale / completed)
- Article counts
- Strategic vector alignment (3 pillars)
- Yandex SEO (SQI, top queries, opportunities, recrawl quota, diagnostics)

## Lock-file hygiene

`tmp/claude-locks/<file>.lock` (per-worktree) — convention для крупных правок (>50 LOC или >5 мин). Format:

```
session=victory,worktree=/home/q/victory-victory,started=2026-06-04T15:00:00+03:00,task=migration-add-seo-fields
```

`pre-edit-lock.sh` hook **(updated 04.06.26)** проверяет ВСЕ worktrees через shared `.git` и предупреждает о cross-worktree locks.

Cleaner stale locks (empty или старше 2ч):

```bash
bin/lock-clean              # dry-run, показывает кандидатов в current worktree
bin/lock-clean --force      # actually rm
```

Запускай раз в неделю (или Sunday 00:00 через cron) — или когда hook на старте подсвечивает stale.

## Hand-off workflow

См. skill `session-handoff-protocol`. TL;DR:

### Git-first (preferred для substantial work)

```bash
# Sender (current worktree):
git add . && git commit -m "WIP: feature X" && git push
# Receiver (their worktree):
git fetch && git merge origin/dev/<sender>
```

### Inbox (same-worktree only — quick prompts)

См. CLI выше. Для cross-worktree — переключайся на git.

## Branch discipline

- **`main`** — production. Никаких direct push.
- **`dev/<session>`** — рабочая ветка per session
- **Feature branches** (`claude/<task>`, `test/<smth>`) — short-lived, off `dev/<session>` или `main`
- **Merge to main** — только через PR + CI green (rubocop + brakeman + bundler-audit + rspec)

## Anti-patterns

- ❌ Активная работа в `/home/q/victory` после worktree setup — это main checkout (зарезервирован для merges)
- ❌ Запуск `claude` без `export CLAUDE_SESSION=*` — теряется session identity
- ❌ Параллельная правка одного файла в двух worktrees без cross-worktree lock check (см. `pre-edit-lock.sh`)
- ❌ `bundle install` в двух worktrees одновременно — Gemfile.lock race. Только victory.
- ❌ Direct push to `main` — должен идти через PR + CI gate
- ❌ Inbox для cross-worktree messages — не работает; используй git
- ❌ Забыть `bin/claude-inbox done <id>` после обработки — inbox растёт
- ❌ Lock-file без metadata (пустой) — нарушает stale-detection логику
- ❌ KPI cache stale > 24ч — hook показывает несвежие числа

## Full reference

- Skill `session-coordination` — convention в деталях (worktree gotchas, branch discipline)
- Agent `session-coordinator` — для active coordination (worktree setup, lock generation, hand-off generation)
- `.claude/hooks/pre-edit-lock.sh` — runtime cross-worktree lock warning
- `.claude/memory/strategicVector.md` — Infrastructure decision 04.06.26 + trigger metrics
