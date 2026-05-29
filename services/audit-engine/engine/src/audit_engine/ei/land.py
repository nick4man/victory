"""EI для земельного участка.

Нет ренты, нет ипотеки (в базовой модели — физлицо покупает за свои).
Считаем прямое сравнение «вложить в землю vs в депозит»:

    EI = projected_price / (price_total + opportunity_cost_deposit + total_tax)

Интерпретация:
* EI > 1 → земля обогнала депозит после учёта налогов → есть смысл покупать.
* EI ≈ 1 → паритет; решение по нефинансовым факторам.
* EI < 1 → депозит выгоднее; WAIT.
"""
from __future__ import annotations

from audit_engine.models import LandEIDetails, LandInput


def calculate_land_ei(inp: LandInput) -> LandEIDetails:
    growth = inp.price_growth_annual / 100.0
    projected_price = inp.price_total * (1.0 + growth) ** inp.horizon_years

    # Депозит с ежемесячной капитализацией (консистентно с apartment/deposit)
    monthly_dr = inp.deposit_rate / 100.0 / 12.0
    n_months = inp.horizon_years * 12
    fv_deposit = inp.price_total * (1.0 + monthly_dr) ** n_months
    opportunity_cost = fv_deposit - inp.price_total

    # Налоги и обслуживание — линейно по годам (без индексации).
    total_tax = (inp.annual_tax + inp.annual_maintenance) * inp.horizon_years

    denominator = inp.price_total + opportunity_cost + total_tax
    ei = round(projected_price / denominator, 4) if denominator > 0 else 0.0

    return LandEIDetails(
        projected_price=round(projected_price, 2),
        opportunity_cost_deposit=round(opportunity_cost, 2),
        total_tax_and_maintenance=round(total_tax, 2),
        ei=ei,
    )
