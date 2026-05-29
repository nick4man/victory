---
name: session-coordination
description: Use when working in parallel Claude Code sessions on the victory62 repo to avoid edit conflicts. Three known sessions (victory for Rails, chat for site-chatbot dev + planning, seo for SEO work) share the same working tree but have different Ruby setups and domain focus. RELATED (.claude/docs/delegation-map.md) — for ACTIVE coordination work (creating locks, generating hand-off summaries) invoke agent `session-coordinator`; this skill captures the convention, the agent applies it operationally.
---

# Session Coordination (victory ↔ chat ↔ seo)

## The setup

Над `/home/q/victory` параллельно идут как минимум три Claude Code сессии:

| Session | Purpose | Ruby | Tools |
|---|---|---|---|
| **victory** | Rails dev + migrations + rspec + rubocop + Rails dev-server :3000 | chruby → **3.2.2** | bin/rails, bundle, rspec, gem |
| **chat** | Site-chatbot development + planning + TG comms + docs | системный **3.3** | curl, python3, **gem-less** |
| **seo** | SEO meta / JSON-LD / sitemap / lighthouse audits / content-SEO | системный **3.3** | curl, lighthouse via chrome-devtools-mcp, schema validators |

Все сессии:
- Делят один git working tree
- Используют один `.mcp.json` (4 MCP сервера)
- Видят одинаковые `.claude/agents/*`, `.claude/skills/*`, `.claude/memory/*`

## Conflict points

| Что | Риск | Митигация |
|---|---|---|
| Одновременная правка одного файла | merge conflict при коммите | lock-file pattern (см. ниже) |
| Stale read of just-edited file | работа с outdated state | `git diff` перед edit'ом |
| Накопление uncommitted | сложно понять кто что менял | частые коммиты (1-2 per сессия per час) |
| `bundle install` race | конкурентный gem.lock write | не запускай bundle одновременно |

## Lock-file pattern

```
tmp/claude-locks/<filename>.lock
```

**Создать перед крупной правкой** (>50 LOC или > 5 мин):

```bash
mkdir -p tmp/claude-locks
echo "session=chat,started=$(date -Iseconds),task=tool-add" \
  > tmp/claude-locks/chat_responder.rb.lock
```

**Проверить перед edit'ом**:

```bash
LOCK=tmp/claude-locks/<file>.lock
[ -f "$LOCK" ] && cat "$LOCK"  # show owner
```

**Снять после коммита**:

```bash
rm tmp/claude-locks/<file>.lock
```

> `tmp/claude-locks/` входит в `.gitignore` (через `/tmp/*`).

## Hand-off pattern (formalized via inbox)

**С commit `bin/claude-inbox` и `.claude/sessions/inbox/` — informal pattern `.remember/now.md` deprecated** (но остаётся для history). Использовать formal protocol:

См. skill `session-handoff-protocol` — он описывает frontmatter format, priority levels, related_files, sender/receiver rules.

### Sender — обновлённый workflow

1. Закоммить или stash uncommitted state (важное)
2. Обнови `.claude/memory/activeContext.md` (текущая фаза/фокус) если фаза меняется
3. Используй formal inbox:
   ```bash
   bin/claude-inbox send <receiver> "стук-стук, нужна migration для X"
   ```
4. Receiver увидит pending на старте сессии через SessionStart hook (если `$CLAUDE_SESSION` set)

### Receiver — обновлённый workflow

1. SessionStart hook автоматически показывает inbox pending count + headlines (если `$CLAUDE_SESSION` set)
2. `bin/claude-inbox read <id>` — открыть полное сообщение
3. `git status` + `git log --oneline -5` — что свежее
4. `head -60 .claude/memory/activeContext.md` — текущий фокус
5. Выполни TODO → `bin/claude-inbox done <id>` (move to archive/)

## Lock cleaner

Stale locks накапливаются (empty или > 2h old). Раз в неделю или при подсветке в hook:

```bash
bin/lock-clean              # dry-run, показывает кандидатов
bin/lock-clean --force      # actually rm
```

Hook на старте автоматически подсвечивает stale locks — это сигнал запустить cleaner.

## Routine commands

```bash
# Что свежее (от какой сессии последний коммит):
git log --oneline -3

# Что не закоммичено сейчас:
git status --porcelain | head -10

# Кто что лочит:
ls tmp/claude-locks/ 2>/dev/null

# Свежий activeContext:
head -50 .claude/memory/activeContext.md
```

## Rules of thumb

- **bin/rails / bundle / rspec** → только в **victory-сессии** (system Ruby 3.3 ≠ project 3.2.2)
- **curl-based отправки в TG** → можно из chat-сессии (gem-less, нужен только curl)
- **Markdown / docs / planning** → chat-сессия по умолчанию
- **Migrations / model changes / view changes** → victory-сессия (тесты прогнать сразу)
- **Site-chatbot tool development** → chat-сессия (по конвенции проекта)
- **Большие refactor'ы** → одна сессия за раз; другая ждёт коммит/push

## Anti-patterns

- ❌ Параллельно править один файл без lock — гарантированный merge conflict
- ❌ Запускать `bin/rails runner` в chat-сессии — wrong Ruby
- ❌ Делать `git push --force` без full sync с другой сессией
- ❌ Stash без `git stash save 'meaningful name'` — потом не найдёшь
- ❌ Класть lock и забывать снять > 1 час — это блокер

## Когда вспомнить про эту skill

- При планировании большой правки в файле, который другая сессия может тронуть
- При hand-off между сессиями
- При git conflict на merge/pull
- При обновлении `.claude/memory/activeContext.md`
