"""Тесты DCF Monte-Carlo для BusinessInput."""
from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

from audit_engine.models import BusinessInput
from audit_engine.monte_carlo_business import run_business_mc


def _biz(**overrides) -> BusinessInput:
    base = dict(
        object_name="Кофейня у метро",
        price_total=30_000_000.0,
        annual_revenue=40_000_000.0,
        ebitda=8_000_000.0,       # 20% маржа
        ebitda_margin=20.0,
        revenue_growth_annual=8.0,
        discount_rate=20.0,
        terminal_growth=3.0,
        tax_rate=20.0,
        horizon_years=5,
    )
    base.update(overrides)
    return BusinessInput(**base)


def test_business_mc_returns_valid_summary():
    summary = run_business_mc(_biz(), num_simulations=5_000, seed=42)
    assert summary.num_simulations == 5_000
    assert summary.ei_p5 < summary.ei_p50 < summary.ei_p95
    assert 0.0 <= summary.buy_probability <= 100.0
    assert summary.verdict in ("BUY", "NEUTRAL", "WAIT")


def test_business_mc_monotone_in_revenue_growth():
    """Выше ожидаемый рост выручки → выше медианный EI (при прочих равных)."""
    low = run_business_mc(_biz(revenue_growth_annual=3.0), num_simulations=10_000, seed=1)
    high = run_business_mc(_biz(revenue_growth_annual=15.0), num_simulations=10_000, seed=1)
    assert high.ei_p50 > low.ei_p50


def test_business_mc_monotone_in_discount_rate():
    """Выше ставка дисконтирования → ниже справедливая стоимость → ниже EI."""
    low_r = run_business_mc(_biz(discount_rate=12.0), num_simulations=10_000, seed=2)
    high_r = run_business_mc(_biz(discount_rate=30.0), num_simulations=10_000, seed=2)
    assert low_r.ei_p50 > high_r.ei_p50


def test_business_mc_handles_low_rate_fallback():
    """Если discount_rate ≤ terminal_growth на части сэмплов — не падает,
    использует multiple-fallback. Проверяем, что результат конечен."""
    biz = _biz(discount_rate=5.0, terminal_growth=3.0, multiple_ebitda=5.0)
    summary = run_business_mc(biz, num_simulations=5_000, seed=3)
    import math
    assert math.isfinite(summary.ei_p50)
    assert math.isfinite(summary.ei_mean)


def test_business_mc_reproducible_with_seed():
    a = run_business_mc(_biz(), num_simulations=2_000, seed=777)
    b = run_business_mc(_biz(), num_simulations=2_000, seed=777)
    assert a.ei_mean == b.ei_mean
    assert a.ei_p50 == b.ei_p50
