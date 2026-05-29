"""EI для частного дома — переиспользуем квартирную математику + земля + утилиты.

Отличия от APARTMENT:
* `land_area_sotka × land_price_per_sotka` добавляется к прогнозной стоимости
  с собственным ростом `land_growth_annual` (обычно ниже, чем у дома).
* `annual_utilities_cost × horizon_years` вычитается из числителя всех трёх
  стратегий как реальные расходы собственника.
"""
from __future__ import annotations

from audit_engine.ei_calculator import (
    calculate_cash_scenario,
    calculate_deposit_scenario,
    calculate_mortgage_scenario,
)
from audit_engine.models import (
    AuditInput,
    HouseEIDetails,
    HouseInput,
)


def _to_audit_input(h: HouseInput) -> AuditInput:
    """Проекция HouseInput -> AuditInput для переиспользования квартирных формул."""
    return AuditInput(
        complex_name=h.object_name,
        apartment_type="HOUSE",
        area_sqm=h.area_sqm,
        price_total=h.price_total,
        monthly_rent=h.monthly_rent,
        mortgage_rate=h.mortgage_rate,
        mortgage_term_years=h.mortgage_term_years,
        down_payment_pct=h.down_payment_pct,
        deposit_rate=h.deposit_rate,
        price_growth_annual=h.price_growth_annual,
        horizon_years=h.horizon_years,
        cash_discount_pct=h.cash_discount_pct,
        lat=h.lat,
        lon=h.lon,
        cadastral_number=h.cadastral_number,
    )


def calculate_house_ei(h: HouseInput) -> HouseEIDetails:
    """Квартирные формулы + земельная прибавка к активу + коммуналка-расход."""
    base = _to_audit_input(h)
    mortgage = calculate_mortgage_scenario(base)
    cash = calculate_cash_scenario(base)
    deposit = calculate_deposit_scenario(base)

    # Земельная компонента — отдельный рост.
    land_current = h.land_area_sotka * h.land_price_per_sotka
    land_growth = h.land_growth_annual / 100.0
    land_future = land_current * (1.0 + land_growth) ** h.horizon_years

    utilities_total = h.annual_utilities_cost * h.horizon_years

    # Корректируем EI: к активу прибавляем землю, из «плюсов» вычитаем коммуналку.
    # Делаем это симметрично для всех трёх стратегий.
    def _adjust_ei(details, denom: float) -> float:
        numerator_bonus = land_future - land_current - utilities_total
        new_denom = denom
        if new_denom <= 0:
            return 0.0
        # EI'_num = EI*denom + numerator_bonus
        base_num = details.ei * new_denom
        return round((base_num + numerator_bonus) / new_denom, 4)

    mortgage_denom = mortgage.total_payments + mortgage.opportunity_cost_dp
    cash_denom = cash.price_with_discount + cash.opportunity_cost
    deposit_denom = deposit.projected_price + deposit.total_rent_cost

    mortgage = mortgage.model_copy(update={"ei": _adjust_ei(mortgage, mortgage_denom)})
    cash = cash.model_copy(update={"ei": _adjust_ei(cash, cash_denom)})
    deposit = deposit.model_copy(update={"ei": _adjust_ei(deposit, deposit_denom)})

    eis = {"mortgage": mortgage.ei, "cash": cash.ei, "deposit": deposit.ei}
    best = max(eis, key=eis.get)

    return HouseEIDetails(
        mortgage=mortgage,
        cash=cash,
        deposit=deposit,
        land_projected_value=round(land_future, 2),
        total_utilities_cost=round(utilities_total, 2),
        best_strategy=best,
    )
