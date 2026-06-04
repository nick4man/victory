---
name: session-coordination
description: Use when working in parallel Claude Code sessions on the victory62 repo. 4 known sessions (victory for Rails dev, chat for site-chatbot, seo for SEO/Lighthouse, upgrade for Rails/Ruby EOL upgrades). PRIMARY recommendation 04.06.26 — git worktree per session (eliminates branch-checkout collisions). RELATED (.claude/docs/delegation-map.md) — invoke agent `session-coordinator` для active coordination (worktree setup, lock generation, hand-off summaries); this skill captures convention, agent applies operationally.
---

# Session Coordination (victory ↔ chat ↔ seo ↔ upgrade)

## The setup

Over `/home/q/victory` **4 parallel Claude Code сессии** работают. До 04.06.26 они делили одно working dir и регулярно бились checkout'ами друг друга — мы прожили эту боль (cross-session branch switches под committами). **Решение: git worktree per session**.

| Session | Worktree path | Branch convention | Ruby | Tools |
|---|---|---|---|---|
| **victory** | `/home/q/victory-victory` (или `/home/q/victory` migration-pending) | `dev/victory` или `claude/<task>` | chruby → **3.2.2** | bin/rails, bundle, rspec, gem |
| **chat** | `/home/q/victory-chat` | `dev/chat` | системный **3.3** | curl, python3, gem-less |
| **seo** | `/home/q/victory-seo` | `dev/seo` | системный **3.3** | curl, lighthouse, schema validators |
| **upgrade** | `/home/q/victory-upgrade` | `dev/upgrade` или `test/...` | EOL targets (3.3, 3.4) | bundle, ruby (target) |

`/home/q/victory` — **main checkout** (canonical, reserved для merge/deploy hand-off, НЕ для активной работы сессий).

## Why worktree (vs shared working tree)

| Concern | Shared dir (old) | Worktree (new) |
|---|---|---|
| `git checkout` in session A | breaks session B (working tree changed under their feet) | isolated — only A's tree changes |
| Concurrent edits on different files | OK | OK |
| Concurrent edits on **same** file | needs lock-file | needs lock-file (cross-worktree via shared `.git`) |
| Disk usage | 1× | 4× checkouts (~1-2 GB each — manageable) |
| `tmp/` (cache, locks, sessions) | shared | **per-worktree** ← gotcha |
| `.git/` | shared | **shared** (single repo, single config, single refs) |

## Worktree setup (one-time, by victory session)

```bash
cd /home/q/victory
git worktree add /home/q/victory-chat     -b dev/chat     origin/main
git worktree add /home/q/victory-seo      -b dev/seo      origin/main
git worktree add /home/q/victory-upgrade  -b dev/upgrade  origin/main
# /home/q/victory остаётся как main checkout либо victory worktree (TBD)
git worktree list                  # подтвердить 4 entries
```

После setup каждая сессия открывает свой terminal и:

```bash
export CLAUDE_SESSION=chat     # или victory / seo / upgrade
cd /home/q/victory-chat        # cd в свой worktree
claude --resume chat           # session restart inside worktree
```

`SessionStart` hook прочитает `CLAUDE_SESSION` + покажет worktree-local context (branch, inbox, KPI).

## Per-worktree gotchas

### `tmp/claude-locks/` — per-worktree (был shared)

Lock files теперь в worktree-local `tmp/claude-locks/`. Между worktree не виден прямо. Cross-worktree warning требует helper:

```bash
# in pre-edit-lock.sh — check all worktrees via shared .git
COMMON=$(git rev-parse --git-common-dir)
for wt in $(git worktree list --porcelain | awk '/^worktree/ {print $2}'); do
  [ -f "$wt/tmp/claude-locks/$BASENAME.lock" ] && echo "Locked by $wt"
done
```

См. `.claude/hooks/pre-edit-lock.sh` — обновлён 04.06.26 для cross-worktree visibility.

### `.claude/sessions/inbox/` — per-worktree (был effectively shared via single dir)

Inbox файлы — gitignored. Каждый worktree имеет свой пустой `inbox/`. Cross-worktree messaging:
- **Option A** (current): отправитель и получатель должны быть в одном worktree (например, обоим cd в `/home/q/victory-chat`). Сейчас единственный реальный способ.
- **Option B** (future): переехать inbox в `/home/q/.claude-shared/inbox/<session>/` (outside repo). Документировать в `bin/claude-inbox`.

Кратко-сейчас: **prefer git for hand-offs** (commit + branch + PR) — inbox только для quick «пнул сессию» сообщений в той же worktree.

### `bundle install` — race на shared Gemfile.lock

Если два worktree одновременно `bundle install` — последний победит, первый получит stale Gemfile.lock. Coordinate: **только victory session делает bundle install**. Остальные `bundle check` (read-only).

## Conflict points

| Что | Риск | Митигация |
|---|---|---|
| Одновременная правка одного файла в разных worktree | Merge conflict на merge | Lock-file pattern (cross-worktree через shared `.git`) |
| Stale read of just-edited file | Работа с outdated state | `git diff origin/main..HEAD` перед edit |
| Накопление uncommitted | Сложно понять кто что менял | Commit'ить часто; one branch per session |
| `bundle install` race | Конкурентный Gemfile.lock write | Только victory делает bundle install |
| Branch checkout collision | Solved by worktree | — |

## Lock-file pattern (per-worktree, cross-worktree warning)

```
<worktree>/tmp/claude-locks/<filename>.lock
```

**Создать перед крупной правкой** (>50 LOC или > 5 мин):

```bash
mkdir -p tmp/claude-locks
echo "session=$CLAUDE_SESSION,worktree=$(pwd),started=$(date -Iseconds),task=tool-add" \
  > tmp/claude-locks/chat_responder.rb.lock
```

**Проверить перед edit'ом** (видит все worktree через shared `.git`):

```bash
bin/check-cross-worktree-locks chat_responder.rb
# или вручную:
for wt in $(git worktree list --porcelain | awk '/^worktree/ {print $2}'); do
  LOCK="$wt/tmp/claude-locks/chat_responder.rb.lock"
  [ -f "$LOCK" ] && { echo "Locked in $wt:"; cat "$LOCK"; }
done
```

**Снять после коммита**:

```bash
rm tmp/claude-locks/chat_responder.rb.lock
```

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
bin/lock-clean              # dry-run, показывает кандидатов в current worktree
bin/lock-clean --force      # actually rm
```

`schedule.rb` запускает `bin/lock-clean --force` Sundays 00:00 — но это в main checkout. Per-worktree cron не настроен (TODO).

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

- **`bin/rails / bundle / rspec`** — только в **victory worktree** (chruby 3.2.2 active)
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
- ❌ Параллельно править один файл в двух worktree без cross-worktree lock check
- ❌ `bundle install` в двух worktree одновременно — Gemfile.lock race
- ❌ Direct push to `main` — CI gate должен gate'ить (PR + review + green)
- ❌ Stash без `git stash save 'meaningful name'` — потом не найдёшь
- ❌ Lock-file без metadata (пустой) — нарушает stale-detection логику

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
