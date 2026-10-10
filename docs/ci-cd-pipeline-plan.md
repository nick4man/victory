# План: завершение CI/CD-пайплайна (worktree `~/victory-release`, ветка `claude/release-1.0`)

Источники: `docs/superpowers/plans/2026-10-05-release-1-0-compose.md` (план релиза 1.0),
`docs/runbooks/{release,cutover-1.0}.md`, `/home/q/2026-10-05 Архитектура разработки.md`
(ступени 1–2, раздел 7), верификация состояния 10.10.26.

## Состояние на сейчас (верифицировано)

- **PR #109 OPEN**, CI 11/11 зелёный, ревью сессией `/code-review` пройдено (правки в `ab75754`), mergeable. **Не слит.**
- **Прод НЕ переключён**: работает старый dev-стек (bind-mount `./:/app`, `RAILS_ENV=development`), образы `1.0.0` собраны локально 05.10, push в GHCR неподтверждён. Cutover (части A и B) не выполнялся.
- Повторный RC-прогон после правок force_ssl **не задокументирован** — висячая строка в `cutover-1.0.md:172`.
- CI (`.github/workflows/lint.yml`) — только проверки; **сборки/пуша образов нет**, dependabot нет, GitHub environments нет, секретов для CD нет.
- Задел под пайплайн уже есть: теги `sha-<7>` в `bin/release`, `RAILS_ENV_FILE`, `WEB_BIND`/`WEB_PORT` в compose, staging-блок в `database.yml:100-117`, `PLAYWRIGHT_BASE_URL` в `playwright.config.ts:39`, маршрут `*.dev.victory62.org` в Traefik (по архитектурному документу — подтвердить на месте).
- Зафиксированные принципы (нарушать нельзя): **выкатка тянет, а не толкает** — у CI нет docker.sock прода; запуск с GitHub — только SSH-ключ с принудительной командой; простой 30–60 с допустим (решение Р8); Kamal — ступень 2, отдельное решение.

Целевой пайплайн (из архитектурного документа, ступень 2):

```
PR → CI (lint+rspec, уже есть) → merge в main → сборка образов (тег sha-<7>) → GHCR
  → staging автоматически → smoke + Playwright → подтверждение человеком →
  → прод забирает образ (bin/rollout) → мониторинг/алерт
```

---

## Фаза 0. Завершить релиз 1.0 (предусловие, без него пайплайн не о чем выкатывать)

1. **Повторный RC-прогон** по обновлённым правилам из `cutover-1.0.md:163-170`
   (`DISABLE_SSL` не ставить; проверки: POST на `/webhooks/zhk_ingest` без
   `X-Forwarded-Proto` → 401 не 301; GET `/` → 301). Результат дописать в
   `cutover-1.0.md` вместо висячей строки :172. Коммит в `claude/release-1.0`.
2. **Merge PR #109** (после п.1; CI уже зелёный).
3. **Cutover часть A** по runbook (окно ночью MSK, сразу после Topnlab sync):
   предусловия (`.env`: `DATABASE_NAME=viktory_realty_development`, `ADMIN_TOKEN`,
   `SECRET_KEY_BASE`, сгенерировать `ZHK_INGEST_TOKEN` и разнести в `.env`+`.env.zhk`),
   `bin/backup all` → `docker compose stop web sidekiq` → `bin/rollout 1.0.0 --yes --skip-backup`
   → внешние проверки → логи 5 мин → `git tag v1.0.0` + push (через `http.version=HTTP/1.1`).
4. **Cutover часть B** (конвейер с chat, профиль `conveyor`) — отдельным окном после
   суток стабильной работы A, строго по runbookу (новый `CHANNEL_BOT_TOKEN` через
   BotFather `/revoke` — старый утёк).
5. **Зачистка**: RC-стек `victory-rc down -v` + `rm -rf /home/q/victory-rc-storage`;
   стек `victory-victory` (дрейф, postgis35) — погасить и разобрать.
6. **Post-release PR `claude/post-release-1.0-notes`** (задача 8/10 плана релиза):
   синхронизировать `CLAUDE.md`, `.claude/memory/{activeContext,techContext}.md`,
   `.github/workflows/claude.yml` (устранить противоречие «деплой ручной/автоматический»),
   корневой `AGENTS.md` (в main-чекауте уже новый — перенести расхождения).

Выход: прод на образе `1.0.0`, `bin/rollout` — штатный механизм выкатки, документы сходятся с реальностью.

---

## Фаза 1. Сборка образов в CI (PR `claude/ci-build-images`)

Новый `.github/workflows/build.yml` (lint.yml не трогаем):

1. **Триггеры**: `push` в `main` (build+push), `pull_request` в `main` (только build web, без push — проверка собираемости), `workflow_dispatch`. `permissions: contents: read, packages: write`. Concurrency-группа по ref, как в lint.yml.
2. **Login GHCR**: `docker/login-action` с `GITHUB_TOKEN` (владелец репо = владелец ghcr-организации `nick4man`, из коробки).
3. **Матрица образов**: `web` (корневой `Dockerfile`, target `prod`), `conveyor`/`publisher`/`zhk-registry` (Dockerfile в `services/*/`). Службы собирать только при изменениях в их каталогах (`dorny/paths-filter` или `git diff` шаг) — они редко меняются; `web` — всегда. `docker/build-push-action@v6`, `cache-from/to: type=gha,scope=<svc>`.
4. **Теги**: `sha-<7>` — всегда; `<VERSION>` — только когда коммит меняет файл `VERSION` (проверка `git diff HEAD~1 --name-only -- VERSION`). Так CI покрывает и «каждый мерж — артефакт», и релизы.
5. **Production-загрузка в CI** (пункт из ступени 1): после сборки web —
   `docker run --rm -e RAILS_ENV=production -e SECRET_KEY_BASE=not-a-secret-ci-boot-check -e TELEGRAM_BOT_TOKEN=not-a-token-... -e OMNIROUTE_*=... <img> bin/rails zeitwerk:check` — ловит production-only ошибки eager load до выкатки. Заглушки писать явно «не-токенными» (GitGuardian).
6. **`bin/release` — режим довеса тега без сборки**: новый флаг `--from-ci` —
   проверить наличие `sha-<7>` в реестре (`docker buildx imagetools inspect`), натянуть
   на него `<VERSION>` (`imagetools create -t`) без локальной сборки. Локальная сборка
   остаётся fallback'ом. Обновить `docs/runbooks/release.md`: релиз = bump VERSION →
   PR → merge → CI собрал оба тега (или `bin/release --from-ci` для старого sha).
7. Спеки/проверки: workflow синтаксически проверяется actionlint'ом локально
   (`which actionlint` или через `docker run rhysd/actionlint`), иначе — прогон на PR.

Выход: каждый merge в main → образ `sha-<7>` в GHCR; смена VERSION → релизный тег.

---

## Фаза 2. Staging + smoke + Playwright (PR `claude/staging`)

1. **`docker-compose.staging.yml`** (override, проект `victory-staging`):
   - web: `RAILS_ENV=staging`, порт `127.0.0.1:3002:3000`, свой `STORAGE_DIR`
     (`/home/q/victory-staging-storage`), labels Traefik на `staging.dev.victory62.org`
     (маршрут/сертификат `*.dev.victory62.org` подтвердить на роутере заранее — п.5
     раздела 7 архитектурного документа) + basic-auth middleware Traefik.
   - **Свои** postgres (тот же `Dockerfile.postgres`, БД `viktory_realty_staging`) и
     redis-контейнеры — изоляция от прода полная, не shared-база.
   - sidekiq — не поднимать (на staging нечего кронить; Topnlab sync против боя с
     staging-базы не нужен) или поднимать с отключённым cron — решить при реализации,
     зафиксировать в SERVICE-заметке runbook'а.
2. **`config/environments/staging.rb`**: копия production с послаблениями
   (`force_ssl = false` за basic-auth, свой `cache_store` namespace, `config.hosts`
   под staging-домен). Заглушки внешних токенов — как в `.env.rc` (`=disabled-in-staging`).
3. **`.env.staging.example`** + боевой `.env.staging` на хосте вне git.
4. **`bin/staging-reset`**: restore последнего gpg-дампа (`bin/backup` уже шифрует) в
   staging-БД с последующим `UPDATE`-санитайзером (чистка tg_user_id/телефонов в
   копии — PII на стенде не нужны). Запуск вручную/по cron хоста, не в CI.
5. **Автовыкатка на staging**: джоба в `build.yml` после push — SSH на хост
   `victory`, forced command `bin/staging-rollout <sha-тег>` (новый тонкий скрипт:
   pull → up -d → health → `bin/smoke https://staging.dev.victory62.org`).
   Отдельный SSH-ключ только для staging (секрет `STAGING_SSH_KEY`), в
   `authorized_keys` — `command="/home/q/victory/bin/deploy-gate staging",no-pty,...`
   (обёртка `bin/deploy-gate` — ниже, фаза 3, ставится раньше и переиспользуется).
6. **Playwright против staging**: джоба в `build.yml` после staging-rollout —
   `npm ci`, `PLAYWRIGHT_BASE_URL=https://staging.dev.victory62.org npx playwright test`,
   `actions/upload-artifact` на `test-results/` при падении (пересекается с TD-4 из
   ROI-плана — закрывает его в правильном месте: против staging, не против локалки).
7. Runbook `docs/runbooks/staging.md`: как поднять, как ресетить данные, что
   выключено (вебхуки наружу, TG-боты, SMTP).

Выход: каждый merge в main через ~10–15 мин проверен smoke+Playwright на staging.

---

## Фаза 3. Выкатка на прод с подтверждением (PR `claude/cd-prod-deploy`)

Принцип «тянет, не толкает» сохраняется: единственное, что умеет CI — дёрнуть
forced command, который запускает `bin/rollout` (он сам делает pull, бэкап, smoke).

1. **`bin/deploy-gate`** (новый, в репо): валидирует `$SSH_ORIGINAL_COMMAND` —
   допустимы только `rollout <тег>` (тег — `^[0-9a-z.\-]{1,40}$`) и
   `staging-rollout <тег>`; всё остальное — отказ. Установка в `authorized_keys`
   отдельного пользователя/ключа на хосте — шаг runbook'а, не скрипта.
2. **GitHub environment `production`** с required reviewers (владелец) — настройка
   через `gh api`/UI; зафиксировать в runbook'е. Секреты окружения: `PROD_SSH_KEY`,
   `PROD_HOST`, `PROD_SSH_USER`.
3. **`.github/workflows/deploy.yml`**:
   - триггер `workflow_dispatch`, input `tag` (по умолчанию — последний зелёный
     sha-тег из build.yml, показывать в summary);
   - job `deploy` с `environment: production` (=> пауза на подтверждение человеком)
     → SSH `bin/deploy-gate rollout <tag>` → вывод rollout в лог джобы
     (`bin/rollout` уже: backup → pull → up → health → smoke → sidekiq → prod-mark);
   - job `post-check`: внешние проверки с раннера — `https://victory62.org/health`,
     `/health/database`, главная → 200; при не-200 — алерт в Telegram work-bot
     (секрет `ALERT_TG_BOT_TOKEN`/`ALERT_TG_CHAT_ID`) — закрывает TD-5 из ROI-плана.
4. **Runbook** `docs/runbooks/deploy-pipeline.md`: полный цикл PR→прод, как
   откатить (`bin/rollout <предыдущий>` руками на хосте — автоотката нет намеренно),
   как завести ключи, ротация `PROD_SSH_KEY`.
5. **Метрики поставки**: журнал уже есть (теги `deploy/<дата>` от `prod-mark`,
   ветка `prod`). Добавить в runbook ежемесячную сводку: merge→prod, число выкаток,
   откаты (<15 %).

Выход: выкатка = нажать «Approve» в GitHub; простой 30–60 с (Р8); откат — прежний
`bin/rollout <старый тег>`.

---

## Фаза 4. Гигиена конвейера (отдельные PR, параллельно фазам 1–3)

1. **`strong_migrations`** в Gemfile + пара правил в CI-комментарии (блокирует
   опасные миграции на CI). Миграции в два шага — правило ревью, записать в
   `AGENTS.md`/`systemPatterns.md`.
2. **Спек обхода публичных GET-маршрутов** (`spec/requests/public_routes_spec.rb`):
   все GET без параметров → не 5xx. Закрывает класс багов «500 на форме» из аудита.
3. **Крон хоста в репозиторий**: `deploy/crontab.victory` (5 записей:
   Yandex.Webmaster ×3, `kpi:phase_a`, `lock-clean`) + `bin/cron-install`
   (идемпотентная установка через `crontab -`; вызывается из runbook'а, не из CI).
4. **ADR**: `docs/adr/0001-obrazy-i-tegi.md` (образы+sha-теги+GHCR),
   `0002-vykatka-tjanet.md` (pull-модель, forced command), `0003-rollout-vmesto-kamal.md`
   (почему не Kamal сейчас + триггеры пересмотра: простой стал критичен, >1 выкатки/день,
   второй узел). Формат — по странице на решение.
5. **Очистка корневых `*.md`** (исторический шум: STATUS/SUMMARY/FINAL_REPORT/
   DEPLOYMENT* и т.д.) — удалить одним PR, ссылки проверить grep'ом.
6. **Разовые процедуры из `.claude/memory/techContext.md` → `docs/runbooks/`**,
   памяти оставить актуальное состояние (раздел 7 архитектурного документа, п.2).
7. **НЕ в этом треке** (зафиксировать как отдельные задачи): переименование БД в
   `viktory_realty_production` (Р3, гигиена после стабилизации); переезд dev-работы
   на отдельную машину (решение о железе — вне репо); перевод репо в private
   (CodeQL станет платным — решение владельца); ротация трёх ключей из инцидента
   16.09.26 (подтвердить у владельца — п.2 раздела 7).

---

## Порядок и PR-план

| # | PR / действие | Содержание | Блокирует |
|---|---|---|---|
| 0 | (операционно, не PR) | RC-прогон, merge #109, cutover A/B, тег v1.0.0 | всё |
| 1 | `claude/post-release-1.0-notes` | синк документов и memory | — |
| 2 | `claude/ci-build-images` | build.yml + bin/release --from-ci + zeitwerk-чек | 3, 4 |
| 3 | `claude/staging` | compose-override, staging.rb, deploy-gate, staging-rollout, Playwright-джоба | 4 |
| 4 | `claude/cd-prod-deploy` | deploy.yml + environment + post-check алерты | — |
| 5 | `claude/ci-hygiene` (стек мелких) | strong_migrations, public-routes-спек, crontab, ADR, чистка *.md | — |

Каждый PR: зелёный CI → code-review diff → merge (действующее правило).
Bash-скрипты — shellcheck перед коммитом (хук уже есть в `.githooks/`).

## Что осознанно НЕ делаем

- **Kamal 2** — откладываем (ADR-0003 с триггерами пересмотра). `bin/rollout`
  покрывает выкатку/откат; простой 30–60 с разрешён решением Р8.
- CI-раннер на прод-хосте, docker.sock прода, push-to-deploy — запрещены принципом.
- Zero-downtime, PgBouncer, реплики, k8s — до триггеров из `strategicVector.md`.
- Private-репозиторий и платный CodeQL — решение владельца, отдельно.
