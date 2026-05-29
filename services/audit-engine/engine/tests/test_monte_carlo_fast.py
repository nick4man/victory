"""Tests for vectorized Monte-Carlo simulator (`MonteCarloSimulatorFast`)."""
from __future__ import annotations

import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

import numpy as np
import pytest

from audit_engine.config import settings
from audit_engine.models import AuditInput
from audit_engine.monte_carlo import MonteCarloSimulator
from audit_engine.monte_carlo_fast import MonteCarloSimulatorFast


def make_test_input() -> AuditInput:
    return AuditInput(
        complex_name="Тестовый ЖК",
        apartment_type="2BR",
        area_sqm=65.0,
        price_total=12_000_000,
        monthly_rent=45_000,
        mortgage_rate=17.0,
        mortgage_term_years=20,
        down_payment_pct=20.0,
        deposit_rate=14.0,
        price_growth_annual=7.9,
        horizon_years=5,
        cash_discount_pct=10.0,
    )


def test_fast_basic():
    """Fast MC возвращает валидный summary со всеми стратегиями."""
    sim = MonteCarloSimulatorFast(make_test_input(), num_simulations=1000, seed=42)
    result = sim.run_vectorized()

    assert result.cash is not None
    assert result.mortgage is not None
    assert result.deposit is not None
    assert result.recommended_strategy in ("cash", "mortgage", "deposit")
    assert result.confidence_level in ("high", "medium", "low")


def test_fast_reproducibility():
    """Один seed -> одинаковые результаты."""
    inp = make_test_input()
    r1 = MonteCarloSimulatorFast(inp, num_simulations=500, seed=7).run_vectorized()
    r2 = MonteCarloSimulatorFast(inp, num_simulations=500, seed=7).run_vectorized()

    assert r1.cash.ei_mean == r2.cash.ei_mean
    assert r1.mortgage.ei_mean == r2.mortgage.ei_mean
    assert r1.deposit.ei_mean == r2.deposit.ei_mean


def test_fast_statistics_ordering():
    """Перцентили упорядочены."""
    sim = MonteCarloSimulatorFast(make_test_input(), num_simulations=2000, seed=42)
    result = sim.run_vectorized()

    for strategy in (result.cash, result.mortgage, result.deposit):
        assert strategy.ei_p5 <= strategy.ei_p25 <= strategy.ei_median
        assert strategy.ei_median <= strategy.ei_p75 <= strategy.ei_p95
        assert strategy.ei_std >= 0
        assert 0 <= strategy.buy_probability <= 100


def test_fast_matches_reference_within_tolerance():
    """Fast-версия близка к референсной (разные RNG-пути: univariate vs multivariate,
    поэтому сверяем направление вердикта и статистики в пределах допуска 15%).
    """
    inp = make_test_input()
    slow = MonteCarloSimulator(inp, num_simulations=2000, seed=42).run()
    fast = MonteCarloSimulatorFast(inp, num_simulations=2000, seed=42).run_vectorized()

    # Рекомендация совпадает
    assert slow.recommended_strategy == fast.recommended_strategy

    # EI mean по каждой стратегии отличается не более чем на 15%
    for name in ("cash", "mortgage", "deposit"):
        s = getattr(slow, name).ei_mean
        f = getattr(fast, name).ei_mean
        assert s > 0 and f > 0
        rel_diff = abs(s - f) / max(s, f)
        assert rel_diff < 0.15, (
            f"{name}: slow={s:.4f} vs fast={f:.4f} (diff={rel_diff:.1%})"
        )


def test_fast_speedup():
    """Fast-версия должна быть заметно быстрее референсной при N=2000."""
    inp = make_test_input()
    n = 2000

    t0 = time.perf_counter()
    MonteCarloSimulator(inp, num_simulations=n, seed=42).run()
    slow_time = time.perf_counter() - t0

    t0 = time.perf_counter()
    MonteCarloSimulatorFast(inp, num_simulations=n, seed=42).run_vectorized()
    fast_time = time.perf_counter() - t0

    # Порог умеренный — на слабой CI 10x тоже приемлемо
    assert fast_time * 5 < slow_time, (
        f"Expected >=5x speedup, got slow={slow_time:.3f}s fast={fast_time:.3f}s"
    )


def test_correlation_applied():
    """Mortgage и deposit скоррелированы (ρ≈0.85) в генераторе параметров."""
    sim = MonteCarloSimulatorFast(make_test_input(), num_simulations=5000, seed=42)
    params = sim._generate_params_with_correlation()
    # Колонки: [price_growth, mortgage_rate, deposit_rate]
    corr = np.corrcoef(params[:, 1], params[:, 2])[0, 1]
    assert 0.70 <= corr <= 0.95, f"Expected ~0.85 correlation, got {corr:.3f}"


def test_run_override_uses_vectorized():
    """Метод run() на Fast-классе должен быть эквивалентен run_vectorized()."""
    inp = make_test_input()
    r1 = MonteCarloSimulatorFast(inp, num_simulations=500, seed=99).run()
    r2 = MonteCarloSimulatorFast(inp, num_simulations=500, seed=99).run_vectorized()
    assert r1.cash.ei_mean == r2.cash.ei_mean
    assert r1.mortgage.ei_mean == r2.mortgage.ei_mean
    assert r1.deposit.ei_mean == r2.deposit.ei_mean


def test_correlation_is_configurable():
    """ρ между mortgage и deposit читается из settings, а не зашит литералом."""
    original = settings.mc_correlation_mortgage_deposit
    try:
        settings.mc_correlation_mortgage_deposit = 0.5
        sim = MonteCarloSimulatorFast(
            make_test_input(), num_simulations=10_000, seed=123,
        )
        params = sim._generate_params_with_correlation()
        r = np.corrcoef(params[:, 1], params[:, 2])[0, 1]
        assert 0.40 <= r <= 0.60, f"expected ρ≈0.5, got {r:.3f}"
    finally:
        settings.mc_correlation_mortgage_deposit = original


def test_result_includes_tail_percentiles():
    """p1 и p99 заполнены одним вызовом np.quantile."""
    sim = MonteCarloSimulatorFast(
        make_test_input(), num_simulations=5000, seed=42,
    )
    result = sim.run_vectorized()
    for strategy in (result.cash, result.mortgage, result.deposit):
        assert strategy.ei_p1 <= strategy.ei_p5 <= strategy.ei_p25
        assert strategy.ei_p75 <= strategy.ei_p95 <= strategy.ei_p99


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
