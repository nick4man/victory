---
name: audit-engine-v2-api
description: Канонический контракт REST API `audit-engine-v2` (v2.0) — источник истины для всех агентов конвейера OpenClaw. Используй при написании ТЗ, парсинге ответов и интеграции с сервисом аудита.
---

# audit-engine-v2 — REST API (v2.0)

Канонический справочник по HTTP-ручкам audit-engine-v2. Любое изменение эндпоинта в коде
(`workspace-it-dept/audit-engine-v2/src/audit_engine/api/`) обязано синхронно
отражаться здесь. Если между кодом и SKILL расходится — **SKILL авторитетен
для агентов конвейера**, код должен быть приведён к контракту.

## 1. Метаданные

| Параметр | Значение |
|----------|----------|
| Базовый URL (prod/devops-stack) | `http://<host>:8100/api/v2` |
| Базовый URL (внутри docker-сети) | `http://api:8000/api/v2` |
| Live Swagger UI | `<base>/docs` |
| OpenAPI JSON | `<base>/openapi.json` |
| Версия контракта | 2.0 (PR #1-#6, миграция `f4a2c7b9e821`) |
| Авторизация | не требуется внутри audit-net; наружу — за reverse-proxy |
| Формат | JSON (Pydantic v2, snake_case) |

**Связанные артефакты:**
- `workspace-it-dept/devops/audit-v2-stack/RUNBOOK.md` — операционный контракт (deploy, rollback, smoke).
- `skills/audit-golden-report/SKILL.md` — PDF-сборка; **начиная с v2.0 PDF-генератор тянет данные не из python-библиотеки v1, а из этих REST-ручек**.

## 2. Полная карта endpoint-ов (24 штуки)

| # | Method | Path | Назначение |
|---|--------|------|------------|
| 1 | GET  | `/health` | Liveness + версия сборки |
| 2 | POST | `/audit/` | Создать аудит (апартамент/дом/земля/бизнес) |
| 3 | GET  | `/audit/` | Список аудитов (пагинация, фильтры) |
| 4 | GET  | `/audit/{audit_id}` | Карточка аудита |
| 5 | POST | `/audit/{audit_id}/monte-carlo` | Запуск MC (3 стратегии: cash/mortgage/deposit) |
| 6 | GET  | `/audit/{audit_id}/monte-carlo` | Последний или вся история MC-прогонов |
| 7 | POST | `/audit/{audit_id}/compare-offers` | Multi-offer MC — сравнение всех подходящих банков |
| 8 | GET  | `/audit/{audit_id}/compare-offers` | Последний сохранённый multi-offer MC |
| 9 | GET  | `/audit/{audit_id}/location-score` | Локационный скор по координатам аудита |
| 10 | GET | `/audit/{audit_id}/competitors` | Конкурентный анализ (перцентиль + сигнал) |
| 11 | GET | `/audit/{audit_id}/retro` | Retro-расчёт (историческая траектория) |
| 12 | GET | `/audit/{audit_id}/what-if` | What-if таблица чувствительности |
| 13 | GET | `/macro/latest` | Последние макро-ставки (ЦБ, ипотека, депозит, инфляция) |
| 14 | GET | `/macro/history` | История макро-данных |
| 15 | GET | `/complexes/` | Список ЖК |
| 16 | GET | `/complexes/{complex_id}` | Карточка ЖК |
| 17 | GET | `/price-history/{complex_name}` | История цен ЖК |
| 18 | GET | `/bank-offers/` | Каталог банковских офферов (фильтры: `active`, `program_type`) |
| 19 | GET | `/bank-offers/{offer_id}` | Карточка банковского оффера |
| 20 | POST | `/bank-offers/` | Создать банковский оффер (идемпотентный upsert) |
| 21 | PATCH | `/bank-offers/{offer_id}` | Обновить банковский оффер |
| 22 | DELETE | `/bank-offers/{offer_id}` | Пометить оффер неактивным (soft delete) |
| 23 | GET | `/location/score` | Плоский скор по lat/lon (без привязки к аудиту) |
| 24 | POST (алиас) / GET | см. `audit.py:99, audit.py:231` | — включено в `/audit/*` выше |

> Всего 24 HTTP-ручки, сгруппированных в 7 routers: `health`, `audit`, `macro`, `complexes`, `price-history`, `bank-offers`, `location`.

## 3. Кто чем пользуется (по ролям агентов)

Секция цитируется при написании ТЗ — каждый агент должен знать **только свой набор** и не вылезать за границу.

### `re-analyst` (Аналитик)
Читает данные, запускает тяжёлый MC, собирает выводы в `AUDIT/processed/`.
- `POST /audit/` — создание аудита из сырых данных.
- `POST /audit/{id}/monte-carlo` — запуск 3-стратегийного MC (cash/mortgage/deposit).
- `POST /audit/{id}/compare-offers` — **дефолт для расширенного ипотечного аудита** (multi-offer MC).
- `GET /audit/{id}/retro`, `GET /audit/{id}/what-if` — ретро и чувствительность.
- `GET /audit/{id}/location-score` — локационные факторы (если есть lat/lon).
- `GET /audit/{id}/competitors` — конкурентное позиционирование (если в БД есть снапшоты).
- `GET /macro/latest` — актуальные ставки при интерпретации выводов.

### `financial-scout` (Фин. скаут)
Поддерживает каталог ипотечных офферов и макро-данные.
- `GET /macro/latest`, `GET /macro/history` — читает собственные артефакты.
- CRUD `/bank-offers/` — **единственный WRITE-агент по этому роутеру**. Типовой цикл актуализации:
  1. `GET /bank-offers/?active=true` — текущее состояние;
  2. сверить с источником (сайт банка, ЦБ);
  3. `POST /bank-offers/` (новая запись, идемпотентно upsert-ится по `(bank_name, product_name)`) или `PATCH /bank-offers/{id}` (обновление ставки).
  4. `DELETE /bank-offers/{id}` для снятия с полки (soft-delete).

### `audit-reporter` (Аудитор-Репортёр)
Читает финальные данные, скидывает в PDF. **НЕ пишет** в audit-engine-v2.
- `GET /audit/{id}` — общая карточка для шапки отчёта.
- `GET /audit/{id}/compare-offers` — таблица top-5 банков в PDF.
- `GET /audit/{id}/location-score` — секция «Местные факторы».
- `GET /audit/{id}/competitors` — секция «Позиционирование среди конкурентов».
- `GET /audit/{id}/monte-carlo` — распределения (p5/p50/p95) для сценарных блоков.
- `GET /macro/latest` — строка «источник: ЦБ на <date>».

### `data-junior` (Парсер)
Подаёт в API спарсенные позиции.
- `POST /audit/` — создание аудита из сырого прайса.
- `POST /bank-offers/` — если парсит витрины банков по ТЗ скаута.
- `GET /complexes/`, `GET /complexes/{id}` — проверка, что ЖК уже есть (иначе создаёт через BД-контур db-architect, **не через API**).

### `db-architect` (БД Архитектор)
**Read-only по REST** (валидирует консистентность). Прямые изменения — только через alembic + `docker compose exec postgres-v2 psql`.
- `GET /complexes/`, `GET /price-history/{complex_name}` — проверки целостности.
- `GET /health` — перед миграциями.

### `devops-engineer`
- `GET /health` — smoke после deploy (см. RUNBOOK §5).
- `GET /bank-offers/?active=true | jq 'length'` — проверка post-seed счётчика.
- Всё остальное — через `docker compose exec` (не REST).

### `it-debugger`
- `GET /health` — gate перед прогоном smoke-чек-листа.
- Любые `GET /*` для верификации постдеплоя.
- **Не модифицирует состояние** (POST/PATCH/DELETE запрещены).

## 4. Детализация ключевых ручек

Все тела запросов — Pydantic-модели из `src/audit_engine/models.py`. Ниже — минимально воспроизводимые payload-ы.

### 4.1 `POST /audit/` — создание аудита

Дискриминатор: поле `property_type` ∈ {`APARTMENT`, `HOUSE`, `LAND`, `BUSINESS`}. Если не указано — считается APARTMENT (обратная совместимость).

#### APARTMENT (минимальный)
```json
{
  "property_type": "APARTMENT",
  "complex_name": "ЖК Тестовый",
  "apartment_type": "2BR",
  "area_sqm": 65.0,
  "price_total": 12000000,
  "monthly_rent": 45000,
  "mortgage_rate": 17.0,
  "deposit_rate": 14.0,
  "price_growth_annual": 7.9,
  "horizon_years": 5,
  "lat": 55.7558,
  "lon": 37.6173
}
```

#### HOUSE
```json
{
  "property_type": "HOUSE",
  "object_name": "КП Солнечный, уч. 12",
  "area_sqm": 180.0,
  "land_area_sotki": 10.0,
  "price_total": 28000000,
  "monthly_rent": 80000,
  "mortgage_rate": 17.5,
  "deposit_rate": 14.0,
  "price_growth_annual": 6.0,
  "horizon_years": 5
}
```

#### LAND
```json
{
  "property_type": "LAND",
  "object_name": "Участок Новорижское ш., 45 км",
  "land_area_sotki": 15.0,
  "price_total": 9000000,
  "category": "ИЖС",
  "price_growth_annual": 5.0,
  "deposit_rate": 14.0,
  "horizon_years": 5
}
```

#### BUSINESS (DCF)
```json
{
  "property_type": "BUSINESS",
  "object_name": "Кофейня у метро",
  "price_total": 30000000,
  "annual_revenue": 40000000,
  "ebitda": 8000000,
  "ebitda_margin": 20.0,
  "revenue_growth_annual": 8.0,
  "discount_rate": 20.0,
  "terminal_growth": 3.0,
  "tax_rate": 20.0,
  "horizon_years": 5,
  "multiple_ebitda": 5.0
}
```

**Ответ:** `200` + `AuditResult`. Ключевые поля: `id` (UUID созданной записи — используй его в последующих `GET /audit/{id}/...`), `complex_name`, `price_per_sqm`, `scenarios` (матрица 3×3), `ei_cash`, `ei_deposit`, `ei_mortgage`, `monte_carlo` (если `run_monte_carlo=true`), `verdict`, `verdict_explanation`, `risks`, `assumptions`. Все числовые поля в `snake_case`.

### 4.2 `POST /audit/{id}/monte-carlo`
Query: `num_simulations` (default `100000`, ceiling `1000000` → 413), `seed` (int, опц.), `strategy` (опц., default — все три).

**Ответ:** `MonteCarloSummary` с секциями `cash`, `mortgage`, `deposit`; каждая — `ei_mean`, `ei_p5`, `ei_p50`, `ei_p95`, `buy_probability`, `verdict`.

### 4.3 `POST /audit/{id}/compare-offers`
Query: `num_simulations` (default `100000`), `seed`, `limit` (top-N банков по ставке, default `20`).

**Минимальный вызов (smoke):** `?num_simulations=10000`.

**Ответ:** `MultiOfferMCResult`
```json
{
  "num_offers": 24,
  "num_simulations_per_offer": 100000,
  "per_offer": [
    {
      "offer_id": "uuid",
      "bank_name": "Сбер",
      "product_name": "Семейная",
      "rate": 6.0,
      "ei_mortgage_median": 1.12,
      "buy_probability": 68.4,
      "eligible": true
    }
  ],
  "recommended_offer_id": "uuid",
  "recommended_ei_median": 1.12,
  "skipped_ineligible": 3
}
```

### 4.4 `GET /audit/{id}/location-score`
Query: `radius_km` (default `2.0`).

**Ответ:** `LocationScore`
```json
{
  "score": 0.72,
  "metro_count": 3,
  "schools_count": 5,
  "hospitals_count": 2,
  "density_score": 0.8,
  "top_pois": [{"type": "metro", "name": "Таганская", "distance_m": 320}]
}
```

Если POI-таблица пуста — **не ошибка**: `score=0.0`, счётчики нулевые, `top_pois=[]`. Агент обязан обработать это как «данных недостаточно», а не как failure.

### 4.5 `GET /audit/{id}/competitors`
Query: `radius_m` (default `2000`, range `1..50000`), `days_back` (default `90`, range `1..365`).

**Ответ:** `CompetitorAnalysis`
```json
{
  "signal": "OVERPAY",
  "audit_price_per_sqm": 184615,
  "median_price_per_sqm": 170000,
  "p25_price_per_sqm": 155000,
  "p75_price_per_sqm": 180000,
  "percentile": 82.5,
  "sample_size": 14,
  "radius_m": 2000,
  "top5": [{"source": "cian", "price_per_sqm": 168000, "distance_m": 520}],
  "hedonic": {
    "predicted_price_per_sqm": 172500.0,
    "ci_lo_95": 158300.0,
    "ci_hi_95": 187800.0,
    "n_used": 12,
    "r_squared": 0.78,
    "residual_std": 0.041,
    "feature_names": ["intercept", "rooms", "log_area", "distance_km"],
    "coefficients": [11.953, 0.041, 0.118, -0.014]
  }
}
```

Сигналы: `OVERPAY` (перцентиль ≥ 75), `FAIR` (25..75), `UNDERPAY` (≤ 25), `INSUFFICIENT` (`sample_size < 5`). `INSUFFICIENT` — **штатный** ответ, не ошибка.

**Поле `hedonic`** (опционально, `null` при `sample_size < 8` или вырожденной матрице признаков): OLS-регрессия `log(price_per_sqm) ~ rooms + log(area) + distance_km`. Даёт справедливую цену с учётом характеристик объекта (в отличие от чистой медианы). Признаки с нулевой вариативностью автоматически отбрасываются — клиент должен опираться на `feature_names`. `audit-reporter` показывает в PDF: «Прогноз справедливой цены: X ₽/м² (95% CI: Y..Z; R²=…, n=…)».

### 4.6 `GET /bank-offers/`
Query: `active` (bool, default `true`), `program_type` (опц.: `family`, `it`, `standard`, `subsidized`).

**Ответ:** `list[BankOffer]`. Каждый — `id`, `bank_name`, `product_name`, `rate`, `min_down_payment_pct`, `max_loan_amount`, `program_type`, `active`, `eligibility_notes`.

### 4.7 `GET /location/score` (плоский, без аудита)
Query: `lat`, `lon`, `radius_km` (default `2.0`). Подходит для UI-превью и быстрых проверок, где ещё нет `audit_id`.

## 5. Операционные правила (обязательны для всех агентов)

1. **Health gate.** Перед batch-запусками: `GET /api/v2/health` → `200`. Если `5xx` — ТЗ ставится в STALL, Генерал вызывает `devops-engineer` по RUNBOOK §7.
2. **MC-симуляции.**
   - default `num_simulations = 100_000` (`settings.mc_default_simulations`).
   - ceiling `1_000_000` (`settings.mc_max_simulations`); превышение → HTTP `413`.
   - Smoke / быстрый прогон → `10_000`.
3. **Идемпотентность.**
   - `POST /audit/` кэширует по хэшу входа (поле `idempotency_hit` в ответе).
   - `POST /bank-offers/` идемпотентен по `(bank_name, product_name)` — апдейт ставки не дублирует запись.
4. **Дискриминатор `property_type`.** При создании не-APARTMENT аудита поле обязательно. Отсутствие → 422.
5. **Координаты.** Ручки `location-score` и `competitors` **по радиусу** требуют `lat/lon` в теле аудита. Без координат: `location-score` → 400, `competitors` — fallback на поиск по названию ЖК.
6. **Сигнал INSUFFICIENT.** `competitors` возвращает сигнал `INSUFFICIENT` при `sample_size < 5` — PDF-репортер обязан в такой секции писать «выборка недостаточна (<5 объявлений), оценка носит ориентировочный характер», а не опускать блок.
7. **POI-таблица.** На свежем стеке пуста (SEED отложен). `/location/score` вернёт `score=0.0` — это **штатный** ответ, не ошибка.
8. **Rate-limit.** MC-ручки обёрнуты семафором (`_MC_OFFLOAD_SEM`); параллельные тяжёлые прогоны сериализуются. Не запускать >5 compare-offers одновременно — эффективнее очередь.
9. **Персистентность MC.** Результаты `monte-carlo` и `compare-offers` сохраняются в `monte_carlo_runs`; повторный `GET` (без `POST`) отдаёт последний снимок.
10. **Pydantic snake_case.** Все поля — `snake_case`. Никаких `camelCase`.

## 6. Связь с другими артефактами конвейера

| Артефакт | Зачем |
|----------|-------|
| `skills/audit-golden-report/SKILL.md` | PDF-сборка. С v2.0 тянет данные через HTTP-ручки выше, а не через `import audit_engine`. |
| `workspace-it-dept/devops/audit-v2-stack/RUNBOOK.md` | Deploy, rollback, migration-чек, smoke-тесты. |
| `workspace-conveyor/ACCESS_MATRIX.md` | Кто из агентов имеет read/write по REST. |
| `workspace-conveyor/PIPELINE_FLOW.md` | Где новые ручки вклиниваются в поток «Аудит недвижимости». |
| `workspace-conveyor/GENERAL/templates/TZ_AUDIT_REPORTER_TEMPLATE.md` | Шаблон ТЗ — обязательные секции PDF, опирающиеся на v2-API. |

## 7. Верификация контракта

Перед мёрджем ветки `python-senior` обязан:
```bash
# 1. SKILL упомянут в ключевых файлах конвейера (≥5):
grep -rl "audit-engine-v2-api" \
  /home/user/openclaw/skills \
  /home/user/openclaw/workspace-conveyor \
  /home/user/openclaw/agents

# 2. Нет прямых импортов v1-библиотеки из конвейера:
grep -r "audit_engine.calculate" /home/user/openclaw/workspace-conveyor
# → 0 совпадений.

# 3. Контракт совпадает с кодом (spot-check):
diff <(curl -s http://localhost:8100/api/v2/openapi.json | jq -r '.paths | keys[]' | sort) \
     <(awk '/^\| [0-9]+ \|/ {print $6}' SKILL.md | sort)
```

## 8. Changelog

| Версия | Дата | Что изменилось | PR |
|--------|------|----------------|----|
| 2.0 | 2026-04-19 | Первая версия SKILL; зафиксированы 24 ручки, 4 PropertyType, compare-offers, location-score, competitors, mixture MC, DCF MC. | #7 |
