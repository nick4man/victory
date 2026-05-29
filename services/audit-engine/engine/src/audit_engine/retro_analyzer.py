"""
Retro Analyzer — «Машина Времени».

Ретроспективный анализ: «Что было бы, если бы мы купили X лет назад?»
Для каждого исторического среза пересчитывает EI с параметрами того периода.
"""

from __future__ import annotations
import logging
from datetime import date, timedelta

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

logger = logging.getLogger(__name__)

from audit_engine.models import (
    AuditInput,
    RetroSnapshot,
    DeltaPoint,
    RetroResult,
    WhatIfResult,
)
from audit_engine.ei_calculator import (
    calculate_mortgage_scenario,
    calculate_cash_scenario,
    calculate_deposit_scenario,
)


def _ei_verdict(ei: float) -> str:
    """Вердикт по значению EI для what-if результата."""
    if ei >= 1.3:
        return "Отличная покупка"
    if ei >= 1.1:
        return "Хорошая"
    if ei >= 0.95:
        return "Нейтрально"
    return "Убыток"


def analyze_retro(
    current_input: AuditInput,
    historical_prices: list[dict],
    historical_macro: list[dict],
    developer_promises: list[dict] | None = None,
) -> RetroResult:
    """
    Провести ретроспективный анализ.
    
    Args:
        current_input: Текущие параметры аудита.
        historical_prices: Список исторических цен:
            [{"date": "2023-04-01", "price_per_sqm": 250000, "source": "cian"}, ...]
        historical_macro: Список исторических макропараметров:
            [{"date": "2023-04-01", "mortgage_rate": 12.0, "deposit_rate": 8.0, 
              "inflation": 7.5, "price_growth": 10.0}, ...]
        developer_promises: Обещания застройщика (опционально):
            [{"date": "2023-01-01", "promised_price": 200000, "actual_price": 250000}, ...]
    
    Returns:
        RetroResult с дельта-анализом и историей EI.
    """
    snapshots = []
    delta_analysis = []
    ei_history = []

    current_price_sqm = current_input.price_total / current_input.area_sqm
    current_date = date.today()

    # Построим индекс макро по датам для быстрого поиска
    macro_by_date = {}
    for m in historical_macro:
        macro_by_date[m["date"]] = m

    for hp in historical_prices:
        snap_date = hp["date"]
        price_sqm = hp["price_per_sqm"]
        source = hp.get("source", "unknown")

        snapshots.append(RetroSnapshot(
            date=snap_date,
            price_per_sqm=price_sqm,
            source=source,
        ))

        # Рассчитываем дельту: купили бы тогда по той цене
        historical_price_total = price_sqm * current_input.area_sqm
        current_value = current_price_sqm * current_input.area_sqm
        delta_abs = current_value - historical_price_total
        delta_pct = round((delta_abs / historical_price_total) * 100, 2) if historical_price_total > 0 else 0

        # Находим макропараметры на ту дату (или ближайшие)
        macro = macro_by_date.get(snap_date, {})
        hist_mortgage = macro.get("mortgage_rate", current_input.mortgage_rate)
        hist_deposit = macro.get("deposit_rate", current_input.deposit_rate)
        hist_growth = macro.get("price_growth", current_input.price_growth_annual)

        # Пересчитываем EI «как если бы решение принималось тогда»
        retro_input = current_input.model_copy(update={
            "price_total": historical_price_total,
            "mortgage_rate": hist_mortgage,
            "deposit_rate": hist_deposit,
            "price_growth_annual": hist_growth,
        })

        try:
            m_result = calculate_mortgage_scenario(retro_input)
            c_result = calculate_cash_scenario(retro_input)
            d_result = calculate_deposit_scenario(retro_input)
            retro_ei = m_result.ei  # используем ипотечный EI как основной
        except (ZeroDivisionError, ValueError, ArithmeticError) as exc:
            logger.warning(
                "Retro EI failed for %s @ %s (price=%.0f, mort=%.2f, dep=%.2f, growth=%.2f): %s",
                current_input.complex_name, snap_date,
                historical_price_total, hist_mortgage, hist_deposit, hist_growth, exc,
            )
            retro_ei = 0.0
            m_result = c_result = d_result = None

        delta_analysis.append(DeltaPoint(
            purchase_date=snap_date,
            purchase_price=round(historical_price_total, 2),
            current_value=round(current_value, 2),
            delta_absolute=round(delta_abs, 2),
            delta_pct=delta_pct,
            ei_at_that_time=retro_ei,
        ))

        ei_entry = {"date": snap_date, "ei_mortgage": retro_ei}
        if m_result and c_result and d_result:
            ei_entry["ei_cash"] = c_result.ei
            ei_entry["ei_deposit"] = d_result.ei
        ei_history.append(ei_entry)

    # Точность прогнозов застройщика
    dev_accuracy = None
    if developer_promises:
        errors = []
        for dp in developer_promises:
            promised = dp.get("promised_price", 0)
            actual = dp.get("actual_price", 0)
            if promised > 0 and actual > 0:
                error_pct = abs(actual - promised) / promised * 100
                errors.append(error_pct)
        if errors:
            avg_error = sum(errors) / len(errors)
            dev_accuracy = round(100 - avg_error, 2)

    return RetroResult(
        complex_name=current_input.complex_name,
        apartment_type=current_input.apartment_type,
        snapshots=snapshots,
        delta_analysis=delta_analysis,
        ei_history=ei_history,
        developer_accuracy_pct=dev_accuracy,
        inflation_adjusted=False,
    )


class RetroAnalyzerV2:
    """Ретро-анализ с загрузкой исторических данных из БД.

    Используется API-слоем: передаём `AsyncSession` и текущий `AuditInput`,
    получаем либо полный `RetroResult`, либо срез `WhatIfResult` для N лет назад.
    """

    def __init__(self, db: AsyncSession):
        self.db = db

    async def load_historical_data(
        self,
        complex_name: str,
        apartment_type: str,
    ) -> tuple[list[dict], list[dict]]:
        """Загрузить исторические цены и макропараметры из БД.

        Returns: `(historical_prices, historical_macro)` в форме, совместимой
        с `analyze_retro()`:
        - historical_prices: [{"date", "price_per_sqm", "source"}, ...]
        - historical_macro:  [{"date", "mortgage_rate", "deposit_rate",
                               "inflation", "price_growth"}, ...]
        """
        prices_rows = await self.db.execute(
            text(
                "SELECT snapshot_date, price_per_sqm, source, macro_snapshot "
                "FROM price_history "
                "WHERE complex_name = :cn "
                "  AND (:at IS NULL OR apartment_type = :at) "
                "ORDER BY snapshot_date ASC"
            ),
            {"cn": complex_name, "at": apartment_type},
        )
        historical_prices: list[dict] = []
        historical_macro: list[dict] = []
        for row in prices_rows.fetchall():
            m = row._mapping
            snap_date = m["snapshot_date"].isoformat()
            historical_prices.append({
                "date": snap_date,
                "price_per_sqm": float(m["price_per_sqm"]),
                "source": m["source"] or "db",
            })
            if m["macro_snapshot"]:
                macro = dict(m["macro_snapshot"])
                macro.setdefault("date", snap_date)
                historical_macro.append(macro)

        # Если в price_history не зашит macro_snapshot — добираем из macro_economics
        if not historical_macro:
            macro_rows = await self.db.execute(
                text(
                    "SELECT date, avg_mortgage_rate, avg_deposit_rate, "
                    "       inflation_annual, cbr_key_rate "
                    "FROM macro_economics "
                    "ORDER BY date ASC"
                )
            )
            for row in macro_rows.fetchall():
                m = row._mapping
                historical_macro.append({
                    "date": m["date"].isoformat() if m["date"] else None,
                    "mortgage_rate": float(m["avg_mortgage_rate"])
                        if m["avg_mortgage_rate"] is not None else None,
                    "deposit_rate": float(m["avg_deposit_rate"])
                        if m["avg_deposit_rate"] is not None else None,
                    "inflation": float(m["inflation_annual"])
                        if m["inflation_annual"] is not None else None,
                    "price_growth": None,
                })

        return historical_prices, historical_macro

    async def analyze_with_db(self, current_input: AuditInput) -> RetroResult:
        """Полный ретро-анализ с автоподгрузкой из БД."""
        prices, macro = await self.load_historical_data(
            current_input.complex_name,
            current_input.apartment_type,
        )
        return analyze_retro(current_input, prices, macro)

    async def what_if_analysis(
        self,
        current_input: AuditInput,
        years_back: list[int],
    ) -> list[WhatIfResult]:
        """«Что, если бы мы купили N лет назад?» — по одной точке на каждое N.

        Для каждого N находим ближайший snapshot в `price_history` (± 6 мес от
        `today - N лет`), пересчитываем EI с тогдашними ставками, возвращаем
        прибыль и вердикт.
        """
        if not years_back:
            return []

        today = date.today()
        area = current_input.area_sqm
        current_value = current_input.price_total
        current_price_sqm = current_value / area if area else 0

        prices, macro = await self.load_historical_data(
            current_input.complex_name,
            current_input.apartment_type,
        )
        macro_by_date = {m["date"]: m for m in macro if m.get("date")}

        results: list[WhatIfResult] = []
        for years in years_back:
            target = today - timedelta(days=365 * years)

            # Ищем ближайший snapshot в окне ±6 месяцев
            window = timedelta(days=183)
            best_snap = None
            best_diff = None
            for p in prices:
                try:
                    snap_date = date.fromisoformat(p["date"])
                except (TypeError, ValueError):
                    continue
                diff = abs((snap_date - target).days)
                if diff <= window.days and (best_diff is None or diff < best_diff):
                    best_snap = (snap_date, p)
                    best_diff = diff

            if best_snap is None:
                continue

            snap_date, snap = best_snap
            price_sqm_then = float(snap["price_per_sqm"])
            purchase_price = price_sqm_then * area
            profit_abs = current_value - purchase_price
            profit_pct = (profit_abs / purchase_price * 100) if purchase_price else 0.0

            m = macro_by_date.get(snap_date.isoformat(), {})
            mortgage_then = float(m.get("mortgage_rate") or current_input.mortgage_rate)
            deposit_then = float(m.get("deposit_rate") or current_input.deposit_rate)
            growth_then = float(m.get("price_growth") or current_input.price_growth_annual)

            retro_input = current_input.model_copy(update={
                "price_total": purchase_price,
                "mortgage_rate": mortgage_then,
                "deposit_rate": deposit_then,
                "price_growth_annual": growth_then,
            })
            try:
                ei_at_purchase = calculate_mortgage_scenario(retro_input).ei
            except Exception:
                ei_at_purchase = 0.0

            results.append(WhatIfResult(
                years_ago=years,
                purchase_date=snap_date.isoformat(),
                purchase_price=round(purchase_price, 2),
                purchase_price_sqm=round(price_sqm_then, 2),
                current_value=round(current_value, 2),
                profit_absolute=round(profit_abs, 2),
                profit_pct=round(profit_pct, 2),
                ei_at_purchase=round(ei_at_purchase, 4),
                ei_verdict=_ei_verdict(ei_at_purchase),
                mortgage_rate_then=mortgage_then,
                deposit_rate_then=deposit_then,
            ))

        return results
