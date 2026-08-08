# Per-session планы + обязательные локи

## Context

Над репо victory62 работают 4 параллельные сессии Claude Code, каждая в своём git worktree
(`/home/q/victory-{victory,chat,seo,upgrade}`). Две проблемы, обе подтверждены осмотром:

**1. Планы затирают друг друга.** Каталог `.claude/plans/` в репо **пуст во всех 5 checkout'ах**
и не отслеживается git, хотя на него ссылаются 8 мест (`CLAUDE.md:29`,
`.claude/hooks/session-start.sh:195`, `strategicVector.md:3,178,188`, `activeContext.md:173,195`,
`session-handoff-protocol/SKILL.md:147`). Реальные планы лежат в глобальном `/home/q/.claude/plans/` —
одном плоском каталоге на все сессии и все проекты хоста. Туда же harness кладёт план текущей
сессии, туда же попали оба мастер-документа. Общий каталог без разделения = гонка на запись.

**2. Локи не работают.** `tmp/claude-locks/` пуст во всех worktree — за два месяца не создано
ни одного лока. Причина структурная: `pre-edit-lock.sh` подключён на `PreToolUse Edit|Write`,
но (а) всегда `exit 0`, то есть только предупреждает, и (б) создавать локи надо вручную, чего
никто не делает. Механизм существует на бумаге и не защищает ничего.

**Цель:** у каждой сессии свой каталог планов под git; локи ставятся автоматически и физически
блокируют правку файла, занятого другой сессией.

**Решения приняты пользователем:** планы — в репо, per-session; локи — блокирующие;
жизненный цикл — авто-постановка на правке, авто-снятие на коммите.

---

## Ключевое проектное решение: ключ лока — путь, а не имя файла

Текущая схема кладёт лок в `tmp/claude-locks/<basename>.lock`. В репо **35 дублирующихся
basename** (`base.rb`, `client.rb`, `base_controller.rb`, `_form.html.erb`, `index.html.erb`…).
В предупреждающем режиме ложное срабатывание — это шум; в блокирующем — это заблокированная
правка `app/services/yandex/client.rb`, потому что другая сессия держит
`app/services/topnlab/client.rb`. Поэтому ключ = repo-relative путь со слэшами, заменёнными на `%`:

```
tmp/claude-locks/app%models%property.rb.lock
```

Существующих локов нет (0 во всех worktree), так что смена формата ничего не ломает.

---

## Часть 1. Планы per-session

### Раскладка

```
.claude/plans/
  _shared/                          ← мастер-документы, меняются только через PR
    splendid-imagining-lerdorf.md
    merry-honking-kay.md
  victory/  chat/  seo/  upgrade/   ← планы сессии, каждый со своим .keep
```

Переместить из `/home/q/.claude/plans/` в `.claude/plans/_shared/` оба мастер-документа
(`splendid-imagining-lerdorf.md` 10 КБ, `merry-honking-kay.md` 7 КБ). Глобальный
`~/.claude/plans/` остаётся рабочим буфером harness'а — его путь мы не контролируем.

### Новый hook `.claude/hooks/plan-sync.sh`

`PostToolUse` на `Write|Edit`. Если `tool_input.file_path` лежит внутри `$HOME/.claude/plans/` —
копирует файл в `$CLAUDE_PROJECT_DIR/.claude/plans/<session>/` (session — из marker-файла
`.claude-session`, как в `session-start.sh:15-19`). Плоское копирование, имя сохраняется.

Так план, который harness пишет в глобальный буфер, немедленно оказывается в репо под своей
сессией — попадает в git, виден в PR, переживает переезд. Хук идемпотентный, всегда `exit 0`:
сбой синхронизации плана не должен ломать сессию.

### Обновление ссылок

8 мест выше — заменить `.claude/plans/<файл>.md` → `.claude/plans/_shared/<файл>.md`.
В `CLAUDE.md` добавить абзац о раскладке (per-session каталоги + `_shared` только через PR).

---

## Часть 2. Блокирующие локи

### `.claude/hooks/pre-edit-lock.sh` (переписать)

Сейчас: cross-worktree скан по basename, всегда `exit 0`.
Станет: cross-worktree скан по path-ключу с реальной блокировкой.

Логика:
1. Достать `file_path` (jq с fallback на grep — оставить как есть, строки 19-25).
2. Привести к repo-relative. **Если файл вне репо — пропустить** (`exit 0`): иначе хук
   заблокирует правку самого plan-файла в `~/.claude/plans/`.
3. Ключ = путь, `/` → `%`.
4. Скан всех worktree через `git worktree list --porcelain` (существующая логика, строка 33).
5. Найден лок чужой сессии:
   - возраст > TTL (2ч) → удалить, предупредить, пропустить;
   - иначе → сообщение в stderr и **`exit 2`** (Claude Code блокирует вызов и отдаёт stderr модели).
6. Лок своей сессии — не блокирует никогда.
7. Аварийный обход: `CLAUDE_LOCK_BYPASS=1`.

Формат сообщения при блоке — с указанием, кто держит, сколько времени и как снять:

```
⛔ app/models/property.rb занят сессией chat
   worktree: /home/q/victory-chat
   с 08.08.26 20:14 (12 мин назад), task=extract concerns
   Снять: bin/lock-clean --force   |   обойти: CLAUDE_LOCK_BYPASS=1
```

### `.claude/hooks/post-edit-lock.sh` (новый)

`PostToolUse` на `Write|Edit`: создаёт (или обновляет mtime) лок на только что изменённый файл
в `tmp/claude-locks/` **своего** worktree. Метаданные — `session`, `worktree`, `path`, `started`,
`pid`, `task`. Даты — `dd.MM.yy` по конвенции проекта. Всегда `exit 0`.

Это ядро решения: ручная постановка провалилась (0 локов за 2 месяца), автоматическая
не требует от сессии ничего.

### Снятие на коммите

`.githooks/post-commit` (новый, отслеживается git) + `bin/install-git-hooks` (новый, ставит
symlink в `.git/hooks/`). Для каждого файла из `git diff-tree --no-commit-id --name-only -r HEAD`
удаляет соответствующий лок в текущем worktree.

Важно: `.git/hooks` лежит в common dir (`/home/q/victory/.git`, `core.hooksPath` не задан),
то есть хук общий для всех 5 worktree — это и нужно. Сейчас там нет ни одного не-sample хука.
`.git/hooks` под git не попадает, поэтому нужен установщик; вызывать его из `session-start.sh`
идемпотентно, чтобы не требовать ручного шага на каждой машине.

### Правка существующих утилит под новый ключ

- `bin/lock-clean` — TTL-логика остаётся, обновить разбор имён (`%` → `/`) для читаемого вывода.
- `bin/check-cross-worktree-locks` — принимать путь, считать ключ так же, как хук.
  ⚠️ Файл создан в этой сессии и ещё не закоммичен.

### `.claude/settings.json`

Добавить в существующие массивы: `plan-sync.sh` и `post-edit-lock.sh` в `PostToolUse`
(рядом с `post-edit-rubocop.sh`), `pre-edit-lock.sh` в `PreToolUse` уже есть.

---

## Часть 3. Документация

- `.claude/skills/session-coordination/SKILL.md` — секция lock-file: переписать под авто-режим
  и блокировку, убрать инструкции по ручному `echo ... > lock`, поправить пример ключа.
  Там же — раскладка планов.
- `.claude/sessions/README.md` — то же самое.
- `CLAUDE.md` — короткий абзац: план пишется в свой per-session каталог; локи автоматические
  и блокирующие; аварийный обход.

---

## Риски

**Дедлок при падении сессии.** Три страховки: TTL 2ч (истёкший лок снимается автоматически при
первой же попытке правки), `bin/lock-clean --force`, `CLAUDE_LOCK_BYPASS=1`.

**Ложная блокировка** — снята переходом на path-ключ.

**Шум от авто-локов.** Лок будет на каждый отредактированный файл. Это не проблема, пока снятие
работает: post-commit + TTL. Если сессия правит и долго не коммитит — файлы остаются занятыми,
что и является задуманным поведением.

---

## Проверка

```bash
cd /home/q/victory-upgrade

# 1. Планы: раскладка на месте, мастер-доки переехали, ссылки не битые
ls .claude/plans/{_shared,victory,chat,seo,upgrade}
grep -rn '\.claude/plans/' CLAUDE.md .claude/ | grep -v '_shared\|plans/<session>' # должно быть пусто

# 2. plan-sync: правка файла в ~/.claude/plans → копия в своём каталоге
#    (проверяется следующим же входом в plan mode)

# 3. Лок ставится автоматически
#    отредактировать любой файл → появится:
ls tmp/claude-locks/

# 4. Блокировка чужого лока — эмулируем лок от chat
mkdir -p /home/q/victory-chat/tmp/claude-locks
printf 'session=chat\nworktree=/home/q/victory-chat\npath=app/models/property.rb\nstarted=%s\ntask=test\n' \
  "$(date -Iseconds)" > '/home/q/victory-chat/tmp/claude-locks/app%models%property.rb.lock'
#    → попытка Edit app/models/property.rb должна быть ОТКЛОНЕНА с указанием chat
#    → Edit app/services/topnlab/client.rb (дубль basename с yandex/client.rb) должен ПРОЙТИ

# 5. Обход и снятие
CLAUDE_LOCK_BYPASS=1 # → правка проходит
bin/check-cross-worktree-locks app/models/property.rb   # → покажет лок chat
rm '/home/q/victory-chat/tmp/claude-locks/app%models%property.rb.lock'

# 6. Снятие на коммите
bin/install-git-hooks && git commit -am 'test' && ls tmp/claude-locks/  # локи закоммиченных файлов ушли

# 7. Ничего не сломали
bin/rb bundle exec rubocop --parallel
```

---

## Не входит в этот план (но лежит в рабочем дереве)

В этой сессии уже сделан и проверен изолированный Ruby-box (`docker-compose.ruby.yml`, `bin/rb`,
`ARG RUBY_VERSION` в `Dockerfile`, `bin/check-cross-worktree-locks`) — закрывает отсутствие
менеджера версий Ruby для всех 4 сессий. Прогон: `895 examples, 29 failures`. Эти файлы не
закоммичены; их стоит развести с локами/планами по отдельным коммитам в одном PR.

Также остаются незакрытыми хвосты миграции worktree: `origin/dev/upgrade` разошёлся с локальной
веткой (ahead 1 / behind 1 после squash-мержа PR #9), `.env` есть только в upgrade-worktree
(остальным трём нужен для `bin/rb`), `activeContext.md` указывает на давно закрытую ветку
`claude/currency-converter-app-9Ljw6`.
