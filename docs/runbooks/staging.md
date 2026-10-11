# Staging (с 11.10.26)

Стенд на том же хосте `victory`, но полностью изолированный compose-проект
`victory-staging`: свои тома (`victory-staging_pgdata`, `victory-staging_redisdata`),
свой storage (`/home/q/victory-staging-storage`), свой `RAILS_ENV=staging`
(`config/environments/staging.rb` = production + почта выключена). Поднимаются
только `db`, `redis`, `web` — sidekiq и службы `services/*` на staging не нужны.

Назначение: каждый merge в `main` автоматически выкатывается сюда и проверяется
smoke + Playwright (workflow `.github/workflows/build.yml`), прежде чем человек
подтвердит выкатку на прод. Контур поставки целиком — `docs/ci-cd-pipeline-plan.md`.

## Первичная настройка (один раз)

1. **`.env.staging`** в `/home/q/victory` из `.env.staging.example` — все секреты
   НОВЫЕ (`openssl rand -hex 64` для SECRET_KEY_BASE, `-hex 24` для ADMIN_TOKEN),
   внешние интеграции остаются заглушками `disabled-in-staging`.
2. **Traefik на роутере** (вне репозитория): маршрут `staging.dev.victory62.org` →
   `хост-victory:3002`, сертификат `*.dev.victory62.org` уже есть, middleware
   basic-auth обязателен. Учётку записать в секрет репозитория `STAGING_BASIC_AUTH`
   (формат `user:pass`).
3. **SSH-ключ для CI**: `ssh-keygen -t ed25519 -f ~/.ssh/victory-staging-ci -N ''`,
   публичный — в `~/.ssh/authorized_keys` с принудительной командой (ключ умеет
   только выкатку **на staging**, ничего больше — в т.ч. НЕ умеет `bin/rollout`,
   это прод; прод-выкатка через CI — отдельная фаза и отдельный ключ):
   ```
   command="/home/q/victory/bin/deploy-gate",no-agent-forwarding,no-port-forwarding,no-pty,no-user-rc ssh-ed25519 AAAA... staging-ci
   ```
   Приватный — в секрет репозитория `STAGING_SSH_KEY`.
4. **Переменные репозитория** (Settings → Variables): `STAGING_ENABLED=true`,
   `STAGING_HOST`, `STAGING_SSH_USER`. Пока `STAGING_ENABLED` не задана, джобы
   staging в build.yml пропускаются.
5. Первый запуск вручную: `bin/staging-rollout sha-<7 последнего коммита main>`,
   затем данные: `bin/staging-reset` (свежий gpg-дамп прода → staging-БД,
   с санитизацией `users.tg_user_id`).

## Эксплуатация

- **Выкатка**: автоматически из CI после каждого merge в main. Вручную:
  `bin/staging-rollout <тег>`. Что выкачено — `.env.staging-deploy`.
- **Данные**: `bin/staging-reset [путь-к-дампу]` — пересоздаёт staging-БД из
  бэкапа прода и перезапускает web (миграции доезжают через `db:prepare`
  в entrypoint). Регулярность — по необходимости перед проверками; в cron
  не ставить, restore гасит web стенда на пару минут.
- **Логи**: `docker compose -p victory-staging logs -f web`.
- **Smoke локально**: `bin/smoke http://127.0.0.1:3002 <ADMIN_TOKEN из .env.staging>`.
  Снаружи через Traefik: `SMOKE_BASIC_AUTH='user:pass' bin/smoke https://staging.dev.victory62.org`.
- **Полный снос**: `docker compose -p victory-staging down -v &&
  rm -rf /home/q/victory-staging-storage`.

## Что на staging выключено

- Почта (`delivery_method = :test` в staging.rb), Telegram-боты, Topnlab,
  LLM-шлюз, Sentry — заглушками в `.env.staging`. Проверка интеграций наружу
  на стенде не проводится: контракты проверяют спеки и smoke прода.
- sidekiq: cron-задачи из копии прода ходили бы по внешним API (Topnlab sync
  каждые 30 мин) — не поднимаем.

## Ограничения

- Visual regression (пиксельные снапшоты `tests/visual/*-snapshots/`) против
  staging НЕ гоняется: базовые PNG сняты с dev-данными. Против staging работает
  только навигационный `staging-smoke.spec.ts`. TD-4 из ROI-плана (VR в CI)
  закрывается отдельно — прогоном против локального dev-сервера в CI.
- Staging делит хост с продом: нагрузочные проверки на нём не делаем.
