# План: разнести 4 Claude-сессии (victory / chat / seo / upgrade) по отдельным worktree

## Context — зачем

Над репо victory62 работают 4 параллельные Claude Code сессии. Сейчас chat/seo/upgrade имеют worktree, но сессия **victory делит `/home/q/victory`** — а это **live-prod bind-mount**: контейнер `victory-web-1` монтирует `/home/q/victory → /app` в `RAILS_ENV=development` с code-reload, поэтому **любая правка там мгновенно попадает на живой сайт**. Это и коллизия между сессиями, и прямой риск для прода.

Цель: каждая сессия — в своём чистом worktree на ветке `dev/<session>` от текущего main (Rails 8.1.3.1); `/home/q/victory` зарезервирован **только под deploy/merge** (никакой активной разработки). Идентичность сессии — автоматически через marker-файл. Тулинг (inbox / lock / hooks / доки) — полностью на 4 сессии.

## Текущее состояние (проверено, read-only)

| Worktree | Ветка | Позади main | Впереди | Чисто |
|---|---|---|---|---|
| `/home/q/victory` | **main** (74ba0f2) | — | — | ✓ (prod bind-mount) |
| `/home/q/victory-chat` | dev/chat | 34 | **0** | ✓ (нет remote) |
| `/home/q/victory-seo` | dev/seo | 34 | **0** | ✓ (нет remote) |
| `/home/q/victory-upgrade` | upgrade/rails-8-eol-phase2 | — | 2 (уже в main через PR #8) | ✓ |

- `dev/victory` **не существует**; `dev/upgrade` существует (27 позади, 0 впереди), нигде не checked-out.
- Все dev-ветки — **чистые ancestors main, 0 неслитых коммитов** → освежение fast-forward безопасно, работа не теряется.
- `CLAUDE_SESSION` не выставлен; `session-start.sh` не worktree-aware; `bin/claude-inbox` знает только `victory|chat|seo`; нет `inbox/upgrade/`; `.gitignore` вайтлистит `.keep`, а файлы-заглушки — `.gitkeep` (т.е. не трекаются).

## Целевая топология

```
/home/q/victory           main         prod bind-mount + deploy/merge ONLY (live code-reload — НЕ трогать!)
/home/q/victory-victory   dev/victory  NEW — сессия victory
/home/q/victory-chat      dev/chat     refresh → main
/home/q/victory-seo       dev/seo      refresh → main
/home/q/victory-upgrade   dev/upgrade  switch с rails-8-ветки, refresh → main
```

## Механизм идентичности (выбор: marker-файл, auto)

Marker-файл `.claude-session` в корне каждого worktree — **источник правды**. Каждый потребитель читает его сам (SessionStart-hook не может экспортировать env в сессию, поэтому централизованный export не годится):
- **hook** — для печати идентичности + guard от запуска в чужом worktree;
- **`bin/claude-inbox`** и **`pre-edit-lock.sh`** — как fallback при пустом `CLAUDE_SESSION`.

`.claude-session` **обязательно gitignored** (значения разные по worktree, общий tracked-файл конфликтовал бы).

## Шаги

### A. Worktree-топология
1. Освежить существующие session-worktree до main (все чистые, 0 впереди → ff-only, без потерь):
   - `git -C /home/q/victory-chat merge --ff-only origin/main`
   - `git -C /home/q/victory-seo  merge --ff-only origin/main`
2. Починить upgrade-worktree: перевести на `dev/upgrade` + освежить:
   - `git -C /home/q/victory-upgrade checkout dev/upgrade`
   - `git -C /home/q/victory-upgrade merge --ff-only origin/main`
   - удалить локальную `upgrade/rails-8-eol-phase2` (содержимое уже в main): `git branch -D upgrade/rails-8-eol-phase2`
3. Создать недостающий victory-worktree:
   - `git worktree add /home/q/victory-victory -b dev/victory origin/main`
4. `git worktree list` → 5 checkout'ов (main + 4 сессии), каждая на своей `dev/<session>`.

### B. Auto-identity (marker-файл)
5. Положить `.claude-session` в корень каждого worktree:
   - `victory-victory/.claude-session` → `victory`; `victory-chat` → `chat`; `victory-seo` → `seo`; `victory-upgrade` → `upgrade`;
   - `/home/q/victory/.claude-session` → `main` (маркер «reserved checkout» — hook предупредит «здесь только deploy/merge»).
6. Добавить `/.claude-session` в `.gitignore` (сначала — до создания файлов).
7. Доработать `.claude/hooks/session-start.sh` (около строки 16, `SESSION_ID="${CLAUDE_SESSION:-unknown}"`):
   - fallback: если `CLAUDE_SESSION` пуст — читать `./.claude-session`;
   - печатать **путь worktree** (сейчас печатается только branch);
   - **guard**: если `SESSION_ID == main` (или worktree = `/home/q/victory`) — крупное предупреждение «prod bind-mount, только deploy/merge»; если идентичность не совпадает с ожидаемым маркером worktree — предупредить о запуске в чужом месте.

### C. Тулинг → на 4 сессии
8. `bin/claude-inbox`:
   - строка 13: `valid_sessions=("victory" "chat" "seo" "upgrade")`;
   - строка 11: fallback на маркер — `MY_SESSION="${CLAUDE_SESSION:-$(cat "$ROOT/.claude-session" 2>/dev/null || echo unknown)}"`;
   - строка 4 (коммент) + `usage()` — добавить `upgrade`.
9. `.claude/hooks/pre-edit-lock.sh` — тот же marker-fallback для session-имени в lock-метаданных (уже per-worktree и cross-worktree-aware; менять только источник session-id).
10. Создать `.claude/sessions/inbox/upgrade/.keep`.
11. Починить трекинг inbox: переименовать существующие `.gitkeep` → `.keep` в `inbox/{victory,chat,seo}` (и создать `inbox/upgrade/.keep`) — чтобы совпало с вайтлистом `.gitignore:17 !.claude/sessions/inbox/*/.keep`. Все 4 inbox-каталога станут трекаемыми.

### D. Доки
12. Обновить `.claude/sessions/README.md`, `.claude/skills/session-coordination/SKILL.md`, `.claude/agents/session-coordinator.md`:
    - убрать «(migration pending)» / «(TBD)» — victory-victory теперь существует;
    - документировать marker-файл `.claude-session` как основной способ идентичности (ручной `export CLAUDE_SESSION` — как override);
    - выделить предупреждение **`/home/q/victory` = live-prod bind-mount, только deploy/merge, НИКОГДА не активная разработка**;
    - Ruby **3.3.6** везде (старое разделение chruby 3.2.2 / system 3.3 устарело после EOL-апгрейда);
    - добавить `victory-victory` в setup-скрипт.
13. `CLAUDE.md` — секция «Параллельные сессии Claude Code»: пути worktree + «main checkout = deploy-only» + marker-identity.

### E. Carry-over
14. Старое inbox-сообщение в `/home/q/victory/.claude/sessions/inbox/victory/` (одно, от 04.06) — inbox per-worktree, поэтому при желании скопировать в `victory-victory/.claude/sessions/inbox/victory/`; вероятно устарело — можно оставить/архивировать.

## Verification (end-to-end)
- `git worktree list` → 5 записей; каждая сессия на `dev/<session>`, `/home/q/victory` на `main`.
- В каждом worktree `cat .claude-session` = ожидаемое имя.
- Прогнать hook вручную без env: `CLAUDE_PROJECT_DIR=/home/q/victory-chat bash /home/q/victory-chat/.claude/hooks/session-start.sh` → печатает `session=chat` + путь worktree, без mismatch-warning; тот же прогон в `/home/q/victory` → предупреждение «prod bind-mount / deploy-only».
- `cd /home/q/victory-upgrade && bin/claude-inbox list` → нет ошибки «invalid session»; `bin/claude-inbox send chat "test"` из upgrade проходит; получатель в `victory-chat` видит сообщение.
- `git -C /home/q/victory branch --show-current` → `main` (не трогали); **прод HTTP 200** (checkout `/home/q/victory` не менялся — только добавлен gitignored `.claude-session`).

## Risks / mitigations
- **Нельзя трогать checkout `/home/q/victory`** (live prod). Все refresh — на ДРУГИХ worktree. В `/home/q/victory` добавляется только gitignored `.claude-session=main` (ноль влияния на код/reload).
- **ff-only** безопасен: dev-ветки — чистые 0-ahead ancestors; если вдруг где-то есть неслитое — ff-only падает громко (без `--force`, ничего не теряется).
- **`.claude-session` закоммитить по ошибке** → сначала gitignore, потом создавать файлы (значения per-worktree, общий tracked-файл конфликтует).
- Все изменения тулинга (inbox/lock/hook/доки) правятся в **одном** worktree (например `victory-victory` или напрямую в рабочем), коммитятся в `dev/<session>` → PR → main как обычно; `/home/q/victory` получит их только при следующем deploy-обновлении (не срочно, тулинг работает из любого worktree через shared `.git`).
