# 🏗️ СОДИКС Audit Engine v2.0 — Cheat Sheet

> **Базовый URL:** `http://localhost:8100`
> **Документация (Swagger):** http://localhost:8100/api/v2/docs

---

## 🔍 Проверка здоровья

```bash
curl http://localhost:8100/api/v2/health
```
Ожидаемый ответ: `{"status": "ok", "version": "2.0.0", "db_status": "healthy", "tables_count": 8}`

---

## 📊 Макро-данные (ЦБ РФ)

**Последние данные:**
```bash
curl http://localhost:8100/api/v2/macro/latest
```

**История (последние 30 записей):**
```bash
curl "http://localhost:8100/api/v2/macro/history?limit=30"
```

---

## 🏠 Запуск аудита (ГЛАВНАЯ ФУНКЦИЯ)

```bash
curl -X POST http://localhost:8100/api/v2/audit/ \
  -H "Content-Type: application/json" \
  -d '{
    "complex_name": "ЖК Солнечный",
    "apartment_type": "2BR",
    "area_sqm": 65.0,
    "price_total": 12000000,
    "monthly_rent": 45000,
    "horizon_years": 5,
    "run_monte_carlo": true,
    "mc_simulations": 10000
  }'
```

### Параметры запроса

| Параметр | Тип | Обязательный | Описание |
|---|---|---|---|
| `complex_name` | string | ✅ | Название ЖК |
| `apartment_type` | string | ✅ | Тип: Studio, 1BR, 2BR, 3BR |
| `area_sqm` | float | ✅ | Площадь (м²) |
| `price_total` | float | ✅ | Цена квартиры (руб.) |
| `monthly_rent` | float | ✅ | Аренда аналога (руб./мес.) |
| `mortgage_rate` | float | ❌ | Ставка ипотеки (авто: ЦБ + 2%) |
| `mortgage_term_years` | int | ❌ | Срок ипотеки (по умолч. 20 лет) |
| `down_payment_pct` | float | ❌ | Первоначальный взнос (по умолч. 20%) |
| `deposit_rate` | float | ❌ | Ставка депозита (авто: ЦБ − 1%) |
| `price_growth_annual` | float | ❌ | Рост цен (авто: инфляция + 2%) |
| `horizon_years` | int | ❌ | Горизонт оценки (по умолч. 5 лет) |
| `cash_discount_pct` | float | ❌ | Скидка за 100% оплату (по умолч. 10%) |
| `run_monte_carlo` | bool | ❌ | Запуск Monte-Carlo (по умолч. true) |
| `mc_simulations` | int | ❌ | Число симуляций MC (по умолч. 10000) |

### Расшифровка ответа

**Вердикт (verdict):**
- 🟢 `BUY` — покупка целесообразна (EI ≥ 1.2)
- 🟡 `NEUTRAL` — нейтрально (EI 0.9–1.1)
- 🔴 `WAIT` — рекомендуется подождать (EI < 0.8)

**EI (Efficiency Index):**
- `ei_cash` — при оплате 100%
- `ei_mortgage` — при ипотеке
- `ei_deposit` — при размещении денег на депозит

**Monte-Carlo (`monte_carlo`):**
- `recommended_strategy` — рекомендуемая стратегия
- `confidence_level` — уровень уверенности (high/medium/low)
- Для каждой стратегии: `ei_mean`, `ei_median`, `ei_p5`-`ei_p95`, `buy_probability`

---

## 📋 История аудитов

**Список:**
```bash
curl "http://localhost:8100/api/v2/audit/?limit=20&skip=0"
```

**Конкретный аудит по ID:**
```bash
curl http://localhost:8100/api/v2/audit/{audit_id}
```

---

## 🏢 Жилые комплексы

**Список:**
```bash
curl http://localhost:8100/api/v2/complexes/
```

**Детали с квартирами:**
```bash
curl http://localhost:8100/api/v2/complexes/{id}
```

---

## ⚡ Быстрый тест

Скопируйте и вставьте для проверки:
```bash
curl -s http://localhost:8100/api/v2/health && echo " ✅ API OK" || echo " ❌ API DOWN"
```

---

*СОДИКС ИТ-Департамент • Audit Engine v2.0.0 • 2026-04-14*
