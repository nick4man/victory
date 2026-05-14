# .claude/sessions/ — inter-session coordination

Три параллельные Claude Code сессии работают на одной кодбазе `/home/q/victory`:

| Session | Purpose | Ruby | `CLAUDE_SESSION` env value |
|---|---|---|---|
| **victory** | Rails dev (migrations, controllers, models, specs). Rails dev-server :3000. | chruby/rbenv → **3.2.2** | `victory` |
| **chat** | Site-chatbot dev + planning + TG via curl. | системный **3.3** | `chat` |
| **seo** | SEO meta / JSON-LD / sitemap / lighthouse. | системный **3.3** | `seo` |

## Session identity (opt-in)

Перед запуском `claude` в каждом терминале — установи env-var, чтобы hook + inbox + lock-files правильно тебя идентифицировали:

```bash
# Однократно — добавить в `.envrc` (direnv) или `~/.zshrc` per-tmux-pane.
# Или вручную в каждом терминале:
export CLAUDE_SESSION=victory   # или chat / seo
```

Если `CLAUDE_SESSION` не установлен — hook покажет «Session: unknown» и напомнит установить. Inbox не будет сканироваться.

## Inbox protocol

### Структура

```
.claude/sessions/inbox/
├── victory/       # messages FOR victory session
│   ├── 2026-05-14T08-30_from-chat_new-tool.md
│   └── archive/   # processed messages
├── chat/
│   └── archive/
└── seo/
    └── archive/
```

Inbox files — markdown с frontmatter, gitignored (не коммитим сообщения). Архив тоже gitignored. Сама структура папок остаётся в repo через `.gitkeep`.

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
bin/claude-inbox send victory "стук-стук, нужна migration для news_embeddings ivfflat index"
bin/claude-inbox list                  # pending FOR my session
bin/claude-inbox read <id>             # display by timestamp prefix
bin/claude-inbox done <id>             # move to archive/
```

## SessionStart hook integration

Когда `$CLAUDE_SESSION` set:

1. Печатает `Session: <id>` в header
2. Сканирует `inbox/<id>/*.md`, показывает count + headlines первых 3 (FIFO by mtime)
3. Сканирует `tmp/claude-locks/*.lock`, подсвечивает stale (empty или > 2ч)
4. Печатает KPI snapshot из `kpi-cache.txt` (если свежий)

Если `$CLAUDE_SESSION` unset — секции inbox / session-identity skipped, hook продолжает работать.

## KPI cache (Phase A snapshot)

`kpi-cache.txt` — текстовый dump из `bundle exec rake kpi:phase_a`. Обновляется вручную (perekida на cron в Phase D):

```bash
# Запускать только в victory-сессии (нужен Rails 3.2.2 chruby)
bundle exec rake kpi:phase_a > .claude/sessions/kpi-cache.txt
```

Hook читает этот файл и печатает в SessionStart output. Stale (> 24ч) — предупреждение в hook.

Содержимое:
- Premium-сегмент (count листингов >= 15M ₽)
- SEO landings — % Property с заполненным `seo_title`
- Active inquiries (не closed/rejected)
- Foreign inquiries (если есть source-фильтр)
- MAU site — только если YANDEX_METRIC_API_TOKEN set

## Lock-file hygiene

`tmp/claude-locks/<file>.lock` — convention для крупных правок (>50 LOC или >5 мин). Format:

```
session=victory,started=2026-05-14T10:00:00+03:00,task=migration-add-seo-fields
```

Очистка stale (empty или старше 2ч):

```bash
bin/lock-clean              # dry-run, показывает кандидатов
bin/lock-clean --force      # actually rm
```

Запускай раз в неделю — или когда hook на старте подсвечивает stale.

## Hand-off workflow (формальный)

См. skill `session-handoff-protocol`. TL;DR:

1. **Sender**: закоммитить или stash важное → `bin/claude-inbox send <receiver> "..."` с TODO list → обновить `.claude/memory/activeContext.md` если фаза меняется
2. **Receiver**: на старте сессии увидит inbox notification → `bin/claude-inbox read <id>` → выполнить TODO → `bin/claude-inbox done <id>`

Заменяет старый informal pattern с `.remember/now.md` (тот остаётся для history).

## Anti-patterns

- ❌ Запуск `claude` без `export CLAUDE_SESSION=*` — теряется session identity
- ❌ Параллельная правка одного файла в двух сессиях без lock — guaranteed conflict
- ❌ Забыть `bin/claude-inbox done <id>` после обработки — inbox растёт
- ❌ Lock-file без metadata (пустой) — нарушает stale-detection логику
- ❌ KPI cache stale > 24ч — hook показывает несвежие числа
