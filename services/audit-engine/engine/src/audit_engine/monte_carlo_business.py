"""DCF Monte-Carlo для бизнеса (Phase F).

Детерминированный DCF из `ei/business.py` — ядро расчёта; MC-слой сэмплит
три ключевых неопределённых параметра:
  - `revenue_growth_annual`  (N(μ, σ = mc_business_revenue_growth_std))
  - `ebitda_margin`          (N(μ, σ = mc_business_margin_std))
  - `discount_rate`          (N(μ, σ = mc_business_discount_rate_std))

На каждом сэмпле считаем справедливую стоимость через DCF → EI.
Возвращаем `BusinessMCSummary` с p5/p50/p95 и P(EI ≥ 1).

Всё векторизовано по NumPy: 100k симуляций укладываются в единицы ms.
"""
from __future__ import annotations

from typing import Optional

import numpy as np

from audit_engine.config import settings
from audit_engine.models import BusinessInput, BusinessMCSummary


def _verdict(ei_median: float) -> str:
    if ei_median >= settings.ei_buy_threshold:
        return "BUY"
    if ei_median <= settings.ei_reject_threshold:
        return "WAIT"
    return "NEUTRAL"


def run_business_mc(
    inp: BusinessInput,
    num_simulations: int = 100_000,
    seed: Optional[int] = None,
) -> BusinessMCSummary:
    rng = np.random.default_rng(seed)
    n = num_simulations

    g_rev = rng.normal(
        inp.revenue_growth_annual,
        settings.mc_business_revenue_growth_std,
        size=n,
    ) / 100.0
    base_margin = (
        inp.ebitda_margin if inp.ebitda_margin is not None
        else (inp.ebitda / inp.annual_revenue * 100.0)
    )
    margin = np.clip(
        rng.normal(base_margin, settings.mc_business_margin_std, size=n),
        1.0, 99.0,
    ) / 100.0
    r = np.clip(
        rng.normal(inp.discount_rate, settings.mc_business_discount_rate_std, size=n),
        1.0, 60.0,
    ) / 100.0

    tax = inp.tax_rate / 100.0
    g_term = inp.terminal_growth / 100.0
    horizon = inp.horizon_years

    # Project revenue_t = revenue_0 * (1+g)^t; FCF_t = revenue_t * margin * (1-tax)
    # NPV_explicit = Σ FCF_t / (1+r)^t
    # В векторном виде: формируем матрицу (n, horizon).
    years = np.arange(1, horizon + 1)
    # Shape (n, horizon): revenue_0 * (1+g_rev[:,None])**years
    revenue_matrix = inp.annual_revenue * (1.0 + g_rev[:, None]) ** years
    fcf_matrix = revenue_matrix * margin[:, None] * (1.0 - tax)

    discount_factors = (1.0 + r[:, None]) ** years  # (n, horizon)
    npv_explicit = np.sum(fcf_matrix / discount_factors, axis=1)  # (n,)

    last_fcf = fcf_matrix[:, -1]

    # Terminal value. Где r <= g_term — fallback на EV/EBITDA multiple × last ebitda.
    multiple = inp.multiple_ebitda if inp.multiple_ebitda is not None else 5.0
    last_ebitda = last_fcf / (1.0 - tax)

    safe_mask = r > g_term
    tv = np.empty(n)
    tv[safe_mask] = last_fcf[safe_mask] * (1.0 + g_term) / (r[safe_mask] - g_term)
    tv[~safe_mask] = last_ebitda[~safe_mask] * multiple

    tv_discounted = tv / (1.0 + r) ** horizon
    fair_value = npv_explicit + tv_discounted

    ei = fair_value / inp.price_total

    ei_mean = float(np.mean(ei))
    ei_std = float(np.std(ei))
    p5, p50, p95 = (float(x) for x in np.quantile(ei, [0.05, 0.50, 0.95]))
    buy_prob = float(np.mean(ei >= 1.0) * 100.0)

    return BusinessMCSummary(
        num_simulations=n,
        ei_mean=round(ei_mean, 4),
        ei_p5=round(p5, 4),
        ei_p50=round(p50, 4),
        ei_p95=round(p95, 4),
        ei_std=round(ei_std, 4),
        buy_probability=round(buy_prob, 2),
        verdict=_verdict(p50),
    )
