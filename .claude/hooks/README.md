# `.claude/hooks/` — Claude Code hook scripts

Three bash scripts implementing project-level hooks for Claude Code. Они **не активированы** по умолчанию — нужны два шага вручную:

```bash
# 1. Сделать executable
chmod +x .claude/hooks/*.sh

# 2. Добавить блок hooks в .claude/settings.json (см. ниже)
```

После этого reset Claude Code сессии — hooks начнут фаерить.

## Что делают скрипты

### `session-start.sh` — SessionStart hook

Печатает короткую ориентацию при старте каждой сессии Claude Code:
- Текущая git ветка
- Количество uncommitted файлов
- Последний коммит
- Первые ~14 строк `.claude/memory/activeContext.md` (текущая фаза)
- Список lock-файлов в `tmp/claude-locks/` (если есть — другая сессия что-то правит)

**Стоимость**: ~50ms (читает git status + head). Безопасен — exit 0 всегда.

### `pre-edit-lock.sh` — PreToolUse hook (Edit/Write)

Перед Edit/Write проверяет `tmp/claude-locks/<filename>.lock`. Если файл залочен другой сессией — **только warning в stderr**, НЕ блокирует операцию.

**Стоимость**: ~10ms (один `[ -f ... ]` check).

### `post-edit-rubocop.sh` — PostToolUse hook (Edit/Write на `.rb`)

После Edit/Write на `.rb`/`.rake`/`.ru` файлы — запускает `bundle exec rubocop -a` в фоне через `nohup`. НЕ блокирует Claude (forked process).

**Требования**: rubocop должен быть в bundle (Phase 3.2 добавляет). Если нет — silently skips.

**Стоимость**: ~5ms на запуск; rubocop сам работает 1-3s в фоне.

## Как активировать

Добавить в `.claude/settings.json` (или создать его если нет):

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/session-start.sh"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/pre-edit-lock.sh"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/post-edit-rubocop.sh"
          }
        ]
      }
    ]
  }
}
```

`.claude/settings.json` — **проектный** конфиг, коммитится. Все сессии (victory/chat/seo) подхватят hooks автоматически после рестарта.

## Что если хук сломается

- Все скрипты `set +e` и `exit 0` в конце — даже ошибка внутри не блокирует Claude
- Stderr идёт в логи; stdout добавляется как контекст агенту
- Если рубокоп слишком долго работает — `nohup ... &` детачит, агент не ждёт

## Откатить — одной командой

```bash
# Снять executable
chmod -x .claude/hooks/*.sh

# Или удалить hooks-блок из .claude/settings.json
# Или удалить весь файл .claude/settings.json (тогда падает на defaults)
```

## Связанные документы

- `.claude/skills/session-coordination/SKILL.md` — про tmp/claude-locks/ pattern
- `.claude/memory/activeContext.md` — что читает session-start.sh
