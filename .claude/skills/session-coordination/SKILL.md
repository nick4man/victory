---
name: session-coordination
description: Use when working in parallel Claude Code sessions on the victory62 repo to avoid edit conflicts. Three known sessions (victory for Rails, chat for site-chatbot dev + planning, seo for SEO work) share the same working tree but have different Ruby setups and domain focus.
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

## Hand-off pattern

Когда нужно передать работу между сессиями:

### Sender

1. Закоммить или stash uncommitted state (важное)
2. Обнови `.claude/memory/activeContext.md` (текущая фаза/фокус)
3. Напиши hand-off в `.remember/now.md` — TODO для receiver

Пример:

```markdown
## Hand-off chat → victory (2026-05-13 22:30)

**State**: chat сделала design-stub нового tool `find_similar_news` в `app/services/chat_tools/find_similar_news.rb`. Stub без реализации — нужна migration для индекса pgvector на news_embeddings + bundle install не требуется.

**TODO для victory**:
- [ ] Migration `AddIvfflatIndexToNewsEmbeddings`
- [ ] `bin/rails db:migrate`
- [ ] Реализовать `#call` в `find_similar_news.rb`
- [ ] Spec в `spec/services/chat_tools/find_similar_news_spec.rb`
- [ ] Закоммитить (текущий stub uncommitted)

**Uncommitted files**:
- `app/services/chat_tools/find_similar_news.rb` (stub)
- `app/services/chat_tools/registry.rb` (added registration line)
```

### Receiver

1. `git status` + `git log --oneline -5` — что свежее
2. `head -60 .claude/memory/activeContext.md` — текущий фокус
3. `cat .remember/now.md` — hand-off note
4. Продолжай с TODO list

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
