# Агентный конвейер: issue → kanban → PR → dev/* → main

Дата последней проверки: 04.11.26

Цель: задачи ставятся как GitHub issue, Hermes-агенты их делают, Kimi ревьюит,
CI проверяет, PR сам вливается в интеграционную ветку `dev/*`. Человек нужен
в трёх местах: написать issue, после прочтения сменить метку `agent:triage` →
`agent:hermes` (это авторизация запуска), и смержить `dev/*` → `main`.

## Поток

```
сырое пожелание → issue с agent:draft → cron victory-issue-drafts переписывает
  тело по форме и ставит agent:triage (см. «Черновики agent:draft»)
issue (форма .github/ISSUE_TEMPLATE/task.yml|bug.yml) → метка agent:triage
  │  человек проверяет и меняет метку на agent:hermes (это и есть авторизация запуска)
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
  → squash-merge (--match-head-commit) в dev/*, ветка удаляется;
    issue закрывает сам workflow по `Closes #N` из тела PR (closing keywords
    GitHub работают только для default branch, поэтому явно)
  ▼
dev/* → main: PR открывает человек, мержит человек (main = прод, деплой — deploy.yml).
```

## Авторизация запуска

Формы ставят только `agent:triage`. Метку `agent:hermes` ставит владелец после
прочтения issue — хостовый синк берёт только её и дополнительно проверяет
автора (`author_association` OWNER/MEMBER/COLLABORATOR) — issue чужого автора
с `agent:hermes` получает `needs-human` и не идёт в работу.

## Черновики `agent:draft`

Сырое пожелание заводится как issue с меткой `agent:draft` (форма-черновик или
вручную). Cron Hermes `victory-issue-drafts` (скилл `victory-issue-writer`)
переписывает тело по форме task/bug, снимает `agent:draft`, ставит
`agent:triage` и оставляет комментарий. Владелец проверяет текст и меняет
`agent:triage` → `agent:hermes` (см. «Авторизация запуска»). Если запрос
неясен, агент задаёт вопросы комментарием и ставит `needs-human`; метку
`agent:hermes` агент никогда не ставит сам.

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
- Вердикт Kimi: job «Kimi Review» читает транскрипт агента на раннере
  (`execution_file` action'а — туда пишет только он сам), берёт последние
  `HEAD: <sha>` / `VERDICT: …` и публикует артефакт `kimi-verdict`
  (HEAD / RUN / VERDICT). automerge читает только этот артефакт из run
  `.github/workflows/kimi.yml` с event=pull_request на текущем head —
  комментарии бота не читаются вовсе. Новый push → новое ревью → новый артефакт.
- PR, меняющий что-либо в `.github/` (workflow, формы), автослиянию не
  подлежит: снимается `automerge`, ставится `needs-human`. Иначе PR мог бы
  переписать проверки, которыми сам проверяется.
- Внешние проверки (CodeQL, GitGuardian) могут финишировать последними —
  automerge слушает ещё и `check_suite: completed` и ждёт pending до 20 мин.
- Merge атомарен к проверенному head (`--match-head-commit`); если head уехал —
  выход, следующий прогон проверит заново.
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

## Проверено

- 04.11.26 — первый успешный прогон конвейера, issue #148.
- 04.11.26 — повторный прогон после hardening automerge, issue #152 (после #151).
