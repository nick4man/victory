# Конвейер выкатки на прод (фаза 3, с 12.10.26)

Путь изменения: PR → CI (`lint.yml`) → merge в `main` → `build.yml` собирает
образы `sha-<7>` в GHCR и автоматически выкатывает на staging (smoke +
Playwright) → человек подтверждает выкатку на прод → `deploy.yml` дёргает
`bin/prod-gate` по SSH → `bin/rollout` на хосте делает pull, бэкап, health,
smoke и `prod-mark` → внешние проверки с раннера, при не-200 — алерт в
Telegram.

Принцип «тянет, не толкает»: у CI нет ни docker.sock, ни shell на проде.
Единственное, что он умеет, — forced command `prod-gate`, а та умеет только
`bin/rollout <тег> --yes`. Подтверждение человека — GitHub environment
`production` с required reviewers: джоба `deploy` встаёт на паузу до Approve.

## Первичная настройка (один раз)

1. **SSH-ключ на хосте victory** (отдельный от staging-ключа — ревью #111, P1):
   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/victory-prod-ci -N ''
   ```
   Публичный — в `~/.ssh/authorized_keys` с принудительной командой:
   ```
   command="/home/q/victory/bin/prod-gate",no-agent-forwarding,no-port-forwarding,no-pty,no-user-rc ssh-ed25519 AAAA... prod-ci
   ```
   Приватный — в секрет окружения `PROD_SSH_KEY`.
2. **GitHub environment `production`** (Settings → Environments → New):
   - Required reviewers: владелец;
   - секреты окружения: `PROD_SSH_KEY` (п.1), `ALERT_TG_BOT_TOKEN` и
     `ALERT_TG_CHAT_ID` (work-bot и рабочий чат — для алертов post-check);
   - переменные окружения: `PROD_HOST`, `PROD_SSH_USER`.
   Через CLI: `gh api repos/nick4man/victory/environments/production -X PUT`
   (reviewers настраиваются в UI или через API environments).
3. Проверка связки без выкатки: заведомо старый тег выкатывать НЕ надо —
   достаточно `ssh -i ~/.ssh/victory-prod-ci <user>@<host> "rollout bogus"`:
   ответ `prod-gate: некорректный тег` значит, что ключ, gate и валидация
   работают, а побочек нет.

## Эксплуатация

- **Выкатка**: Actions → Deploy production → Run workflow → поле `tag` пустое
  (возьмётся последний зелёный sha из Build images) или явный тег → Approve в
  environment → дождаться `post-check`. Время — тот же простой 30–60 с, что у
  ручного `bin/rollout` (решение Р8 релиза 1.0).
- **Вручную на хосте** остаётся полноценным путём: `bin/rollout <тег>` —
  CI-вариант лишь вызывает его же.
- **Откат**: `bin/rollout <предыдущий тег>` на хосте (теги — `git tag -l 'v*'`,
  `docker image ls`, журнал — теги `deploy/*`). Автоотката нет намеренно.
  Миграции назад не едут — см. `docs/runbooks/release.md`, раздел «Откат».
- **Что выкачено**: `.env.deploy` на хосте + ветка `prod` и теги `deploy/<дата>`
  в GitHub (их ставит `bin/prod-mark` внутри rollout).

## Ротация и отзыв

- Отзыв доступа CI к проду — удалить строку ключа из `authorized_keys` на
  victory (workflow начнёт падать на SSH — заметно и безопасно).
- Ротация `PROD_SSH_KEY`: новый ключ п.1, замена секрета, удаление старого из
  `authorized_keys`. При компрометации — сначала удаление строки, потом всё
  остальное.

## Метрики поставки

Журнал уже есть: теги `deploy/<dd.MM.yy-HHmm>` и ветка `prod`. Раз в месяц
сводка: время merge→prod (цель < суток), число выкаток, доля откатов/срочных
правок (держать < 15 %). Источник цифр — `git log` по тегам `deploy/*` и
история прогонов Deploy production.
