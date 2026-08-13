---
name: session-handoff-protocol
description: Use when transferring work context between parallel Claude Code sessions (victory/chat/seo) — formal inbox-based hand-off via `bin/claude-inbox`. Replaces the informal `.remember/now.md` convention. Covers when to write a hand-off, frontmatter structure, related_files, priority levels, and how the receiver consumes inbox messages on session start. RELATED (.claude/docs/delegation-map.md) — pair with skill `session-coordination` (the broader convention — lock-files, session-domain split rules); pair with agent `session-coordinator` for active coordination (creating locks, generating hand-off summaries on demand). Inbox notifications appear automatically in SessionStart hook output when `$CLAUDE_SESSION` env-var is set.
---

# Session hand-off protocol (formal)

Three Claude Code сессии работают параллельно на одной кодбазе. Когда одна сессия должна **передать работу** другой — нужна структурированная коммуникация, чтобы receiver на старте увидел и понял что делать.

## Triggering — когда писать hand-off

| Situation | Should write | Receiver |
|---|---|---|
| Stub'нул новый service-object, нужна реализация + spec | YES | victory (если Rails-side) |
| Сделал design-document, нужно code-implementation | YES | victory |
| Drafted EN-content для landing, нужно SEO-check + publish | YES | seo |
| Прокинул новый chat_tool — нужна migration для index | YES | victory |
| Поправил CSS в shared partial — может задеть другую view | YES | victory (для verification) |
| Изменил `.claude/memory/strategicVector.md` (rare) | YES | broadcast (написать всем 3 сессиям) |
| Найдена бага которую сейчас не исправляешь | YES | соответствующая сессия (по domain) |
| Прочитал/изучил что-то полезное для другого сессии | YES (low priority) | соответствующая |
| Просто закоммитил routine work | NO | git log сам говорит |
| Trivial fix typo | NO | переусложнение |

Правило большого пальца: если другая сессия должна **что-то сделать после твоей работы** — пиши inbox. Если просто хочешь чтобы она **знала** — может быть в `activeContext.md`.

## Message structure (frontmatter)

```yaml
---
from: chat
to: victory
created: 2026-05-14T08:30:00+03:00
priority: normal           # low | normal | high
related_files:
  - app/services/chat_tools/find_similar_news.rb
  - app/services/chat_tools/registry.rb
---
```

### Поля

- **from** — твоя сессия (`$CLAUDE_SESSION`, проставится автоматически `bin/claude-inbox`)
- **to** — целевая сессия (`victory` | `chat` | `seo`)
- **created** — ISO-8601 с timezone, ставится автоматически
- **priority** — три уровня:
  - `low` — «когда будет время»; не блокер
  - `normal` — текущая работа, должен обработать в этой сессии
  - `high` — блокер для receiver: либо лочит дальнейший прогресс, либо есть deadline. Hook подсвечивает high-priority особо.
- **related_files** — файлы которые receiver скорее всего тронет; helps avoid edit conflicts (см. lock-file skill `session-coordination`)

## Body structure

```markdown
## Что сделано
[2-3 строки summary — что я уже сделал, какой state кода]

## TODO для receiver
- [ ] Конкретный actionable step 1
- [ ] Конкретный actionable step 2
- [ ] (optional) verification step

## Context / why
[1-2 предложения если non-obvious почему это надо сделать сейчас]
```

Не больше 500 слов. Detail — в коде / activeContext / commit messages. Inbox = trigger + scope, не documentation.

## Sending — via CLI

```bash
# Short form — message в одну строку
bin/claude-inbox send victory "нужна migration для news_embeddings — добавь IvfflatIndex; stub лежит в chat_tools/find_similar_news.rb"

# Long form — открыть editor (если EDITOR set)
bin/claude-inbox send victory --edit
```

Файл создаётся в `.claude/sessions/inbox/<to>/<timestamp>_from-<sender>_<slug>.md`. Slug — kebab-case первые 60 символов сообщения.

## Receiving

### Automatic on session start

Hook (если `$CLAUDE_SESSION` set) сканирует `.claude/sessions/inbox/$CLAUDE_SESSION/*.md` (не archive/), печатает:

```
=== INBOX (3 pending) ===
  [2026-05-14T08-30_from-chat_new-tool] from chat (normal)
    нужна migration для news_embeddings — добавь IvfflatIndex...
  [2026-05-14T09-15_from-seo_meta] from seo (low)
    можешь проверить мою новую _jsonld_district.erb partial...
  [2026-05-14T10-00_from-chat_urgent] from chat (HIGH ⚠️)
    chat_responder.rb крашится на новом tool — нужен fix немедленно
```

### Manual consumption

```bash
bin/claude-inbox list                              # show pending count + headlines
bin/claude-inbox read 2026-05-14T08-30             # display full message
bin/claude-inbox done 2026-05-14T08-30             # mv to archive/ after processing
```

## Rules для receiver

1. **Read on session start** — если hook показал pending, прочитай ДО любой substantive work
2. **Acknowledge high-priority first** — если есть `high`, разбираться сразу
3. **Don't skip without good reason** — если нет capacity сейчас, ответь sender через inbox: `bin/claude-inbox send chat "получил, разберусь в следующей сессии"`
4. **Always `bin/claude-inbox done`** после обработки — иначе inbox растёт и hook становится noisy

## Rules для sender

1. **Be specific** — TODO checklist > vague description
2. **Include `related_files`** — receiver сразу видит scope; снижает edit-conflict риск
3. **Don't dump too much** — > 500 слов = надо в `.claude/memory/activeContext.md` или новый plan file, а в inbox дать ссылку
4. **Verify receiver direction** — `chat` для site-chatbot tools; `seo` для SEO landings; `victory` для всего Rails-side. Если сомневаешься — `victory` (там в основном работа кода)

## Broadcast pattern

Когда хочешь известить ВСЕ 3 сессии (rare — изменение стратегии, новый convention, важный фикс):

```bash
bin/claude-inbox send victory "<message>"
bin/claude-inbox send chat "<message>"
bin/claude-inbox send seo "<message>"
```

Или (если ты в victory и хочешь известить chat+seo):

```bash
for s in chat seo; do bin/claude-inbox send $s "<message>"; done
```

Hook не имеет специального broadcast support — ты просто дублируешь.

## Когда вспомнить про этот skill

- Перед `git commit` на работе, которая может задеть другую сессию
- Перед context-switch (закрываешь сессию или переключаешься на другую задачу)
- При обнаружении баги или TODO, который явно не для твоего домена
- При получении inbox-уведомления от hook — прочитать и обработать корректно

## Anti-patterns

- ❌ Inbox как чат — не пиши «привет, ты тут?» messages; это task queue, не chat
- ❌ Длинные тексты > 500 слов — выноси в `.claude/plans/<session>/*.md`, в inbox даёшь ссылку
- ❌ Забывать `done <id>` — растёт noise в hook output
- ❌ Множественные дубликаты одной задачи — обнови существующий message (читай → правишь содержимое → `done`)
- ❌ Игнорировать high-priority — это блокер для другой сессии, не для лички

## Cross-references

- Lock-file pattern: skill `session-coordination` — для file-level locking
- Session-coordinator agent — для active coordination work (создаёт locks, генерирует hand-off summary автоматически по запросу)
- `bin/lock-clean` — раз в неделю чистит stale locks
- `.claude/memory/activeContext.md` — для long-lived state (текущая фаза, фокус); inbox = short-lived hand-off
