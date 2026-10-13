# Переключение прода на релиз 1.0 (production-образы) и переезд конвейера с chat

Хост `victory`, каталог `/home/q/victory` (main checkout, он же compose-проект
`victory`). Простой сайта ≈ 1 мин. Выполнять в тихое время (ночь MSK). Topnlab
sync идёт каждые 30 мин — начать сразу после очередного:
`docker compose logs --since 30m sidekiq | grep TopnlabSyncJob | tail -1`.

Переключение состоит из двух независимых частей: **A** — сайт на production-образ,
**B** — конвейер новостей с chat в compose (профиль `conveyor`). B можно делать
отдельным днём после A.

## Предусловия (общие)

- [ ] PR ветки `claude/release-1.0` слит в `main`, CI зелёный, `/code-review` пройдено.
- [ ] Прогон RC из этого файла — `SMOKE OK`, не старше 3 дней.
- [ ] `git -C /home/q/victory status` чистый; после `git pull --ff-only` чекаут на релизном коммите.
- [ ] `.env` в `/home/q/victory`:
  - `DATABASE_NAME=viktory_realty_development` (`grep -E '^DATABASE_NAME=' .env`) — production-блок
    `database.yml` читает это имя, development-блок его игнорировал; при расхождении новый web
    создаст **пустую** базу и поднимется на ней без единой ошибки;
  - `ADMIN_TOKEN`, `SECRET_KEY_BASE` присутствуют (`grep -cE '^(ADMIN_TOKEN|SECRET_KEY_BASE)=' .env` → 2);
  - **`ZHK_INGEST_TOKEN` присутствует** — на 05.10.26 его в проде **не было** (вебхук отвечал 503,
    реестр ЖК против прода никогда не работал): `grep -cE '^ZHK_INGEST_TOKEN=.+' .env` → 1.
    Сгенерировать: `openssl rand -hex 24`; то же значение — в `.env.zhk`.
- [ ] `.env.zhk` создан из `.env.zhk.example`, токен равен значению в `.env`
  (`diff <(grep -oE '^ZHK_INGEST_TOKEN=.*' .env) <(grep -oE '^ZHK_INGEST_TOKEN=.*' .env.zhk) && echo same`).
- [ ] Образы собраны: `bin/release --check` показывает 1.0.0 и sha релизного коммита;
  `docker image ls ghcr.io/nick4man/victory-web` содержит `1.0.0`.
- [ ] Свежий бэкап: `bin/backup all` — не старше часа.

## A. Сайт на production-образ

1. Точек невозврата нет: всё ниже откатывается командами из раздела «Откат A».
2. Остановить старые web и sidekiq (освобождает :3000) — сайт недоступен с этого момента:
   `docker compose stop web sidekiq`
3. Выкатить: `bin/rollout 1.0.0 --yes --skip-backup` (бэкап сделан в предусловиях).
   Скрипт ждёт health, гонит `bin/smoke`, проверяет sidekiq, ставит `bin/prod-mark`.
4. Снаружи: `curl -sI https://victory62.org | head -1` → `200`; открыть главную и
   карточку объекта в браузере — стили на месте.
5. Логи 5 минут: `docker compose logs -f --since 5m web sidekiq` — без `Blocked host`, без 500.
6. Контейнер `zhk-registry` жив: `docker compose ps zhk-registry` → `running`
   (крона реестра в crontab хоста `victory` нет и не было — убирать нечего).
7. Тег релиза: `git tag -a v1.0.0 -m 'release 1.0.0: production-образы, единый compose' && git -c http.version=HTTP/1.1 push origin v1.0.0`.

### Откат A (к стеку до 1.0)

```bash
cd /home/q/victory
docker compose stop web sidekiq zhk-registry
docker compose -f docker-compose.yml -f docker-compose.dev.yml up -d web sidekiq
curl -fsS http://127.0.0.1:3000/health/database
```

Данные не трогались (тома и `storage/` общие), миграций в 1.0 нет — откат без
восстановления БД.

## B. Конвейер новостей: с chat в профиль `conveyor`

Что переезжает: таблицы `urgent_events` (chat:`audit-v2-postgres:5433`, база `re_audit`,
≈170 МБ с эмбеддингами), `posts_queue` + `content_revisions` + `system_flags`
(chat:`postgres-local:5432`, база `re_audit`, 10 МБ). Что остаётся на chat выключенным:
крон `/opt/victory-conveyor`, контейнер `publisher-bot`. Что **не** переезжает:
`omniroute` (LLM-шлюз, порт 20128 на chat — обе стороны ходят в него по LAN),
`audit-v2-*` (репатриация до 31.03.27), агенты openclaw (`project-manager` и др.,
читают `postgres-local` под `audit_user` — их не трогаем).

### Предусловия B

- [ ] `.env.conveyor`, `.env.publisher` созданы из `*.example`; значения — из
  `/opt/victory-conveyor/.env` и `workspace/agents/content-publisher/.env` на chat
  (копировать руками, вне git). `NEWS_DB_*` и `DB_*` смотрят в `news-db`, один пароль.
- [ ] `NEWS_DB_PASSWORD=<тот же>` дописан в `.env.deploy` (его читает служба `news-db`).
- [ ] `CHANNEL_BOT_TOKEN` в `.env.publisher` — **новый** (старый утёк через логи
  `publisher-bot` 05.10.26; `@BotFather` → `/revoke`).
- [ ] С `victory` доступны `192.168.0.105:5433` и `:5432`? Порт 5432 на chat слушает только
  `127.0.0.1` — данные с него идут через `ssh chat docker exec … pg_dump`, не напрямую.

### Переезд B (окно между прогонами коллектора, ≈15 мин)

1. На chat — заморозить запись, не ломая чтение:
   ```bash
   ssh chat 'crontab -l > ~/crontab.bak.$(date +%d.%m.%y-%H%M) && crontab -l | sed -E "s#^(\*/30|2,17,32,47|0 6-20|0 6-12|0 7) (.*victory-conveyor.*)#\# 1.0-cutover: \1 \2#" | crontab - && docker stop publisher-bot && crontab -l | grep -c "1.0-cutover"'
   ```
   Ожидается `5` (пять строк конвейера закомментированы), `publisher-bot` остановлен.
2. Поднять базу и применить схему (initdb из `services/urgent-news-collector/schema/`):
   ```bash
   cd /home/q/victory && docker compose --profile conveyor up -d --wait news-db && docker compose exec -T news-db psql -U news -d news -Atc '\dt' | cut -d'|' -f2 | tr '\n' ' '
   ```
   Ожидается: `content_revisions posts_queue system_flags urgent_events`.
3. Данные — по ssh-трубе, без промежуточных файлов (`--data-only`, `--disable-triggers`
   чтобы `updated_at` не переписался при вставке):
   ```bash
   ssh chat 'set -a; . /opt/victory-conveyor/.env; set +a; docker exec -e PGPASSWORD="$NEWS_DB_PASSWORD" audit-v2-postgres pg_dump -U "$NEWS_DB_USER" -d "$NEWS_DB_NAME" --data-only --no-owner --disable-triggers -t urgent_events' \
     | docker compose exec -T news-db psql -U news -d news -q
   ssh chat 'set -a; . /opt/victory-conveyor/.env; set +a; docker exec -e PGPASSWORD="$DB_PASSWORD" postgres-local pg_dump -U "$DB_USER" -d "$DB_NAME" --data-only --no-owner --disable-triggers -t posts_queue -t content_revisions -t system_flags' \
     | docker compose exec -T news-db psql -U news -d news -q
   ```
4. Сверить счётчики с chat (на 05.10.26: `urgent_events` 21 285, `posts_queue` 190,
   `content_revisions` 1, `system_flags` 2 — на день переезда числа будут больше, брать с chat):
   ```bash
   docker compose exec -T news-db psql -U news -d news -Atc "select 'urgent_events '||count(*) from urgent_events union all select 'posts_queue '||count(*) from posts_queue union all select 'content_revisions '||count(*) from content_revisions union all select 'system_flags '||count(*) from system_flags"
   ```
   И последовательности: `select setval('urgent_events_id_seq', (select max(id) from urgent_events)); select setval('posts_queue_id_seq', (select max(id) from posts_queue)); select setval('content_revisions_id_seq', coalesce((select max(id) from content_revisions),1));`
5. Поднять коллектор и публикатор: `docker compose --profile conveyor up -d conveyor publisher`.
   Логи 2 минуты: `docker compose logs -f conveyor publisher` — у publisher `Successfully connected
   to database`, `Telegram Bot started`; у conveyor `read crontab`. Ближайший тик коллектора —
   `*/30`; дождаться его и проверить `docker compose logs --since 5m conveyor | grep -ciE 'error|traceback'` → `0`.
6. Зеркало на сайт: после первого `urgent_trigger` в логе конкретная строка `[news_ingest] OK` (успех пишет её post_news_to_victory.sh на stderr; любая другая строка `[victory62-mirror]` — skipping или exception, статьи на сайте не будет);
   на сайте `/news` — новая запись.

### Откат B

```bash
cd /home/q/victory && docker compose --profile conveyor stop conveyor publisher
ssh chat 'crontab -l | sed -E "s#^\# 1.0-cutover: ##" | crontab - && docker start publisher-bot'
```

Данные на chat не трогались; всё, что успел записать новый стек, остаётся в `news-db`
(при повторном переезде — `down -v` для `news-db` и заново с шага 2).

### После B

- Через сутки без ошибок: на chat `publisher-bot` можно удалить (`docker rm publisher-bot`),
  строки из crontab — убрать совсем. Каталог `/opt/victory-conveyor` оставить до ротации
  пароля `audit_user` на `postgres-local` (его ещё читают агенты openclaw).
- Пароль `audit_user@postgres-local` ротировать после инвентаризации агентов openclaw —
  отдельная задача.

## После всего

- Через сутки: `docker compose ps` — все `healthy`; `docker compose logs --since 24h sidekiq | grep -ci error`.
- Снести RC: `docker compose -p victory-rc --env-file /home/q/victory-release/.env.rc down -v; rm -rf /home/q/victory-rc-storage`.
- Следующий план: CI на ветке `dev`, dev-машина, `WEB_BIND` на внутренний интерфейс,
  переименование БД в `viktory_realty_production`, Kamal.

## Прогон RC — 05.10.26 21:47–21:52

Контрольный стек `victory-rc` (порт 3001). `.env.rc` — копия боевого `.env` с override
`RAILS_ENV=production`, `WEB_PORT=3001`, `WEB_BIND=127.0.0.1`, `DISABLE_SSL=true`,
`STORAGE_DIR=/home/q/victory-rc-storage`, `SENTRY_DSN=`, `VICTORY_TAG=1.0.0`;
выключены `TOPNLAB_API_KEY`, `TELEGRAM_BOT_TOKEN`, `SMTP_PASSWORD` (`=disabled-in-rc`).
Запуск: `RAILS_ENV_FILE=.env.rc docker compose -p victory-rc --env-file .env.rc …`.

- образ `victory-web` sha-b1cfb39, дамп `viktory-05.10.26-0330.dump.gpg` →
  `pg_restore` без ошибок: properties 135, articles 176, schema_migrations 119;
- web: `Puma started. Environment: production`, health через 3 с, **без** `Created database`;
- `bin/smoke http://127.0.0.1:3001 <token>` — **9/9 ok** (health, health/database, главная,
  tailwind css, каталог, sitemap, robots, вебхук без токена → 401, admin health);
- карточка объекта `/properties/<slug>` → 200; `/health` по http без `X-Forwarded-Proto` → 200
  (редиректа нет); `POST http://web:3000/webhooks/zhk_ingest` из docker-сети → 401 от
  контроллера (не 403 «Blocked host»);
- `zhk-registry` в `DRY_RUN` против `http://web:3000`: `erz: нашли (DRY_RUN) 10`, без traceback;
- sidekiq: `Booted Rails 8.1.3.1 application in production environment`, 22 cron-задачи,
  остановлен через 45 с.

Найдено и исправлено по ходу: `env_file: .env` у Rails-служб жёстко указывал на боевой файл
(→ `${RAILS_ENV_FILE:-.env}`); `bin/smoke` печатал `token=` в URL при FAIL (→ маскируется).
Тома `victory-rc_*` оставлены до переключения.

⚠️ Этот прогон шёл с `DISABLE_SSL=true`, и ревью PR показало, что он **не проверял**
`force_ssl`: в проде внутренние http-POST на `/webhooks/*` получали бы 301 (исправлено
в `production.rb` — `/webhooks/` исключён из ssl-редиректа вместе с `/health`).
Правило для следующих прогонов RC: **`DISABLE_SSL` в `.env.rc` не ставить**, а в проверки
добавить запрос без `X-Forwarded-Proto`:

```bash
docker run --rm --network victory-rc_default curlimages/curl:8.10.1 -s -o /dev/null \
  -w '%{http_code}\n' -X POST http://web:3000/webhooks/zhk_ingest      # ожидается 401, не 301
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3001/        # ожидается 301 — редирект на сайте работает
```

Повторный прогон после правок ревью — 12.10.26 11:36–11:47 (против `sha-f613c87`):

- `.env.rc` без `DISABLE_SSL`; дамп `viktory-12.10.26-1133.dump.gpg` → pg_restore
  без ошибок: properties 137, articles 180, schema_migrations 119;
- web: `Puma started. Environment: production`, health 200 за ~5 с, `Created database` нет;
- `bin/smoke http://127.0.0.1:3001` — **9/9 ok**;
- force_ssl: `POST /webhooks/zhk_ingest` без `X-Forwarded-Proto` → **401** (не 301),
  `GET /` по http → **301** на https, главная и карточка с `X-Forwarded-Proto: https` → 200;
- sidekiq: `Booted Rails 8.1.3.1 application in production environment`, 22 cron-задачи.

## Cutover выполнен — 12.10.26, окно A (11:49–11:52 MSK)

- Свежий бэкап за час: `viktory-12.10.26-1133.dump.gpg` + secrets.
- `bin/rollout sha-f613c87 --yes --skip-backup`: web/sidekiq на
  `ghcr.io/nick4man/victory-web:sha-f613c87`, zhk-registry на `1.0.0` (служба не
  менялась с `4944990`, в GHCR sha-тега нет — `ZHK_TAG=1.0.0` в `.env.deploy`),
  db не тронута. Smoke 9/9 внутри rollout, sidekiq жив.
- Снаружи: `/health`, `/health/database`, `/`, карточка объекта, `/news` → 200;
  логи web без `Blocked host`/500. prod-mark: ветка `prod` → `f613c87`,
  тег `deploy/12.10.26-1152`.
- ⚠️ Урок: проверка связки из `deploy-pipeline.md` использовала `rollout bogus`
  как «заведомо невалидный» тег — но `bogus` проходит regex
  `^[0-9a-z][0-9a-z.-]{0,39}$`, и выкатка реально случилась (благополучно: образ
  собрался локально из того же дерева, smoke зелёный, затем перевыкатка на
  sha-тег). Пример в runbook исправлен на действительно невалидный тег.
- Тег `v1.0.0` (п.7 окна A) не ставился: выкачен sha-тег, а не VERSION.
- Окно B (конвейер новостей с chat) — отдельным окном, предусловия выше.
- RC-стек остановлен, тома `victory-rc_*` оставлены до завтра, затем снести
  (раздел «После всего»).

## Окна B и C выполнены — 13.10.26 (00:37–04:30 MSK)

### Окно B (конвейер)

- Чекаут `/home/q/victory` поднят до `678d5a6`+ (вкл. #129 — классификатор без
  платного Sonnet); образы conveyor/publisher собраны на хосте, initdb news-db
  предпроверен на scratch-проекте (риск `\restrict` на psql15 не подтвердился).
- `.env.conveyor` / `.env.publisher` / `.env.deploy` заполнены; `NEWS_DB_PASSWORD`
  общий для трёх файлов, `VICTORY_NEWS_TOKEN` совпал с `NEWS_INGEST_TOKEN`.
- chat: 5 строк crontab закомментированы (маркер `1.0-cutover`, бэкап
  `~/crontab.bak.13.10.26-*`), `publisher-bot` остановлен.
- Данные по ssh-трубе, счётчики сошлись: `urgent_events` 21285, `posts_queue` 191,
  `content_revisions` 1, `system_flags` 2; `setval` последовательностей выставлены.
- ⚠️ Найдено по ходу: `urgent_events` не росла с 05.10 16:30 — контейнер
  `audit-v2-postgres` был пересоздан из plain-образа postgis без pgvector, все
  INSERT падали (`$libdir/vector`), дедуп `already_seen` ослеп, и каждые 30 минут
  ~105 одних и тех же RSS-записей уходили на переклассификацию с платным хвостом
  (658–883 вызова Sonnet/день 06–12.10 — причина сжигания ключа OpenRouter).
- ⚠️ Пустые опциональные ключи в `.env.conveyor` (`SEEN_HEADLINE_WINDOW_DAYS=` и
  т.п.) роняют коллектор (`int('')`) — пустые строки закомментированы.
- conveyor поднят, тики supercronic идут, прогон без единого PAID-вызова.
- `publisher` НЕ поднят: `CHANNEL_BOT_TOKEN` утёк 05.10 — ждём `/revoke` и новый
  токен от @BotFather, затем `docker compose --profile conveyor up -d publisher`.

### Окно C (audit-engine, выносилось за рамки исходного плана)

- Стек поднят из репо (профиль `audit`): audit-postgres (PG16+pgvector),
  audit-redis, audit-api, audit-mc-worker. Найден и влит фикс #130: SQLAlchemy 2.1
  сменил дефолтный DBAPI на psycopg v3, в образе был только psycopg2 — alembic
  падал на старте.
- Дамп `re_audit` с chat (PG16→PG16): полный, по списку таблиц — БЕЗ таблиц
  конвейера (`urgent_events`, `posts_queue`, `content_revisions`, `system_flags` —
  они в `news-db`) и без мёртвых (`recipes`, `ingredients`, `location_scores`,
  `financial_events`, `digests` — в коде их нет, на chat остались).
- ⚠️ `pg_dump -t` не выгружает функции — `poi_sync_geom()` и
  `update_updated_at_column()` перенесены вручную через `pg_get_functiondef`.
- `alembic_version` выставлен в `k9a6b7c8d2e3` (= head репо). Том отчётов
  (`audit-v2-stack_reports`) оказался пуст на обоих концах.
- Smoke: `bin/audit-stack smoke` — полный расчёт (EI + Monte-Carlo 100k) OK;
  из `web`: `curl http://audit-api:8000/api/v2/health` → ok. Rails `.env` уже
  указывал на `http://audit-api:8000/api/v2` — переключение бесшовное,
  перезапуск web не потребовался.
- chat: `audit-v2-api`, `audit-v2-postgres`, `audit-v2-redis` остановлены
  (не удалять неделю — откат). omniroute (chat:20128) остаётся по LAN.
