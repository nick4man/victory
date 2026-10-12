# Конвейер выкатки на прод (фаза 3, с 12.10.26)

Путь изменения: PR → CI (`lint.yml`) → merge в `main` → `build.yml` собирает
образы `sha-<7>` в GHCR и автоматически выкатывает на staging (smoke +
Playwright) → человек подтверждает выкатку на прод → `deploy.yml` дёргает
`bin/prod-gate` по SSH **через bastion на vps1** → `bin/rollout` на хосте
делает pull, бэкап, health, smoke и `prod-mark` → внешние проверки с раннера,
при не-200 — алерт в Telegram.

Принцип «тянет, не толкает»: у CI нет ни docker.sock, ни shell на проде.
Единственное, что он умеет, — forced command `prod-gate`, а та умеет только
`bin/rollout <тег> --yes`. Подтверждение человека — GitHub environment
`production` с required reviewers: джоба `deploy` встаёт на паузу до Approve.

Топология SSH: victory снаружи недоступен (внешний :22 роутера → vps1), поэтому
раннер ходит двумя хопами: **bastion на vps1** (ключ `bastion-ci`, ограничен
`permitopen="10.10.0.122:22",no-pty` — только TCP-проброс до victory:22, без
shell и без exec) → **victory по WireGuard** (`10.10.0.122`, ключ `prod-ci` +
`prod-gate`). Компрометация bastion-ключа не даёт ни shell на vps1, ни выкатку
(нужен ещё prod-ключ); компрометация prod-ключа без bastion не даёт даже
TCP-доступа до victory.

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
2. **Bastion-ключ для vps1** (victory снаружи по SSH недоступен — внешний :22
   роутера ведёт на vps1, поэтому раннер идёт через vps1 по WireGuard):
   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/vps1-bastion-ci -N ''
   ```
   Публичный — в `~/.ssh/authorized_keys` **на vps1** с ограничением на один
   проброс (не строка с `command=`: ProxyJump нужен TCP-forward, а не exec):
   ```
   permitopen="10.10.0.122:22",no-agent-forwarding,no-pty,no-user-rc ssh-ed25519 AAAA... bastion-ci
   ```
   Приватный — в секрет окружения `BASTION_SSH_KEY`.
3. **GitHub environment `production`** (Settings → Environments → New):
   - Required reviewers: владелец;
   - секреты окружения: `PROD_SSH_KEY` (п.1), `BASTION_SSH_KEY` (п.2),
     `ALERT_TG_BOT_TOKEN` и `ALERT_TG_CHAT_ID` (work-bot и рабочий чат — для
     алертов post-check);
   - переменные окружения: `PROD_HOST` (`10.10.0.122` — WG-адрес victory),
     `PROD_SSH_USER`, `BASTION_HOST` (внешний IP vps1), `BASTION_SSH_USER`.
   Через CLI: `gh api repos/nick4man/victory/environments/production -X PUT`
   (reviewers настраиваются в UI или через API environments).
4. Проверка связки без выкатки: `ssh -J <bastion_user>@<bastion_host>
   -i ~/.ssh/victory-prod-ci <prod_user>@10.10.0.122 "rollout BOGUS!"` →
   ответ `prod-gate: некорректный тег` значит, что оба ключа, bastion-ограничение,
   WG и gate работают, а побочек нет. ⚠️ Не проверяй строчными «осмысленными»
   словами вроде `bogus` — они проходят regex тега, и выкатка случится
   по-настоящему (инцидент 12.10.26, см. `docs/runbooks/cutover-1.0.md`).

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
  victory (workflow начнёт падать на SSH — заметно и безопасно). Достаточно
  удалить и только bastion-строку на vps1: без проброса prod-ключ недостижим.
- Ротация `PROD_SSH_KEY`: новый ключ п.1, замена секрета, удаление старого из
  `authorized_keys`. При компрометации — сначала удаление строки, потом всё
  остальное. Ротация `BASTION_SSH_KEY` — аналогично по п.2.

## Метрики поставки

Журнал уже есть: теги `deploy/<dd.MM.yy-HHmm>` и ветка `prod`. Раз в месяц
сводка: время merge→prod (цель < суток), число выкаток, доля откатов/срочных
правок (держать < 15 %). Источник цифр — `git log` по тегам `deploy/*` и
история прогонов Deploy production.
