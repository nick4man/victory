"""EI для бизнеса через DCF (discounted cash flow).

Стандартный двухфазный DCF:
1. Explicit period (horizon_years): FCF_t = EBITDA_t × (1 - tax_rate) — грубо,
   без учёта CAPEX / изменения OBC (упрощение для MVP).
2. Terminal value по Гордону: TV = FCF_N × (1 + g_term) / (r - g_term).

FCF дисконтируется по `discount_rate`. EI = NPV / price_total.

Интерпретация:
* EI > 1 → бизнес недооценён → BUY.
* EI < 1 → переплата → WAIT.
* EI ~ 1 → справедливая цена.
"""
from __future__ import annotations
from typing import Optional

from audit_engine.models import BusinessEIDetails, BusinessInput


def _compute_dcf(inp: BusinessInput):
    """Вычисляет основные компоненты DCF, возвращает словарь с результатами."""
    r = inp.discount_rate / 100.0
    g_rev = inp.revenue_growth_annual / 100.0
    g_term = inp.terminal_growth / 100.0
    tax = inp.tax_rate / 100.0
    capex_pct = inp.capex_pct_of_revenue / 100.0
    wc_pct = inp.working_capital_change_pct_of_revenue / 100.0

    margin = (
        inp.ebitda_margin / 100.0 if inp.ebitda_margin is not None
        else (inp.ebitda / inp.annual_revenue)
    )

    fcfs: list[float] = []
    revenue = inp.annual_revenue
    for _year in range(1, inp.horizon_years + 1):
        revenue = revenue * (1.0 + g_rev)
        ebitda = revenue * margin
        fcf = ebitda * (1.0 - tax) - revenue * capex_pct - revenue * wc_pct
        fcfs.append(fcf)

    npv_explicit = sum(
        fcf / (1.0 + r) ** t for t, fcf in enumerate(fcfs, start=1)
    )

    terminal_method = "gordon"
    if r > g_term and fcfs:
        terminal = fcfs[-1] * (1.0 + g_term) / (r - g_term)
        terminal_discounted = terminal / (1.0 + r) ** inp.horizon_years
        terminal_growth_used = g_term
    else:
        multiple = inp.multiple_ebitda if inp.multiple_ebitda is not None else 5.0
        last_ebitda = fcfs[-1] / (1.0 - tax) if fcfs else inp.ebitda
        terminal = last_ebitda * multiple
        terminal_discounted = terminal / (1.0 + r) ** inp.horizon_years
        terminal_growth_used = 0.0
        terminal_method = "multiple"

    fair_value = npv_explicit + terminal_discounted
    ei = round(fair_value / inp.price_total, 4) if inp.price_total > 0 else 0.0

    return {
        "fair_value": fair_value,
        "fcfs": fcfs,
        "terminal_discounted": terminal_discounted,
        "npv_explicit": npv_explicit,
        "terminal_growth_used": terminal_growth_used,
        "terminal_method": terminal_method,
        "ei": ei,
    }


def calculate_sensitivity(inp: BusinessInput, base_ei: float) -> dict:
    """Анализ чувствительности EI к изменениям ключевых параметров.

    Варьирует revenue_growth_annual, discount_rate, terminal_growth
    на ±10% и ±20% от базовых значений.
    Возвращает словарь с изменениями EI для каждого параметра.
    """
    variations = [-20, -10, 10, 20]  # в процентах от базового значения
    result = {
        "revenue_growth": [],
        "discount_rate": [],
        "terminal_growth": [],
    }

    # Для каждого параметра создаём изменённую копию входных данных
    for param, key in [
        ("revenue_growth", "revenue_growth_annual"),
        ("discount_rate", "discount_rate"),
        ("terminal_growth", "terminal_growth"),
    ]:
        for delta_pct in variations:
            data = inp.model_dump()
            base_val = data[key]
            new_val = base_val * (1 + delta_pct / 100.0)
            data[key] = new_val
            modified = BusinessInput(**data)
            dcf_result = _compute_dcf(modified)
            ei_new = dcf_result["ei"]
            result[param].append({
                "change_pct": delta_pct,
                "value": new_val,
                "ei": ei_new,
                "delta_vs_base": ei_new - base_ei,
            })
    return result


def calculate_business_ei(inp: BusinessInput) -> BusinessEIDetails:
    """Расчёт EI для бизнеса через улучшенный DCF."""
    dcf = _compute_dcf(inp)
    sensitivity = calculate_sensitivity(inp, dcf["ei"])

    return BusinessEIDetails(
        fair_value_dcf=round(dcf["fair_value"], 2),
        fcf_per_year=[round(x, 2) for x in dcf["fcfs"]],
        terminal_value=round(dcf["terminal_discounted"], 2),
        discount_rate=inp.discount_rate,
        ei=dcf["ei"],
        npv_explicit=round(dcf["npv_explicit"], 2),
        terminal_growth_used=round(dcf["terminal_growth_used"] * 100, 2),
        terminal_method=dcf["terminal_method"],
        sensitivity=sensitivity,
    )
