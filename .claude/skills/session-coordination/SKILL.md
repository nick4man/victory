---
name: session-coordination
description: Use when working in parallel Claude Code sessions on the victory62 repo. 4 known sessions (victory for Rails dev, chat for site-chatbot, seo for SEO/Lighthouse, upgrade for Rails/Ruby EOL upgrades). PRIMARY recommendation 04.06.26 — git worktree per session (eliminates branch-checkout collisions). RELATED (.claude/docs/delegation-map.md) — invoke agent `session-coordinator` для active coordination (worktree setup, lock generation, hand-off summaries); this skill captures convention, agent applies operationally.
---

# Session Coordination (victory ↔ chat ↔ seo ↔ upgrade)

## The setup

Over `/home/q/victory` **4 parallel Claude Code сессии** работают. До 04.06.26 они делили одно working dir и регулярно бились checkout'ами друг друга — мы прожили эту боль (cross-session branch switches под committами). **Решение: git worktree per session**.

| Session | Worktree path | Branch convention | Ruby | Tools |
|---|---|---|---|---|
| **victory** | `/home/q/victory-victory` | `dev/victory` или `claude/<task>` | **3.3.6** | `bin/rb` (rails/rspec/bundle) |
| **chat** | `/home/q/victory-chat` | `dev/chat` | **3.3.6** | curl, python3, `bin/rb` |
| **seo** | `/home/q/victory-seo` | `dev/seo` | **3.3.6** | curl, lighthouse, `bin/rb` |
| **upgrade** | `/home/q/victory-upgrade` | `dev/upgrade` или `test/...` | **3.3.6** | `bin/rb` + `RUBY_TARGET=` для проб |

> 🚨 `/home/q/victory` — **main checkout, ТОЛЬКО deploy/merge**. Это **live-prod bind-mount** (`victory-web-1` → `/app`, `RAILS_ENV=development` + code-reload): правка мгновенно уходит на живой сайт. НЕ вести там активную разработку. Все 4 сессии на Ruby **3.3.6** (после Rails-8.1 EOL-апгрейда 08.08.26).

## Why worktree (vs shared working tree)

| Concern | Shared dir (old) | Worktree (new) |
|---|---|---|
| `git checkout` in session A | breaks session B (working tree changed under their feet) | isolated — only A's tree changes |
| Concurrent edits on different files | OK | OK |
| Concurrent edits on **same** file | needs lock-file | авто-лок + блокировка (cross-worktree via shared `.git`) |
| Disk usage | 1× | 4× checkouts (~1-2 GB each — manageable) |
| `tmp/` (cache, locks, sessions) | shared | **per-worktree** ← gotcha |
| `.git/` | shared | **shared** (single repo, single config, single refs) |

## Worktree setup (one-time, by victory session)

```bash
cd /home/q/victory
git worktree add /home/q/victory-victory  -b dev/victory  origin/main
git worktree add /home/q/victory-chat     -b dev/chat     origin/main
git worktree add /home/q/victory-seo      -b dev/seo      origin/main
git worktree add /home/q/victory-upgrade  -b dev/upgrade  origin/main
git worktree list                  # подтвердить 5 checkout'ов (main + 4 сессии)
# marker-файл идентичности в каждый worktree:
for s in victory chat seo upgrade; do echo "$s" > /home/q/victory-$s/.claude-session; done
echo main > /home/q/victory/.claude-session
```

После setup каждая сессия открывает свой terminal и:

```bash
cd /home/q/victory-chat        # identity берётся из .claude-session (marker-файл)
claude --resume chat           # session restart inside worktree
```

`SessionStart` hook читает `.claude-session` marker (или `CLAUDE_SESSION` override) + печатает `Session`/`Worktree` + guard'ы (main-checkout → prod-warning; env≠marker → mismatch). Marker gitignored (`/.claude-session`), значения per-worktree.

## Per-worktree gotchas

### `tmp/claude-locks/` — per-worktree (был shared)

Lock files лежат в worktree-local `tmp/claude-locks/`. Напрямую между worktree не видны — все скрипты обходят их через общий `.git` (`git worktree list`). Готовый обходчик: `bin/check-cross-worktree-locks`.

Общая логика (ключи, TTL, чтение метаданных) вынесена в `.claude/hooks/lib/locks.sh` — четыре потребителя (`pre-edit-lock.sh`, `post-edit-lock.sh`, `session-start.sh`, `bin/lock-clean`) считают ключ одинаково.

### `.claude/plans/` — per-session (был общий глобальный)

Claude Code пишет план сессии в `~/.claude/plans/` — один плоский каталог на все сессии и все проекты хоста. Четыре сессии писали туда одновременно и затирали друг друга.

Путь буфера мы не контролируем, поэтому `plan-sync.sh` (PostToolUse) зеркалит его в репо:

```
.claude/plans/
  _shared/    ← мастер-документы, меняются ТОЛЬКО через PR
  victory/ chat/ seo/ upgrade/   ← планы своей сессии, под git
```

В чужой per-session каталог не пишем. `_shared/` — общий ресурс, правки туда идут PR-ом, как в код.

### Связь между сессиями — решено 09.08.26

Канал для **живой** сессии уже есть на уровне харнесса: `ListAgents` показывает victory/chat/seo/
upgrade, `SendMessage` адресует по имени. Никакой инфраструктуры не требуется.

Для **оффлайновой** — `bin/claude-inbox`, чьё хранилище переехало в `~/.claude-shared/inbox/`
(бывший Option B). Прежний путь был per-worktree и требовал, чтобы отправитель и получатель
сидели в одном checkout'е, — между сессиями такого не бывает, и почта не работала ни дня.

| Адресат | Канал |
|---|---|
| жива | `SendMessage` |
| оффлайн | `bin/claude-inbox send` |
| существенная работа | git: commit + push + PR |

### `bundle install` — race на shared Gemfile.lock

Gemfile.lock один на репо, поэтому два одновременных `bundle install` из разных worktree затрут друг друга. Coordinate: **bundle install делает одна сессия за раз**; остальные — `bin/rb bundle check` (read-only).

Запускать через `bin/rb`: на хосте нет менеджера версий Ruby (ни chruby, ни rbenv, ни mise), системный ruby не совпадает с пином Gemfile. `bin/rb` поднимает контейнер с целевым Ruby и своим compose-проектом на каждую сессию (`victory-rb-<session>`), так что БД и bundle-волюмы у сессий не пересекаются.

## Conflict points

| Что | Риск | Митигация |
|---|---|---|
| Одновременная правка одного файла в разных worktree | Merge conflict на merge | Авто-локи + блокирующий `pre-edit-lock.sh` |
| Stale read of just-edited file | Работа с outdated state | `git diff origin/main..HEAD` перед edit |
| Накопление uncommitted | Сложно понять кто что менял | Commit'ить часто; one branch per session |
| `bundle install` race | Конкурентный Gemfile.lock write | Одна сессия за раз; остальные `bin/rb bundle check` |
| Branch checkout collision | Solved by worktree | — |

## Lock-file pattern (автоматический, блокирующий)

Ключ лока — **repo-relative путь**, где `/` заменён на `%`:

```
<worktree>/tmp/claude-locks/app%services%chat_tools%chat_responder.rb.lock
```

Путь, а не basename: в репо 35 совпадающих имён (`base.rb`, `client.rb`, `_form.html.erb`…). Пока хук только предупреждал, ложное совпадение было шумом; с блокирующим хуком оно запрещало бы правку невиновного файла.

**Ставить ничего не нужно.** `post-edit-lock.sh` (PostToolUse) ставит лок на каждый отредактированный файл сам, повторная правка продлевает TTL. Ручная схема прожила два месяца и дала 0 локов — именно поэтому её заменили.

**Чужой лок блокирует.** `pre-edit-lock.sh` возвращает exit 2 — Claude Code отменяет Edit/Write и показывает, кто держит файл:

```
⛔ app/models/property.rb занят сессией chat
   worktree: /home/q/victory-chat
   с 08.08.26 21:14 (12 мин назад), task=extract concerns
   Снять: bin/lock-clean --release app/models/property.rb
   Обойти разово: CLAUDE_LOCK_BYPASS=1
```

**Снятие — три пути** (в порядке предпочтения):

```bash
git commit ...                                   # post-commit снимает локи файлов коммита
# TTL 2ч — протухший лок удаляется автоматически при первой же попытке правки
bin/lock-clean --release app/models/property.rb  # точечно, невзирая на возраст
bin/lock-clean --all --force                     # прибрать протухшие везде
```

**Посмотреть занятое:**

```bash
bin/check-cross-worktree-locks                       # все локи во всех worktree
bin/check-cross-worktree-locks app/models/property.rb
```

Аварийный обход одной правки — `CLAUDE_LOCK_BYPASS=1`. Пользуйся, только если уверен, что держащая сессия не работает: смысл блокировки в том, чтобы два агента не разъезжались в одном файле.

## Hand-off patterns

### 1. Git-first (preferred)

Best for substantial work (>10 min of work, multi-file changes):

```bash
# Sender:
git add . && git commit -m "WIP: tool X — needs migration"
git push                                    # to dev/<sender>

# Receiver (in their worktree):
git fetch origin
git merge origin/dev/<sender>               # or cherry-pick
```

### 2. Inbox (only same-worktree)

For quick prompts within the same worktree:

```bash
# Sender:
bin/claude-inbox send chat "стук-стук, нужна migration X в твоей ветке"

# Receiver (next session start, same worktree):
bin/claude-inbox list
bin/claude-inbox read <id>
bin/claude-inbox done <id>
```

### 3. activeContext.md (phase-level signaling)

Когда фаза меняется (e.g. Phase A → Phase B), update `.claude/memory/activeContext.md` через PR — все сессии увидят на следующем session start.

## Branch discipline

- **`main`** — production. **Никаких direct push.**
- **`dev/<session>`** — рабочая ветка per session (`dev/chat`, `dev/seo`, `dev/upgrade`, `dev/victory` или claude/<task> для feature work)
- **Feature branches** (`claude/<task>`, `test/<smth>`) — short-lived, off `dev/<session>` или off `main`
- **Merge to main** — только через PR + CI green (rubocop + brakeman + bundler-audit + rspec)

## Lock cleaner

Stale locks (empty или > 2h old) накапливаются в каждом worktree. Раз в неделю или при подсветке в hook:

```bash
bin/lock-clean              # dry-run по текущему worktree
bin/lock-clean --force      # удалить протухшие здесь
bin/lock-clean --all        # dry-run по всем worktree
bin/lock-clean --all --force
bin/lock-clean --release app/models/property.rb   # точечно, невзирая на возраст
```

Плановая уборка почти не нужна: локи снимаются на коммите (`post-commit`), а протухшие удаляются автоматически при первой же попытке правки. `schedule.rb` с воскресным `bin/lock-clean --force` остаётся страховкой в main checkout.

## Routine commands

```bash
# Where am I (worktree + branch):
echo "worktree: $(pwd)  branch: $(git branch --show-current)"

# What's fresh (latest commits across branches):
git log --all --oneline -5

# Uncommitted now:
git status --porcelain | head -10

# Cross-worktree locks:
for wt in $(git worktree list --porcelain | awk '/^worktree/ {print $2}'); do
  ls "$wt/tmp/claude-locks/" 2>/dev/null | grep -v archive
done

# Fresh activeContext:
head -50 .claude/memory/activeContext.md
```

## Rules of thumb

- **`bin/rails / bundle / rspec`** — через `bin/rb` из любого worktree (свой контейнер с целевым Ruby на сессию)
- **`curl`-based отправки в TG** — можно из любого worktree (gem-less)
- **Markdown / docs / planning** — chat worktree default
- **Migrations / model / view changes** — victory worktree (тесты прогнать сразу)
- **Site-chatbot tool dev** — chat worktree (по конвенции)
- **Rails/Ruby upgrade work** — upgrade worktree (отдельный Gemfile.lock target)
- **SEO / Lighthouse / sitemap** — seo worktree
- **Большие refactor'ы** — одна сессия за раз; другие ждут merge

## Anti-patterns

- ❌ Запуск `claude` без `export CLAUDE_SESSION=*` — теряется session identity, inbox + hook не работают
- ❌ Активная работа в `/home/q/victory` после worktree setup — это main checkout, reserved для merges/deploys
- ❌ **Write-операции за пределами своего worktree** — создание/правка/удаление файлов (включая gitignored: `.env`, симлинки, `mkdir`) и git-команды в чужом `/home/q/victory-<other>` или в main checkout. Даже «заодно, это же мелочь». Read-only диагностика (`git worktree list`, cross-worktree lock check, сравнение состояния) — можно. Нужно что-то в соседней сессии → отдать пользователю командой или через hand-off (commit + branch + PR)
- ❌ Параллельно править один файл в двух worktree без cross-worktree lock check
- ❌ `bundle install` в двух worktree одновременно — Gemfile.lock race
- ❌ `bundle`/`rspec` напрямую на хосте — там нет нужного Ruby, только через `bin/rb`
- ❌ `CLAUDE_LOCK_BYPASS=1` «чтобы не мешало» — обход нужен для мёртвой сессии, а не для живой
- ❌ Direct push to `main` — CI gate должен gate'ить (PR + review + green)
- ❌ Stash без `git stash save 'meaningful name'` — потом не найдёшь
- ❌ Ручное создание lock-файлов — их ставит `post-edit-lock.sh`; ручной без metadata ломает stale-detection

## Когда вспомнить про эту skill

- При планировании большой правки в файле, который другая сессия может тронуть
- При hand-off между сессиями
- При git conflict на merge/pull
- При обновлении `.claude/memory/activeContext.md`
- При onboarding новой сессии (4-й upgrade недавно появился)
- При непонимании «почему мой branch checkout не сохранился» (= другая сессия checkout'ила и сменила working tree → setup worktree)

## Полная справка

`.claude/sessions/README.md` — operational doc (env-var setup, inbox CLI, KPI cache).
`.claude/agents/session-coordinator.md` — agent for active coordination (creates locks, generates hand-off summaries, plans worktree migrations).
`.claude/hooks/pre-edit-lock.sh` — runtime hook that warns про cross-worktree locks.
