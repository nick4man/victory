# techContext.md — стек и инфра

## Стек

| Слой | Технология |
|------|-----------|
| Web framework | Rails **8.1.3.1** (в проде с 08.08.26; `load_defaults` пока 7.1) |
| Language | Ruby **3.4.10** — только в контейнере, через `bin/rb`. На хосте менеджера версий нет (ни chruby, ни rbenv, ни mise), системный ruby 3.3.8 не совпадает с пином Gemfile, поэтому `bundle`/`rspec`/`bin/rails` напрямую в worktree не работают |
| Database | PostgreSQL 15+ (с PostGIS + pgvector) |
| Server | Puma 6.x, порт **3000** в Docker (reverse-proxy → 443 в проде) |
| CSS | Tailwind CSS (`tailwindcss-rails`) |
| JS bundling | Importmap + Stimulus + Turbo (Hotwire) |
| Auth | Devise (**отключен**) |
| Search | PgSearch (full-text, Russian dictionary) |
| Pagination | Kaminari |
| Background jobs | Sidekiq 7 + sidekiq-cron — **активны в проде** (контейнер `victory-sidekiq-1`), расписание в `config/sidekiq_cron.yml` |
| API | Rack::CORS, jbuilder, JWT (для `/api/v1/`) |
| Geocoding | Geocoder gem |
| Scheduling | Whenever (cron) |
| WebSockets | Action Cable |
| File uploads | Active Storage |
| Testing | RSpec, FactoryBot, Shoulda Matchers, DatabaseCleaner, Capybara (selenium_chrome_headless для JS-спеков) |

## Module name

`ViktoryRealty` — главный модуль (см. `config/application.rb`).

## Локализация / TZ

- `Faker::Config.locale = 'ru'` для тестов.
- Default locale: `:ru`. Locale files: `config/locales/ru.yml`, `config/locales/devise.ru.yml`.
- Timezone: Moscow (`config.time_zone = 'Moscow'`).

## ENV vars

| Variable | Default | Описание |
|----------|---------|---------|
| `RAILS_ENV` | `development` | окружение |
| `PORT` | `5000` (старое) / `3000` (Docker) | порт сервера |
| `DATABASE_URL` | — | полный PG URL (production) |
| `DATABASE_HOST` | `localhost` | DB host |
| `DATABASE_PORT` | `5432` | DB port |
| `DATABASE_USERNAME` | `postgres` | DB user |
| `DATABASE_PASSWORD` | `''` | DB password |
| `REDIS_URL` | `redis://localhost:6379/0` | Redis (Sidekiq + cache) |
| `RAILS_MAX_THREADS` | `5` | thread count / DB pool |
| `WEB_CONCURRENCY` | `1` | Puma workers |
| `ACTION_CABLE_URL` | `ws://localhost:3000/cable` | WS endpoint |
| `CORS_ORIGINS` | `*` | allowed origins (CSV) |
| `APP_HOST` | `localhost` | hostname |
| `APP_PROTOCOL` | `http` | scheme |
| `JWT_SECRET_KEY` | (credentials) | JWT signing |
| `ASSET_HOST` | — | CDN |
| `LOG_LEVEL` | `debug`/`info` | logger verbosity |
| `SESSION_TIMEOUT` | `1800` | session expiry (sec) |
| `ADMIN_TOKEN` | — | query-param admin guard (Admin::Reviews, Admin::Articles) |
| `TELEGRAM_BOT_TOKEN` | — | основной TG-бот сайта (`@anvictorybot`) |
| `TELEGRAM_STAFF_CHAT_ID` | `-1003937910508` (dev+owner) | куда уходят отчёты/уведомления |
| `TOPNLAB_API_KEY` | — | ключ CRM; без него `Topnlab::Client` кидает `Error` на init |
| `TOPNLAB_BASE_URL` | — | база API (`agencies-p.topnlab.ru`); тоже обязательна |
| `YANDEX_AI_STUDIO_API_KEY` + `YANDEX_CLOUD_FOLDER_ID` | — | Vision OCR для document intake |
| `YANDEX_WEBMASTER_TOKEN` + `YANDEX_WEBMASTER_USER_ID` | — | Webmaster API (digest, recrawl) |

## DB и миграции

- DB-имена: `viktory_realty_development`, `viktory_realty_test`, `viktory_realty_production`.
- Расширения: `postgis`, `vector` (pgvector), `pg_trgm`, `unaccent`.
- ~13 базовых миграций; новые — по фазам.

## Git — относительные пути worktree (с 10.09.26)

Указатели worktree относительные с **обеих** сторон: `.git/worktrees/<id>/gitdir` →
`../../../../victory-seo/.git`, а `<worktree>/.git` → `gitdir: ../victory/.git/worktrees/victory-seo`.
Дерево `~/victory*` можно перенести целиком, не сломав ни один checkout.

Включено локально в `.git/config` main checkout (конфиг не коммитится):

```bash
git config worktree.useRelativePaths true   # новые `git worktree add` сразу относительные
# git при первой конверсии сам дописал extensions.relativeWorktrees = true
```

🚨 **Требует git ≥2.48 везде, откуда репозиторий читают.** `extensions.relativeWorktrees` —
защитный флаг: git старее обязан отказаться от репозитория **целиком**, а не молча испортить
указатели. `trixie/main` даёт только 2.47.3 — на хосте git ставился отдельно (сейчас 2.56).

⚠️ В прод-контейнерах `victory-web-1` / `victory-sidekiq-1` git **2.39.5**, поэтому любая
git-команда внутри `/app` теперь падает:

```
fatal: unknown repository extension found:
	relativeworktrees
```

Потребителей у неё сейчас нет — git-источников в `Gemfile` нет, shell-out в git из `app/`,
`lib/`, `config/` нет, `bin/rb` дёргает `git rev-parse` на хосте до контейнера. Но при
следующей пересборке образов git стоит поднять до ≥2.48.

Починка указателей (после переезда каталогов или порчи путей) — из main checkout:

```bash
git worktree list                                 # битые видны как `prunable`
git worktree repair --relative-paths <пути...>    # пути всех worktree, явным списком
```

Без явного списка `repair` бессилен: сломанная репо-сторона не даёт ему найти каталоги.
Строка `repair: gitdir absolute/relative path mismatch: …` в выводе — сообщение о самой
конверсии, а не отказ.

Откат к абсолютным — три команды, и третья обязательна:

```bash
git config --unset worktree.useRelativePaths
git worktree repair --no-relative-paths <пути...>
git config --unset extensions.relativeWorktrees   # сам он не снимается
```

Без третьей строки указатели станут абсолютными, но расширение останется в `.git/config`, и
git 2.39.5 в контейнерах продолжит отказываться от репозитория — со стороны выглядит так,
будто откат не сработал. Проверено на образе `victory-web`: со снятым расширением
`git worktree list` внутри `/app` отвечает, `core.repositoryformatversion = 1` сам по себе
старому git не мешает.

История: 10.09.26 массовая замена `/home/q` → `~` по 51 файлу заехала и в git-метаданные.
Тильду git не разворачивает, поэтому все 15 worktree разом стали `prunable`; тем же заходом
были незаметно отключены две страховки — deny-правило `Edit(//home/q/victory/**)` в
`.claude/settings.json` и live-prod guard в `bin/rb` (сравнение `$ROOT` с `'~/victory'`).
Обе восстановлены в тот же день; секция описывает конфигурацию после починки.

## Команды

### Сервер
```bash
bundle exec rails server -p 5000 -b 0.0.0.0  # legacy
bin/rails server                              # Docker prod: :3000
```

### БД
```bash
bin/rails db:create
bin/rails db:migrate
bin/rails db:seed
bin/rails db:reset    # drop + create + migrate + seed
```

### Тесты
```bash
bundle exec rspec
bundle exec rspec spec/models/property_spec.rb
bundle exec rspec --format documentation
```

### Lint
```bash
bundle exec rubocop
bundle exec rubocop -a    # safe autocorrect
bundle exec rubocop -A    # unsafe autocorrect
```

### Sidekiq (когда нужно)
```bash
bundle exec sidekiq -C config/sidekiq.yml
```
Очереди по приоритету: `critical` → `mailers` → `default` → `scheduled` → `low_priority`.

### Cron (Whenever)
```bash
bundle exec whenever --update-crontab
bundle exec whenever --clear-crontab
```
Расписание:
- ежечасно: `SendViewingRemindersJob`
- 03:00: `UpdatePropertyStatisticsJob`
- 10:00: `PropertyValuationFollowUpJob`

### Переезд базы на bookworm — пересборка прод-БД

С PR #42 (в main 09.09.26, мерж `c18ea20`) `Dockerfile.postgres` строится от
`postgres:15-bookworm`, а не от `postgis/postgis:15-3.5` — у bullseye 07.09.26
протух `Release` debian-security и сборка перестала проходить. Мажор PostgreSQL
прежний, каталог данных и volume `pgdata` совместимы, но **одной пересборки мало**.
Заглушки `Acquire::Check-Valid-Until=false` (из #45) в main нет, и она не нужна.

| | Было (`pg15-postgis35`) | Стало (`pg15-postgis36`) |
|---|---|---|
| PostgreSQL | 15.13 | 15.19 |
| PostGIS | 3.5.2 | 3.6.4 |
| pgvector | 0.8.2 | 0.8.6 |
| glibc | 2.31 | 2.36 |

Прод на 09.09.26 всё ещё на старом образе: `victory-db-1` = `pg15-postgis35`.
Код уже выкачен (прод-чекаут на `c18ea20`), поэтому `git pull` в процедуре нет —
осталась только пересборка БД.

🚨 **Точка невозврата — шаг 6.** После `postgis_extensions_upgrade()` и
`ALTER EXTENSION vector UPDATE` каталог расширений в `pgdata` описывает 3.6/0.8.6,
а библиотеки старого образа — 3.5/0.8.2. Подменить образ обратно на
`pg15-postgis35` технически ничто не мешает, но это не откат: база стартует и
падает на первой же PostGIS-функции. **С шага 6 откат существует только через
восстановление из дампа.** До шага 6 откат — вернуть контейнер на старый образ
compose-оверрайдом, две минуты.

Зачем REINDEX: смена glibc меняет порядок сортировки (`datcollversion` был `2.31`,
новый образ даёт `2.36`), и текстовые индексы, построенные под старой библиотекой,
врут — включая уникальные ограничения. В `db/structure.sql` таких индексов 123, из
них 39 UNIQUE; кириллица лежит в `properties(city)` и `properties(district)` — это
единственная таблица, про которую точно известно, что она полна (её наполняет
`TopnlabSyncJob` каждые 30 мин), — а также в `city_median_prices(city, property_type)`,
`landing_contents(...)`, `zhk_facts(field, source)`, `zhk_observations(...)`,
`external_listings(source, source_id)`. UNIQUE `districts(city, name)` тоже в этом
списке, но сама таблица пуста: её наполняла бы `rake districts:import_voronezh` (см.
комментарий в `app/models/district.rb`), а такой задачи в репозитории нет — поэтому
в дымовых проверках `districts` не участвует. Не зависят от коллации 5 HNSW по `vector`
и 2 GiST по гео-колонкам (`districts.boundary` — geometry, `properties.geom` —
geography); индексов `gin_trgm_ops` в схеме нет. При этом бояться нечего:
volume `victory_pgdata` весит ~170 МБ (замер 09.09.26), REINDEX отработает за
секунды — дольше всего перестраиваются те самые 5 HNSW.

**Простой — только шаги 4–9: 2–3 минуты, худший случай 5.** Шаги 1–3 идут на живом
трафике, и сделать их надо заранее; шаги 10–11 — после закрытия окна, но не
«когда-нибудь».

#### Без простоя

**1. Свежий дамп — единственный откат для второй половины.**
```bash
/usr/local/bin/victory-backup db
ls -lt /var/backups/victory/db/ | head -3
```
Проверка: сверху свежий `viktory-<dd.MM.yy-HHmm>.dump.gpg` ненулевого размера.
**Полный путь выписать** — откат B принимает его аргументом, а без аргумента
`restore` ничего не восстанавливает.
🚨 Стоп: дампа нет или он нулевой — дальше не идти вообще.

**2. Откат-тег на старый образ** (по аналогии с `victory-web:pre-ruby34`).
```bash
/usr/bin/docker tag viktory-postgres-pgvector:pg15-postgis35 \
                    viktory-postgres-pgvector:pre-bookworm
/usr/bin/docker image ls | grep pre-bookworm
```
Сейчас старый образ цел случайно — любой `docker image prune` унесёт откат первой
половины вместе с ним.

**3. Собрать новый образ, пока старый контейнер обслуживает трафик.**
```bash
cd /home/q/victory
/usr/bin/docker image inspect -f '{{.Id}} {{.Created}}' \
  viktory-postgres-pgvector:pg15-postgis36        # ДО сборки, записать
/usr/bin/docker compose build db
/usr/bin/docker image inspect -f '{{.Id}} {{.Created}}' \
  viktory-postgres-pgvector:pg15-postgis36        # ПОСЛЕ: ID и дата другие
```
Проверка: ID образа сменился. Именно ID, а не `docker image ls | grep`: тег
`pg15-postgis36` на хосте уже есть — его собирают сессионные стеки `bin/rb`, — и
grep не отличит свежесобранный образ от лежавшего с прошлой недели.
🚨 Стоп: apt не достучался до `apt.postgresql.org` — разбираться сейчас, при живой
базе, а не с погашенной.
🚨 **Не `docker compose up -d --build db`**: он сначала гасит базу и только потом
собирает — при сетевой заминке прод останется без БД на всё время разбирательства.

#### Окно простоя

**4. Погасить приложение: sidekiq первым, web вторым.**
```bash
/usr/bin/docker compose stop sidekiq web
/usr/bin/docker compose ps -a
```
У обоих `restart: unless-stopped`: с пропавшей БД Rails засыпает лог ошибками, а
Sidekiq жжёт retry-бюджет на джобах, упавших не по своей вине. Sidekiq первым —
чтобы он не набирал новых джоб, пока web ещё отвечает.
Проверка: оба `Exited`. Флаг `-a` обязателен: установленный compose (v5.1.3) без него
печатает только запущенные контейнеры, и «остановлен» не отличить от «не существует».
Сайт в этот момент отдаёт 502 — ожидаемо, окно открыто.

**Эталон дымовых проверок — снять здесь, на погашенном приложении.** Сравнивать
после переезда иначе не с чем: каталог маленький (09.09.26 `/properties` показывает
17 объектов, `district` NULLable и заполнен у меньшинства), и «мало строк»
неотличимо от «сортировка поехала». Именно внутри окна, а не в фазе без простоя:
там данные живые — `topnlab_sync` (`config/sidekiq_cron.yml`, каждые 30 мин) делает
upsert в `properties`, а изменение `district` тянет за собой `EmbedPropertyJob`
(`EMBED_TRIGGER_FIELDS` в `app/models/property.rb`) и растит `property_embeddings`.
Эталон, снятый заранее, разъехался бы со сверкой сам по себе — от исправно
отработавшего синка, а не от переезда; расхождение с эталоном стоит в триггерах
отката, и после шага 6 это откат исправной базы из дампа. Здесь данные заморожены:
sidekiq погашен шагом 4, база ещё на старом образе и старом glibc — ровно то
состояние, с которым сравнивают. Три запроса — секунды, окно от них не вырастет.
```bash
DB=$(grep  -m1 '^POSTGRES_DB='   /home/q/victory/.env | cut -d= -f2-)
PGU=$(grep -m1 '^POSTGRES_USER=' /home/q/victory/.env | cut -d= -f2-)
/usr/bin/docker compose exec -T db psql -U "$PGU" -d "$DB" <<'SQL' | tee /home/q/db-baseline.txt
SELECT district, count(*) FROM properties
 WHERE district IS NOT NULL AND district <> ''
 GROUP BY district ORDER BY count(*) DESC, district;
SELECT count(*) AS geo FROM properties
 WHERE geom IS NOT NULL
   AND ST_DWithin(geom, ST_MakePoint(39.74, 54.63)::geography, 5000);
SELECT count(*) AS embeddings FROM property_embeddings;
SQL
```
Файл держать вне `/home/q/victory` — в чекауте его снесёт первый же `git clean -fd`.
Те же три запроса пойдут ещё внутри окна, сразу после шага 8, и должны дать те же
числа: проверка сравнивает «до/после», а не угаданный порог.

**5. Пересоздать контейнер базы на новом образе.**
```bash
/usr/bin/docker compose up -d db
/usr/bin/docker compose ps db
/usr/bin/docker inspect victory-db-1 --format '{{.Config.Image}}'
```
База работала всё это время, гасить её отдельно не нужно: имя образа в compose
изменилось, поэтому `up -d` сам погасит старый контейнер и поднимет на его месте
новый — поверх того же volume `pgdata`.
Проверка: `Up (healthy)` (healthcheck — `pg_isready`), образ `pg15-postgis36`, в
логах нет `FATAL`.
🚨 Стоп: `healthy` не наступил за ~100 с — откат A. Порог не с потолка: у сервиса
`db` в `docker-compose.yml` `interval: 5s` и `retries: 20`, то есть до статуса
`unhealthy` контейнер идёт около 100 с; ждать меньше — гасить базу, которая ещё
поднимается.
⚠️ `WARNING: database "…" has a collation version mismatch` в логах на этом шаге
**ожидаем** и триггером отката не является — он снимется шагом 8.

**6. Расширения. ТОЧКА НЕВОЗВРАТА.**
```bash
DB=$(grep  -m1 '^POSTGRES_DB='   /home/q/victory/.env | cut -d= -f2-)
PGU=$(grep -m1 '^POSTGRES_USER=' /home/q/victory/.env | cut -d= -f2-)
/usr/bin/docker compose exec -T db psql -v ON_ERROR_STOP=1 -U "$PGU" -d "$DB" <<'SQL'
SELECT postgis_extensions_upgrade();
ALTER EXTENSION vector UPDATE;
SQL
```
Имя базы — из `$POSTGRES_DB`, не хардкодом: compose берёт его оттуда же.
`-v ON_ERROR_STOP=1` не украшение: psql, читающий скрипт со stdin, при SQL-ошибке
всё равно выходит с кодом 0 — без флага стоп-условие на точке невозврата держится
только на внимательности человека.
`postgis_extensions_upgrade()` по документации PostGIS иногда требует **двух
прогонов** (первый поднимает сам `postgis`, второй — зависимые): повторять, пока
вывод не перестанет сообщать об upgrade. Расширений в базе семь (`db/structure.sql`):
`fuzzystrmatch`, `pg_trgm`, `postgis`, `postgis_tiger_geocoder`, `postgis_topology`,
`unaccent`, `vector`. `postgis_raster` среди них нет, а капризнее прочих на апгрейде
исторически `postgis_tiger_geocoder` — он живёт в схеме `tiger`.
Проверка:
```sql
SELECT postgis_full_version();                                 -- без "needs upgrade"
SELECT extname, extversion FROM pg_extension ORDER BY extname; -- те же 7 + plpgsql,
                                                               -- postgis 3.6.x, vector 0.8.6
```
🚨 Стоп: функция завершилась **ошибкой** (не WARNING) — дальше не идти, откат B.

**7. REINDEX — один на всю базу, после расширений.**
```bash
/usr/bin/docker compose exec -T db psql -U "$PGU" -d "$DB" -c "REINDEX DATABASE \"$DB\";"
```
Порядок именно такой: расширения → REINDEX → REFRESH COLLATION VERSION. Апгрейд
расширений сам пересоздаёт часть объектов, а отметку коллации снимаем последней —
иначе объявим базу здоровой до перестройки индексов.
Проверка: команда завершилась без ошибок (секунды на 170 МБ).
⚠️ С PG14 `REINDEX DATABASE` не трогает системные каталоги. Здесь некритично —
идентификаторы в каталогах имеют тип `name`, он сортируется по C-локали и от glibc
не зависит; упомянуто, чтобы потом не искали. Если всё же понадобится —
`reindexdb --system`.

**8. Отметить коллацию — всем базам кластера, а список взять запросом.**
```bash
/usr/bin/docker compose exec -T db psql -U "$PGU" -d postgres -Atc \
  "SELECT format('ALTER DATABASE %I REFRESH COLLATION VERSION;', datname)
     FROM pg_database WHERE datcollversion IS NOT NULL" \
| /usr/bin/docker compose exec -T db psql -v ON_ERROR_STOP=1 -U "$PGU" -d postgres
/usr/bin/docker compose exec -T db psql -U "$PGU" -d postgres \
  -c 'SELECT datname, datcollversion FROM pg_database ORDER BY datname;'
```
Пропустить служебные базы — получить WARNING про коллацию на каждом коннекте. Но и
перечислять их руками нельзя, по двум причинам сразу. Кластер инициализирован
образом `postgis/postgis:15-3.5`, поэтому баз пять, а не четыре: кроме `$DB`,
`postgres`, `template1` и `template0` в нём есть `template_postgis` — забытая, она
останется на `2.31`. А `template0` команду не принимает вовсе: `datcollversion` у неё
NULL (PostgreSQL её намеренно не хранит), и `REFRESH` падает с
`ERROR: invalid collation version change`. Условие `datcollversion IS NOT NULL`
закрывает оба случая — `template_postgis` подхватывается само, `template0`
отсеивается. Список строим запросом, а не в цикле по переменной: в zsh
`for d in $DBS` не разбивает строку на слова и уезжает в
`database "postgres\ntemplate1" does not exist`.
Проверка: `2.36` во всех строках, кроме `template0` — её ячейка пуста и до, и после.

**Сверка с эталоном — здесь, до подъёма приложения.** Три запроса ниже — те же, что
снимали эталон после шага 4: сравниваем вывод с `/home/q/db-baseline.txt`, а не с
ожиданием «строк должно быть много»; одного `postgis_full_version()` для этого мало.
Приложение им не нужно — нужна только поднятая база, а шаг 9 сверку испортит:
поднятый sidekiq законно гонит `topnlab_sync` (каждые 30 мин), тот апсертит
`properties` и через `EmbedPropertyJob` растит `property_embeddings` — достаточно
пересечь границу `:00`/`:30`, и штатно отработавший синк выдаст себя за поломку
переезда. Цена такой ошибки после шага 6 — восстановление исправной базы из дампа.
Здесь данные заморожены так же, как при съёмке эталона.
```sql
-- гео: GiST + PostGIS 3.6 — счётчик тот же, что в эталоне
-- (properties.geom уже geography(Point,4326), приводится только правый аргумент)
SELECT count(*) FROM properties
 WHERE geom IS NOT NULL
   AND ST_DWithin(geom, ST_MakePoint(39.74, 54.63)::geography, 5000);

-- вектор: HNSW + pgvector 0.8.6. Первая строка — счётчик, сверить с эталоном.
-- 🚨 Если он 0 — эмбеддингов нет вовсе (EmbedPropertyJob не отрабатывал), и два
-- следующих запроса ПРОПУСТИТЬ: \gset на пустой выборке не заведёт переменную
-- (`no rows returned for \gset`), а EXPLAIN следом упадёт с
-- `syntax error at or near ":"`.
SELECT count(*) AS embeddings FROM property_embeddings;
-- Пробный вектор кладём в переменную psql — под подзапрос-скаляр планировщик HNSW
-- не подставляет, и «проверка» уходила бы мимо индекса.
SELECT embedding AS probe FROM property_embeddings LIMIT 1 \gset
EXPLAIN (COSTS OFF) SELECT property_id FROM property_embeddings
 ORDER BY embedding <=> :'probe' LIMIT 5;      -- ждём Index Scan using
                                               -- idx_property_embeddings_cosine
                                               -- (слова hnsw в плане нет — это метод
                                               -- индекса, а не его имя); Seq Scan на
                                               -- крошечной таблице — выбор
                                               -- планировщика, не поломка
SELECT property_id FROM property_embeddings
 ORDER BY embedding <=> :'probe' LIMIT 5;      -- пять строк, а не ошибка

-- кириллица, btree по живому каталогу (index_properties_on_district): районы,
-- счётчики и порядок — как в эталоне. Абсолютные числа тут ничего не доказывают:
-- district NULLable и заполнен у меньшинства объектов.
SELECT district, count(*) FROM properties
 WHERE district IS NOT NULL AND district <> ''
 GROUP BY district ORDER BY count(*) DESC, district;
-- порядок русского алфавита: ждём t. f — сортировка ушла в C-локаль, а тогда и
-- WARNING про collation version из шага 5 не появился бы.
SELECT 'е' < 'ё' AND 'ё' < 'ж' AS ru_order_ok;
```

**9. Поднять приложение, sidekiq последним.**
```bash
/usr/bin/docker compose up -d web
/usr/bin/docker compose up -d sidekiq
```
Окно простоя закрыто.

#### Дымовые проверки живого приложения — после шага 9

SQL-сверка с эталоном к этому моменту уже прошла внутри окна (сразу после шага 8);
здесь остаётся то, для чего приложение как раз и нужно.
```bash
curl -sI https://victory62.org | head -1         # 200
/usr/bin/docker compose logs --tail=50 sidekiq   # cron-джобы идут
```

#### После окна — два шага, без которых процедура не закончена

**10. Синхронизировать `/usr/local/bin/victory-backup` — до ближайшего воскресенья.**
```bash
sudo cp /home/q/victory/bin/backup /usr/local/bin/victory-backup
grep -n pg15 /usr/local/bin/victory-backup      # только pg15-postgis36
```
Это не симлинк на чекаут, а отдельная копия (обычный файл от 11.08.26), застрявшая
на `pg15-postgis35`. Weekly-таймер (вс 04:33 UTC) гоняет ею `verify`: копия поднимет
старый образ и попробует развернуть в него дамп, снятый уже с PostGIS 3.6 —
проверка восстановления упадёт, и упадёт молча. Пока копия не синхронизирована,
теги `pg15-postgis35` и `pre-bookworm` удалять нельзя.

**11. Записать, что прод-БД переехала.**
```bash
/usr/bin/docker inspect victory-db-1 --format '{{.Config.Image}}'   # pg15-postgis36
```
Заменить в этой секции строку «Прод на 09.09.26 всё ещё на старом образе» на дату
переезда и обновить строку про БД в `progress.md` (таблица «что в проде»).
`bin/prod-mark` тут не поможет: он отмечает выкаченный коммит, а коммит не двигался —
переехал только образ.

**Оба шага обязательны, иначе состояние прода снова станет невидимым:** без 10
ближайшая воскресная проверка бэкапов ломается, без 11 через месяц «процедура
написана» неотличимо от «процедура выполнена».

#### Откат

**A — до шага 6** (расширения ещё не тронуты): вернуть контейнер на старый образ
через compose-оверрайд, две минуты.
```bash
cd /home/q/victory
cat > /home/q/db-rollback.yml <<'YML'
services:
  db:
    image: viktory-postgres-pgvector:pre-bookworm
YML
/usr/bin/docker compose -f docker-compose.yml -f /home/q/db-rollback.yml \
  up -d --force-recreate db
/usr/bin/docker inspect victory-db-1 --format '{{.Config.Image}}'   # pre-bookworm
/usr/bin/docker compose -f docker-compose.yml -f /home/q/db-rollback.yml \
  up -d web sidekiq
/usr/bin/docker inspect victory-db-1 --format '{{.Config.Image}}'   # снова pre-bookworm
```
⚠️ Файл оверрайда — **вне** `/home/q/victory`: в чекауте он ляжет untracked, и первый
же `git clean -fd` снесёт откат. Путь абсолютный, `-f` его принимает.
🚨 **Тег `pg15-postgis36` не перетегиваем.** Он прописан в `docker-compose.ruby.yml`,
то есть его берут ВСЕ сессионные стеки `bin/rb`, и часть из них уже работает с
`pgdata` от bookworm-образа: ретег подсунул бы им PostGIS 3.5 поверх каталога 3.6 —
ровно ту поломку, от которой эта процедура защищает прод, только молча и в чужой
сессии. На тот же тег смотрит `cmd_verify` в `bin/backup`.
Оверрайд живёт до конца разбирательства и передаётся **любой** команде compose,
которая тянет `db`, — не только командам «по сервису `db`». У `web` и `sidekiq` в
`docker-compose.yml` стоит `depends_on: db: condition: service_healthy`, поэтому
compose примиряет зависимость с той конфигурацией, что ему дали: `up -d web sidekiq`
без оверрайда молча пересоздаёт базу на bookworm-образе. Молча — буквально: в выводе
только `Container victory-db-1 Started`, слова `Recreated` нет, а проверка `inspect`
стоит строкой выше и уже прошла. Отсюда и повторный `inspect` после подъёма
приложения. Проверено на синтетическом compose-проекте: без оверрайда контейнер
уехал с образа отката обратно на базовый, с обоими `-f` та же команда печатает
`Running` и `db` не трогает.
Собирать с оверрайдом нельзя — `build db` перезапишет им сам `pre-bookworm`.
⚠️ `docker compose config` показывает итоговую конфигурацию, но печатает
`POSTGRES_PASSWORD` открытым текстом — вывод не копировать в чат и тикеты.
Как и в Ruby-процедуре, откат — это дерево И образы: пока прод-чекаут стоит на
коммите с новым `Dockerfile.postgres`, следующая пересборка снова соберёт bookworm.
Либо держать оверрайд, либо вернуть чекаут на коммит перед #42.

**B — после шага 6**: старый образ И восстановление из дампа шага 1. Приложение
поднимается последним — блок A заканчивается подъёмом web+sidekiq, а здесь они
работали бы по базе, которую `pg_restore --clean` в этот момент перезаписывает.
```bash
cd /home/q/victory
/usr/bin/docker compose stop sidekiq web
cat > /home/q/db-rollback.yml <<'YML'
services:
  db:
    image: viktory-postgres-pgvector:pre-bookworm
YML
/usr/bin/docker compose -f docker-compose.yml -f /home/q/db-rollback.yml \
  up -d --force-recreate db
# путь обязателен: без аргумента `restore` печатает список копий, возвращает 0 и
# НИЧЕГО не восстанавливает. Имя файла — из вывода шага 1.
/usr/local/bin/victory-backup restore \
  /var/backups/victory/db/viktory-<dd.MM.yy-HHmm>.dump.gpg
# оба -f обязательны и здесь — иначе поверх только что восстановленного каталога
# PostGIS 3.5 поднимутся библиотеки 3.6, ровно та поломка, от которой мы откатываемся
/usr/bin/docker compose -f docker-compose.yml -f /home/q/db-rollback.yml \
  up -d web sidekiq
/usr/bin/docker inspect victory-db-1 --format '{{.Config.Image}}'   # pre-bookworm
```
Скрипт спросит подтверждение — ввести имя базы (`$POSTGRES_DB`) целиком.

⚠️ **Если restore не завёлся.** Перед перезаписью `cmd_restore` снимает страховочный
дамп текущего состояния (`cmd_db no-prune`) и при неудаче обрывается через `die` —
восстановление может не начаться вовсе. А снимается этот дамп с базы, чей каталог
уже 3.6, под библиотеками 3.5, так что `pg_dump` вправе упасть на первой же
PostGIS-функции. Тогда не давить на скрипт, а проверить дамп в стороне: поднять
`pre-bookworm` разовым `docker run` со своим volume, развернуть в него дамп шага 1
руками (`gpg --batch --decrypt --passphrase-file … | docker exec -i <контейнер>
pg_restore -U … -d … --clean --if-exists --no-owner --no-acl`), убедиться, что дамп
живой, и только после этого подменять боевой `pgdata`. Боевой каталог до этого
момента не трогаем: если дамп окажется негодным, он единственное, что осталось.

**Триггеры отката:** база не дошла до `healthy` за ~100 с (бюджет healthcheck);
`postgis_extensions_upgrade()` завершилась ошибкой; гео-/вектор-/кириллическая
сверка после шага 8 разошлась с эталоном; сайт после подъёма не отдаёт
200. **Не триггер:** WARNING про collation version
до шага 8 — он там и должен быть.

#### Хвосты

- **`bin/backup verify` и тег образа.** `cmd_verify` поднимает одноразовый
  PostgreSQL по имени образа, зашитому в скрипте. Комментарий в
  `victory-backup-daily.service` уверяет, что `/usr/local/bin/victory-backup` —
  симлинк на `bin/backup` прод-чекаута; тогда тег переключался бы в момент `git pull`,
  а не пересборки — отсюда общее правило «образ собираем ДО pull». Но на 09.09.26
  это **не симлинк, а отдельная копия** (обычный файл от 11.08.26), застрявшая на
  `pg15-postgis35`, хотя в чекауте `bin/backup` уже просит `pg15-postgis36` — отсюда
  шаг 10 и запрет удалять теги `pg15-postgis35`/`pre-bookworm`, пока копия не
  синхронизирована. Daily-таймер (03:31 UTC) `verify` не гоняет.
- **Соседний стек `victory-victory`** (`/home/q/victory-victory`, свой `pgdata`,
  свой compose-проект) тоже на `pg15-postgis35`. Это полноценный compose-стек, а не
  `bin/rb`, — `--nuke` к нему неприменим: ему нужна та же процедура либо явное
  решение оставить как есть.
- **Стеки `bin/rb`**: их `pgdata` создан старым образом; 15.19 поверх каталога 15.13
  стартует штатно, при странностях — `bin/rb --nuke`.
- **Свежая база больше не получает `postgis` сама**: в `postgis/postgis` это делал
  initdb-скрипт, теперь в новой базе только `plpgsql`. Схемы не касается —
  `db/structure.sql` создаёт все семь расширений, — но `bin/backup verify` теперь
  проверяет `postgis` осмысленно.

### Деплой смены Ruby/Rails — пересборка прод-образов

Прод (`/home/q/victory`, compose-проект `victory`) монтирует код bind-mount'ом с
code-reload, поэтому merge в main обновляет код сразу, а **гемы и рантайм — нет**:
они живут в образах `victory-web`/`victory-sidekiq` и в named-volume
`victory_bundle` (`/usr/local/bundle`, каталог `ruby/<ABI>`). Volume перекрывает
образ: без пересоздания новый Ruby не увидит ни одного гема и `bundle exec`
упадёт на старте. Отработано дважды: 08.08.26 (Rails 8.1.3.1) и 07.09.26 (Ruby 3.3.6 → 3.4.10).
Правки ниже — из второго прогона.

```bash
cd /home/q/victory
# 1. откат-теги
/usr/bin/docker tag victory-web victory-web:pre-ruby34
/usr/bin/docker tag victory-sidekiq victory-sidekiq:pre-ruby34
# 2. ПРЕДПОЛЁТ: ff-only пройдёт только если локальная main — предок origin/main.
#    07.09.26 не прошёл бы: на проде висел коммит из ОТКРЫТОГО PR (SECURITY.md),
#    ветка разошлась. Проверить и, если разошлась, выровнять reset'ом —
#    но сперва убедиться, что коммит цел на удалённой ветке своего PR.
git fetch origin
git merge-base --is-ancestor HEAD origin/main && echo ff-ok || git branch -r --contains HEAD
# 3. свежий main + сборка (старые контейнеры пока служат)
git pull --ff-only origin main    # либо: git reset --hard origin/main
/usr/bin/docker compose build web sidekiq
# 4. свап (даунтайм ~30-60с) — БЕЗ ПАУЗЫ после шага 3, см. предупреждение ниже
/usr/bin/docker compose stop web sidekiq
/usr/bin/docker compose rm -f web sidekiq
/usr/bin/docker volume rm victory_bundle
/usr/bin/docker compose up -d web sidekiq
# 5. verify
/usr/bin/docker compose exec web ruby -v            # 3.4.10
/usr/bin/docker compose logs web | grep 'Booted'    # Rails 8.1.3.1
curl -sI https://victory62.org | head -1            # 200
/usr/bin/docker compose logs --tail=50 sidekiq      # cron-джобы идут
```

🚨 **Окно уязвимости между шагами 3 и 4.** Как только новый `Gemfile` ляжет в
bind-mount, рантайм контейнера перестанет ему соответствовать. Работающий Rails
это переживёт — bundler своё уже отработал, — но у `web` и `sidekiq` политика
`restart=unless-stopped`, и любой рестарт в этом окне (ребут хоста, OOM,
падение) вернёт контейнер, который не загрузится. Проверено 07.09.26 в
контейнере 3.3.6 против Gemfile 3.4.10:

```
Bundler::RubyVersionMismatch: Your Ruby version is 3.3.6, but your Gemfile specified 3.4.10
```

Сжать окно сборкой образа заранее (`--build-arg RUBY_VERSION=…`) получится не
всегда: `ARG RUBY_VERSION` в `Dockerfile` появился только в PR #14, на более
старом чекауте флаг молча проигнорируется. Поэтому шаги 3 и 4 идут подряд.

🚨 **Откат — это дерево И образы, одних тегов мало.** Образы `pre-*` несут
прежний Ruby, а дерево после шага 3 требует нового: вернуть только образы —
получить тот же `RubyVersionMismatch`, но уже с обеих сторон.

```bash
git -C /home/q/victory reset --hard <коммит перед апгрейдом>   # для 3.4.10 это 5831765
/usr/bin/docker tag victory-web:pre-ruby34 victory-web
/usr/bin/docker tag victory-sidekiq:pre-ruby34 victory-sidekiq
# далее тот же свап с volume rm
```

Миграций смена Ruby не несёт, но накопившиеся коммиты могут: перед деплоем
сверить `git diff --name-only <прод> origin/main -- db/migrate/`. 07.09.26 там
было пусто (113 файлов с обеих сторон), поэтому шага с `db:migrate` в процедуре
нет — он не универсален.

⚠️ `victory-rubybox` (образ для `bin/rb`) имеет энтрипойнт, ждущий Postgres:
любой `docker run` по нему без `--entrypoint` виснет молча.

**Последние два шага — обязательны, иначе состояние прода снова станет
невидимым:**

```bash
bin/prod-mark            # отметить в GitHub, что именно выкачено
```

`bin/prod-mark` двигает ветку `prod` на выкаченный коммит и ставит тег
`deploy/<dd.MM.yy-HHmm>` с метаданными (Ruby, образ, хост). Без этого GitHub
о выкатке не знает: мерж в `main` и деплой — независимые события, и отличить
«лежит в main» от «работает на сайте» неоткуда. Ровно так 07.09.26 прод
незаметно отстал на 33 коммита.

Ветку `prod` тянет обычный `git fetch`, а `.git` у всех worktree общий —
поэтому `session-start.sh` показывает состояние прода каждой сессии и считает,
сколько коммитов ждёт выкатки. Скрипт отказывается писать при расхождениях
(грязный прод-чекаут, коммит вне `origin/main`) — это осознанно: врущая
отметка хуже отсутствующей. Осмотреть без записи — `bin/prod-mark --check`,
продавить — `--force`.

Затем: обновить строку про прод в `progress.md` (таблица «что в проде»).

## Replit-специфика

`config.hosts.clear` в development разрешает все хосты. Порт 5000 жёстко прибит под Replit proxy. Не удалять — нужно для dev-окружения.

## MCP / Claude Code инфра (Phase 1)

- `.mcp.json` в корне — конфиг 4 MCP-серверов: `serena`, `postgres`, `github`, `rails-guides`.
  MCP `postgres` поднимается контейнером `node:20-alpine` в docker-сети `victory_default`
  — по одному на сессию, безымянные, накапливаются после ребутов.
- `.claude/memory/` — этот memory-bank.
- `.claude/repo-index.md` — компактный индекс «файл → классы» (~5k токенов, читать первым).
- `.claude/repo-map.md` — полный сигнатурный дамп (~190k, on-demand). Оба: `rake repo:map`.
- `.claude/agents/` — проектные субагенты; routing-таблица — `.claude/docs/delegation-map.md`.
- `~/.claude-shared/` — межсессионный обмен: `inbox/`, `events/`, `locks/`.
- `.remember/logs/` — дневной журнал remember-плагина (лежит в main checkout).

Установленные плагины (user-level, не в репо): superpowers, context7, ruby-lsp, pyright-lsp, remember, code-review, feature-dev, telegram, vercel, figma, firecrawl, и др. См. `/home/q/.claude/plugins/installed_plugins.json`.
