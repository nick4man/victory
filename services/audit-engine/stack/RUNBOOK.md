# RUNBOOK — audit-v2-stack

Операционный контракт Docker-стека `audit-engine-v2`. Этот файл — единственный
источник истины для deploy / update / rollback / smoke. Всё, что здесь
описано, — согласовано с SKILL [`audit-engine-v2-api`](../../../skills/audit-engine-v2-api/SKILL.md).

- **Scope:** живой сервер Босса после `git fetch` + обновление контейнеров.
- **Владелец:** `devops-engineer`; smoke-верификация — `it-debugger`.
- **Автор триггеров:** `project-planner` (Генерал) пишет ТЗ строго из этого runbook.

---

## 0. Предпосылки

| Проверка | Команда | Ожидаемый результат |
|----------|---------|---------------------|
| Docker Engine + Compose v2 | `docker --version && docker compose version` | Docker ≥ 24, Compose ≥ 2.20 |
| Порт `5433` свободен | `lsof -i :5433` | пусто |
| Порт `8100` свободен | `lsof -i :8100` | пусто |
| Наличие тома с данными | `docker volume ls \| grep pgdata-v2` | если строка есть → **Сценарий A**; если пусто → **Сценарий B** |
| Рабочий каталог | `cd workspace-it-dept/devops/audit-v2-stack` | `docker-compose.yml` на месте |

Если `docker compose` отсутствует — сначала установить Docker Engine v24+ (`apt install docker.io docker-compose-plugin`), потом возвращаться к этому runbook-у.

---

## 1. Сценарий A — обновление существующего стека (БД сохраняется)

**Применимо по умолчанию**, если на машине уже есть том `pgdata-v2` и Босс не
просил «сбросить базу».

> **GPU vs CPU.** Если на хосте есть NVIDIA-драйвер + `nvidia-container-toolkit` — использовать команды ниже как есть (mc-worker стартует в GPU-режиме, CuPy). Если GPU нет или nvidia-runtime не настроен — применять **CPU-override**, см. §1.1.

```bash
cd workspace-it-dept/devops/audit-v2-stack

# 1. Обновление кода
git fetch origin claude/sync-branch-root-baRrl
git checkout claude/sync-branch-root-baRrl
git pull --ff-only

# 2. Остановка контейнеров БЕЗ -v (том pgdata-v2 остаётся жив)
docker compose down

# 3. Пересборка API и MC-воркера (только они изменились)
docker compose build api mc-worker

# 4. Старт
docker compose up -d

# 5. Миграции — идемпотентно прогоняются в CMD Dockerfile.api:
#    sh -c "alembic upgrade head && uvicorn audit_engine.api.app:app ..."
#    Но страховочный прогон полезен, чтобы увидеть лог:
./migrate.sh

# 6. Seed банковских офферов (идемпотентный upsert)
docker compose exec api python -m scripts.seed_bank_offers

# 7. Smoke
curl -fsS http://localhost:8100/api/v2/health
curl -fsS "http://localhost:8100/api/v2/bank-offers?active=true" | jq 'length'
```

**Результат:** API отвечает, БД сохранила все исторические аудиты, 22+
активных банковских оффера, миграция `f4a2c7b9e821` применена.

### 1.1. CPU-режим (без NVIDIA / GPU)

На сервере Босса GPU нет → mc-worker надо собрать без CuPy. Используем
override `docker-compose.cpu.yml` (собирает mc-worker из `Dockerfile.api` и
запускает его скриптом `audit_engine.monte_carlo_worker` с `MC_USE_GPU=false`).

**Быстрый путь:**
```bash
cd workspace-it-dept/devops/audit-v2-stack
./stop.sh
./start-cpu.sh
./migrate.sh
docker compose -f docker-compose.yml -f docker-compose.cpu.yml exec api \
    python -m scripts.seed_bank_offers
curl -fsS http://localhost:8100/api/v2/health
```

**Ручной путь (если нужно явно видеть команды):**
```bash
docker compose down                                                           # -v НЕ указываем
docker compose -f docker-compose.yml -f docker-compose.cpu.yml build mc-worker
docker compose -f docker-compose.yml -f docker-compose.cpu.yml up -d
./migrate.sh
docker compose -f docker-compose.yml -f docker-compose.cpu.yml exec api \
    python -m scripts.seed_bank_offers
```

Все последующие `docker compose ...` команды на этой машине **должны**
передавать оба `-f` файла (иначе compose не увидит override и попытается
стартовать GPU-конфиг). Для удобства можно экспортировать переменную:
```bash
export COMPOSE_FILE=docker-compose.yml:docker-compose.cpu.yml
```
После этого `docker compose up/down/logs` работают без явных `-f`.

**Проверка, что worker действительно в CPU-режиме:**
```bash
docker compose logs mc-worker | grep -iE 'numpy|cupy'
# → "CuPy not available, using NumPy (CPU)" — ожидаемая строка.
```

---

## 2. Сценарий B — пересоздание с нуля (СБРОС БД)

Применять **только** когда:
1. Босс явно сказал «сбросить БД» / «чистое окружение»; ИЛИ
2. `pgdata-v2` физически повреждён (постгрес не стартует, `fatal: database files are incompatible`).

```bash
cd workspace-it-dept/devops/audit-v2-stack

./stop.sh

# ВНИМАНИЕ: -v удалит том pgdata-v2 безвозвратно.
docker compose down -v

git fetch origin claude/sync-branch-root-baRrl
git checkout claude/sync-branch-root-baRrl
git pull --ff-only

docker compose build --no-cache api mc-worker
docker compose up -d

# Миграции сами стартанут в CMD; ждём healthcheck
until curl -fsS http://localhost:8100/api/v2/health >/dev/null; do sleep 2; done

# Seed банков
docker compose exec api python -m scripts.seed_bank_offers

# POI из OpenStreetMap (Phase D, Overpass API).
# Можно грузить для предзаданных городов (ryazan/moscow/spb) или по произвольному bbox.
# Скрипт идемпотентный (upsert по poi_type + координата ~1м).
docker compose exec api python -m scripts.load_poi_osm --city ryazan
# При необходимости:
#   docker compose exec api python -m scripts.load_poi_osm --city moscow
#   docker compose exec api python -m scripts.load_poi_osm --bbox 54.55,39.60,54.72,39.85 --city-label "Рязань"
# Dry-run (без записи в БД):
#   docker compose exec api python -m scripts.load_poi_osm --city ryazan --dry-run
```

---

## 3. Проверка миграций

```bash
docker compose exec postgres-v2 psql -U audit_user -d re_audit \
  -c "SELECT version_num FROM alembic_version;"
```
Ожидаемое: `g5b3d8f1a932` (голова после PR #8 — PostGIS geom для POI).

```bash
docker compose exec postgres-v2 psql -U audit_user -d re_audit -c "\dt"
```
Ожидаемые таблицы:
```
audit_archive
apartments
bank_offers
competitors
complexes
developers
historical_prices
macro_economics
monte_carlo_runs
points_of_interest
price_history
```

Если хотя бы одной таблицы нет — см. §7 «Частые ошибки» → `alembic upgrade head failed`.

---

## 4. Smoke-тесты API (чек-лист для `it-debugger`)

Выполнять последовательно. Каждый шаг — отдельный пункт отчёта в
`SHARED/handoffs/<project>/NN__it-debugger_to_devops-engineer.json`.

| # | Команда | Ожидание | Если провалился |
|---|---------|----------|-----------------|
| 1 | `curl -fsS http://localhost:8100/api/v2/health` | `200`, `{"status":"ok", ...}` | `docker compose logs api` |
| 2 | `curl -fsS "http://localhost:8100/api/v2/bank-offers?active=true" \| jq 'length'` | `>= 22` | перезапустить seed |
| 3 | `curl -fsS -X POST http://localhost:8100/api/v2/audit/ -H 'Content-Type: application/json' -d @smoke_apartment.json` | `201`, в теле есть `id` | проверить payload по SKILL §4.1 |
| 4 | `curl -fsS -X POST "http://localhost:8100/api/v2/audit/<id>/compare-offers?num_simulations=10000"` | `200`, `per_offer: [...]`, `recommended_offer_id` | логи api + mc-worker |
| 5 | `curl -fsS "http://localhost:8100/api/v2/location/score?lat=54.62&lon=39.74&radius_km=2"` | `200`; при загруженных POI Рязани — `score > 0`; если POI пусты — `score=0.0` (штатно, запустить `load_poi_osm`) | — |
| 6 | `curl -fsS "http://localhost:8100/api/v2/audit/<id>/competitors"` | `200`; `signal: "INSUFFICIENT"` допустимо | — |

Минимальный `smoke_apartment.json` (см. `skills/audit-engine-v2-api/SKILL.md` §4.1 APARTMENT).

**Критерий APPROVED:** все 6 шагов зелёные. При красном шаге `it-debugger` возвращает ТЗ `devops-engineer`-у с конкретным логом.

---

## 5. Upgrade-сценарий (проверка сохранения БД)

Для верификации, что Сценарий A действительно не теряет данные:

```bash
# На старом коммите
git checkout 812c0ea
docker compose up -d --build
AID=$(curl -fsS -X POST http://localhost:8100/api/v2/audit/ \
  -H 'Content-Type: application/json' \
  -d @smoke_apartment.json | jq -r '.id')
echo "Created audit: $AID"

# Переключаемся на голову
git checkout claude/sync-branch-root-baRrl
git pull --ff-only
docker compose down   # без -v
docker compose build api mc-worker
docker compose up -d
./migrate.sh

# Старый аудит всё ещё читается
curl -fsS "http://localhost:8100/api/v2/audit/$AID" | jq '.id'
# → тот же UUID
```

Если `404` — Сценарий A сломан, эскалация в Генералу + Боссу.

---

## 6. Rollback

Цепочка миграций (head → root):

| Шаг | Revision ID | Что добавила |
|-----|-------------|--------------|
| head | `f4a2c7b9e821` | `competitors` (PR #5) |
| | `e3b1f0a9c210` | `points_of_interest` (PR #4) |
| | `d2a9b1c4e501` | поля `property_type`, `land_area_sotki` и пр. (PR #3) |
| | `c9f3b4e5d678` | `bank_offers` (PR #2) |
| | `b7d1a2c3d4e5` | `monte_carlo_runs` + idempotency (PR #1) |
| | `1638584a66fa` | — |
| root | `e88a8d3263c9` | первая миграция |

**Откат на один PR назад:**
```bash
docker compose exec api alembic downgrade <target_revision>
# затем
git checkout <previous_sha>
docker compose up -d --build api mc-worker
```

| Откат до | `alembic downgrade` | Git-чекпоинт |
|----------|---------------------|--------------|
| PR #5 → #4 | `e3b1f0a9c210` | commit `0273f70` |
| PR #4 → #3 | `d2a9b1c4e501` | commit `6f701ff` |
| PR #3 → #2 | `c9f3b4e5d678` | commit `054719e` |
| PR #2 → #1 | `b7d1a2c3d4e5` | commit `812c0ea` |

**Полный откат с потерей данных (аварийный):**
```bash
docker compose down -v
git checkout <target_sha>
docker compose up -d --build
```

---

## 7. Частые ошибки

### 7.1 `Port 5433 already in use`
```bash
lsof -i :5433
# kill старого postgres:
sudo kill <PID>
./start.sh
```

### 7.2 `alembic upgrade head failed`
```bash
docker compose logs api | grep -iE 'alembic|error' | tail -40
docker compose exec api alembic history
docker compose exec api alembic current
```
Частый случай — расхождение `alembic_version` с головой файлов. Решение — ручной `alembic stamp <expected_head>` **только** если devops-engineer уверен, что схема соответствует (сверить `\d <table>` с ожидаемым).

### 7.3 `seed_bank_offers: connection refused`
API ещё не healthy.
```bash
docker compose ps
# дождаться status=healthy у audit-v2-api, затем повторить
docker compose exec api python -m scripts.seed_bank_offers
```

### 7.4 `mc-worker` не стартует (нет GPU)
На боевой машине без NVIDIA/`nvidia-container-toolkit` — используй CPU-override:
см. §1.1. Короткая версия: `./start-cpu.sh` вместо `./start.sh`.

Симптомы: в логах `mc-worker` `could not select device driver "nvidia"` или
контейнер падает с `nvidia-container-cli: initialization error`. Диагностика:
```bash
docker compose logs mc-worker | head -20
```
Если GPU действительно нет — переключайся на CPU-override и не теряй время
на установку NVIDIA-стека.

### 7.5 `/location/score` возвращает `score=0.0`
Это **не ошибка**, но теперь есть лечение. Если таблица `points_of_interest`
пуста — запусти `load_poi_osm` для нужного города:
```bash
docker compose exec api python -m scripts.load_poi_osm --city ryazan
```
Скрипт идемпотентный, тянет POI из OpenStreetMap Overpass API (бесплатно,
без API-ключа) и пишет напрямую в БД. После этого `/location/score` начнёт
возвращать значения > 0 для координат, где есть инфраструктура. Если `score`
остался 0 после загрузки — проверь, что координаты находятся внутри bbox
города (CITIES в `scripts/load_poi_osm.py`).

### 7.6 `/audit/{id}/competitors` возвращает `signal: "INSUFFICIENT"`
Тоже штатно: в БД меньше 5 снапшотов по району / ЖК за `days_back` дней. PDF-репортер пишет соответствующую оговорку.

---

## 7а. Ежемесячный back-testing точности

Раз в месяц (1-го числа) Генерал обязан прогнать сверку прогнозов с реальностью:
```bash
docker compose exec api python -m scripts.backtest --month $(date -d 'last month' +%Y-%m)
```
- Скрипт сам собирает все аудиты за указанный месяц из `audit_archive`.
- Для каждого ищет фактическую цену в `price_history` (или fallback — более свежий аудит того же ЖК/типа).
- Считает **MAPE**, **RMSE**, **sign-accuracy** (совпало ли направление вердикта).
- Пишет отчёт в `SHARED/accuracy/<YYYY-MM>.md`.

**Exit-code:**
- `0` — всё в норме.
- `3` — MAPE > 20% (срочная пересборка калибровки `mc_price_growth_std`, эскалация Боссу).

**Оффлайн-проверка** (для CI / reproducibility):
```bash
python -m scripts.backtest --input pairs.json --dry-run
```

---

## 7б. Регулярные fetcher-ы (cron)

Заменяют ручные seed-скрипты для актуализации макро и банковских ставок.

### 7б.1 CBR key rate (ежедневно, SOAP)
```bash
0 8 * * * cd /app && python -m scripts.fetch_macro_cbr >> /var/log/cron.log 2>&1
```
- Источник: `https://www.cbr.ru/DailyInfoWebServ/DailyInfo.asmx` SOAP `KeyRate` + `cbr-xml-daily.ru/daily_json.js` фолбэк.
- 3 попытки с backoff 1.5/3/6 с.
- Idempotent upsert по `macro_economics.date`.
- Exit-code `2` — все источники недоступны (cron эскалирует), `3` — оба значения `None`.

### 7б.2 CBR inflation YoY (Пн/Чт)
```bash
15 8 * * 1,4 cd /app && python -m scripts.fetch_inflation_cbr
```
- Источник: `https://www.cbr.ru/hd_base/infl/` (HTML, серверный рендер, regex-парсинг).
- Записывает `inflation_annual` по дате = последний день месяца.
- Стандартная задержка публикации Росстата ~ 1.5 мес — на 07.05 свежий = март.

### 7б.3 Bank offers — авто-источники (Пн/Чт)
```bash
# Primary (3 банка): banki.ru schema.org JSON-LD
30 8 * * 1,4 cd /app && python -m scripts.fetch_bank_offers --source banki-ru

# Дополнительно: Газпромбанк через sravni.ru (Next.js __NEXT_DATA__)
30 8 * * 1,4 cd /app && python -m scripts.fetch_bank_offers \
    --source sravni-bank --bank-slug gazprombank
```
- `banki-ru` даёт ВТБ, Альфа-Банк, ДОМ.РФ (~30 офферов). Сбера и Газпромбанка там нет.
- `sravni-bank --bank-slug gazprombank` даёт 4 оффера ГПБ. Сбер на sravni
  не публикуется (DomClick-only).
- При фейле `banki-ru` — авто-fallback на `cbr-keyrate-derived` (ориентир от ЦБ).

### 7б.4 Сбербанк — ручной maintenance
DomClick API закрыт OAuth, прямой сайт за Cloudflare → автоматизация невозможна
без партнёрских ключей. Поддержка через YAML-файл:
```bash
docker exec audit-v2-api python -m scripts.fetch_bank_offers \
    --source manual-yaml --input /app/data/manual_offers/sberbank.yaml
```
Файл `data/manual_offers/sberbank.yaml` версионируется в репо. Обновлять
~ раз в месяц после изменения ставок (или сразу после смены ключевой ЦБ):
1) Сравнить актуальные ставки с https://domclick.ru/ipoteka/programs.
2) Поправить `rate_min/rate_max/valid_from` в YAML.
3) Закоммитить и запустить команду выше.

### 7б.5 Разовая подгрузка через YAML (общий случай)
```bash
docker compose exec api python -m scripts.fetch_bank_offers \
    --source manual-yaml --input /tmp/special_offers.yaml
```
Используется `financial-scout` после ручной верификации новых офферов
(см. SLA в `agents/financial-scout/SOUL.md`). YAML формат — список dict-ов
с полями `bank_name`, `product_type`, `product_name`, `rate_min`, … и т.д.
(см. `OfferUpdate` в `scripts/fetch_bank_offers.py`).

---

## 8. Интерфейс с Генералом (`project-planner`)

Генерал при триггерах `обнови аудит-стек` / `задеплой последний аудитник` / `pull latest на сервер` обязан:

1. Процитировать этот RUNBOOK, указав **Сценарий A** (default) или **B** (если Босс сказал «сбросить БД»).
2. Написать ТЗ `devops-engineer`: скопировать блок команд §1 или §2 целиком.
3. После `devops-engineer` — **обязательно** запустить `it-debugger` с чек-листом §4 (минимум 3 итерации по WORKSPACE_RULES).
4. Финальный статус `APPROVED` → отчёт Боссу по формату `SHARED/status/<project>.json`.

---

## 9. Changelog

| Версия | Дата | Что изменилось | PR |
|--------|------|----------------|----|
| 1.0 | 2026-04-19 | Первая версия RUNBOOK; сценарии A/B, rollback-таблица на 4 PR-а, smoke-чек-лист из 6 пунктов. | #7 |
