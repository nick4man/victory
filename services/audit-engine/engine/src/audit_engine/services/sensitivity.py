"""D2 — Sensitivity analysis: как EI меняется от ставки/роста цен.

Чистые функции, без БД. Использует `ei_calculator.calculate_*_scenario`,
перебирая значения `mortgage_rate` и `price_growth_annual`.

API: см. `api/routers/audit.py:audit_sensitivity`.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Iterable

from audit_engine.ei_calculator import (
    calculate_cash_scenario,
    calculate_deposit_scenario,
    calculate_mortgage_scenario,
)
from audit_engine.models import AuditInput


@dataclass(frozen=True)
class SensitivityCell:
    mortgage_rate: float | None
    price_growth: float | None
    ei_cash: float
    ei_mortgage: float
    ei_deposit: float
    best_strategy: str
    is_profitable: bool  # max(EI) ≥ 1.2


def _best(cash: float, mortgage: float, deposit: float) -> tuple[str, float]:
    best = max(cash, mortgage, deposit)
    if best == mortgage:
        return ("mortgage", best)
    if best == cash:
        return ("cash", best)
    return ("deposit", best)


def _compute(input_data: AuditInput) -> SensitivityCell:
    cash = calculate_cash_scenario(input_data).ei
    mortgage = calculate_mortgage_scenario(input_data).ei
    deposit = calculate_deposit_scenario(input_data).ei
    strategy, best_ei = _best(cash, mortgage, deposit)
    return SensitivityCell(
        mortgage_rate=input_data.mortgage_rate,
        price_growth=input_data.price_growth_annual,
        ei_cash=round(cash, 4),
        ei_mortgage=round(mortgage, 4),
        ei_deposit=round(deposit, 4),
        best_strategy=strategy,
        is_profitable=best_ei >= 1.2,
    )


def by_mortgage_rate(
    input_data: AuditInput, rates: Iterable[float]
) -> list[SensitivityCell]:
    """EI для каждой ставки ипотеки, остальное фиксировано."""
    out: list[SensitivityCell] = []
    for rate in rates:
        perturbed = input_data.model_copy(update={"mortgage_rate": float(rate)})
        out.append(_compute(perturbed))
    return out


def by_price_growth(
    input_data: AuditInput, growths: Iterable[float]
) -> list[SensitivityCell]:
    """EI для каждого годового роста цен."""
    out: list[SensitivityCell] = []
    for g in growths:
        perturbed = input_data.model_copy(update={"price_growth_annual": float(g)})
        out.append(_compute(perturbed))
    return out


def grid_2d(
    input_data: AuditInput,
    rates: Iterable[float],
    growths: Iterable[float],
) -> list[list[SensitivityCell]]:
    """Полная 2D сетка ставка × рост (для heatmap)."""
    rates_list = list(rates)
    return [
        [
            _compute(input_data.model_copy(
                update={"mortgage_rate": float(r), "price_growth_annual": float(g)}
            ))
            for r in rates_list
        ]
        for g in growths
    ]


def find_breakeven_rate(
    input_data: AuditInput,
    *,
    threshold: float = 1.0,
    start: float = 3.0,
    end: float = 30.0,
    step: float = 0.25,
) -> float | None:
    """Минимальная mortgage_rate, при которой EI(mortgage) опускается ниже threshold.

    Полезно для рекомендации «брать ипотеку только до X%».
    """
    rate = start
    prev_ei = None
    while rate <= end:
        perturbed = input_data.model_copy(update={"mortgage_rate": rate})
        ei = calculate_mortgage_scenario(perturbed).ei
        if prev_ei is not None and prev_ei >= threshold > ei:
            return round(rate, 2)
        prev_ei = ei
        rate = round(rate + step, 4)
    return None
