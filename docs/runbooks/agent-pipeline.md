# Агентный конвейер: issue → kanban → PR → dev/* → main

Цель: задачи ставятся как GitHub issue, Hermes-агенты их делают, Kimi ревьюит,
CI проверяет, PR сам вливается в интеграционную ветку `dev/*`. Человек нужен
в двух местах: написать issue и смержить `dev/*` → `main`.

## Поток

```
issue (форма .github/ISSUE_TEMPLATE/task.yml|bug.yml, метка agent:hermes)
  │  cron Hermes на хосте victory, каждые 5 мин: ~/.hermes/scripts/gh-issues-to-kanban.py
  ▼
kanban-карточка (доска `victory`, assignee kb-backend, worktree /home/q/victory/.worktrees/<id>)
  │  воркер: ветка kanban/issue-<N>-<slug> от origin/<dev/*>, код + spec, bin/rb rspec,
  │  PR → dev/* с метками automerge + agent:hermes, `Closes #N` в теле
  ▼
PR: lint.yml + build.yml (на dev/* тоже) + kimi.yml «Kimi Review»
  │  ревью заканчивается строкой VERDICT: MERGE | VERDICT: CHANGES
  ▼
automerge.yml (workflow_run): все check runs зелёные + VERDICT: MERGE на текущем head
  → squash-merge в dev/*, ветка удаляется, issue закрывается по Closes #N
  ▼
dev/* → main: PR открывает человек, мержит человек (main = прод, деплой — deploy.yml).
```

## Направления (dev/*)

| Ветка | Что туда идёт |
|---|---|
| `dev/chat` | чат-виджет, Telegram-боты (work_bot/client_bot), лиды |
| `dev/seo` | лендинги, справочник ЖК, публичный сайт, SEO |
| `dev/upgrade` | зависимости, Rails/Ruby, CI, инфраструктура |

Направление выбирается в форме issue (поле «Направление»). `dev/*` должны
регулярно пересобираться от `main` — после каждого мержа `dev/x → main`
делайте `git checkout dev/x && git merge --ff-only main && git push`, иначе
PR агентов начнут конфликтовать.

## Правила для агентов (что проверяет automerge)

- head-ветка только `kanban/*`, `claude/*`, `kimi/*`; base только `dev/*`. В `main` автослияния нет никогда.
- Метка `automerge` обязательна, метка `needs-human` блокирует.
- Обязательные зелёные проверки: RuboCop, RSpec, Brakeman, bundler-audit,
  «Учёт и границы служб», «Образ web (+ zeitwerk:check)», «Kimi Review».
- Вердикт Kimi берётся из последнего комментария `github-actions[bot]`,
  содержащего `VERDICT:`; он должен упоминать короткий sha текущего head —
  иначе считается устаревшим и ждём новое ревью (новый push в PR запускает его сам).
- Конфликт с base → бот пишет комментарий «нужен ребейз», не мержит.

## Эксплуатация

```bash
# что в очереди
hermes kanban --board victory list
hermes kanban --board victory show <id>
# карточка застряла (blocked: needs_input) — ответить комментарием в issue, затем
hermes kanban --board victory unblock <id> --reason "уточнил в issue"
# снять задачу с конвейера — убрать метку agent:hermes и заархивировать карточку
gh issue edit <N> --remove-label agent:hermes && hermes kanban --board victory archive <id>
# лог синка issue→kanban
hermes cron list
```

Секреты: воркерам нужен `GH_TOKEN` в `~/.hermes/profiles/kb-*/.env` (gh-логин
профиля); без него `gh pr create` упадёт, карточка заблокируется после 2 попыток.
