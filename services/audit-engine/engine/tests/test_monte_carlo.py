"""Tests for Monte-Carlo Simulator."""

import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

from audit_engine.models import AuditInput
from audit_engine.monte_carlo import MonteCarloSimulator, run_monte_carlo


def make_test_input() -> AuditInput:
    """Create a standard test input."""
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


def test_monte_carlo_basic():
    """MC should return valid results with fixed seed."""
    inp = make_test_input()
    sim = MonteCarloSimulator(inp, num_simulations=1000, seed=42)
    result = sim.run()

    # Check all strategies present
    assert result.cash is not None
    assert result.mortgage is not None
    assert result.deposit is not None

    # Check recommended strategy is one of the three
    assert result.recommended_strategy in ("cash", "mortgage", "deposit")

    # Check confidence level
    assert result.confidence_level in ("high", "medium", "low")


def test_monte_carlo_statistics():
    """MC statistics should be in reasonable ranges."""
    inp = make_test_input()
    result = run_monte_carlo(inp, num_simulations=1000, seed=42)

    for strategy in [result.cash, result.mortgage, result.deposit]:
        # Mean should be positive
        assert strategy.ei_mean > 0, f"EI mean should be positive, got {strategy.ei_mean}"

        # Percentile ordering
        assert strategy.ei_p5 <= strategy.ei_p25 <= strategy.ei_median <= strategy.ei_p75 <= strategy.ei_p95, \
            f"Percentiles should be ordered: p5={strategy.ei_p5} p25={strategy.ei_p25} " \
            f"median={strategy.ei_median} p75={strategy.ei_p75} p95={strategy.ei_p95}"

        # Std should be positive
        assert strategy.ei_std > 0, f"Std should be positive, got {strategy.ei_std}"

        # Buy probability should be 0-100
        assert 0 <= strategy.buy_probability <= 100

        # Distribution data should have correct structure
        assert "counts" in strategy.distribution_data
        assert "bin_edges" in strategy.distribution_data
        assert "bin_centers" in strategy.distribution_data
        assert len(strategy.distribution_data["counts"]) == 30
        assert len(strategy.distribution_data["bin_edges"]) == 31


def test_monte_carlo_reproducibility():
    """Same seed should produce same results."""
    inp = make_test_input()
    r1 = run_monte_carlo(inp, num_simulations=500, seed=123)
    r2 = run_monte_carlo(inp, num_simulations=500, seed=123)

    assert r1.cash.ei_mean == r2.cash.ei_mean
    assert r1.mortgage.ei_mean == r2.mortgage.ei_mean
    assert r1.deposit.ei_mean == r2.deposit.ei_mean
    assert r1.recommended_strategy == r2.recommended_strategy


def test_monte_carlo_num_simulations():
    """Number of simulations should be reflected in result."""
    inp = make_test_input()
    result = run_monte_carlo(inp, num_simulations=500, seed=42)
    assert result.cash.num_simulations == 500


if __name__ == "__main__":
    test_monte_carlo_basic()
    print("✅ test_monte_carlo_basic passed")

    test_monte_carlo_statistics()
    print("✅ test_monte_carlo_statistics passed")

    test_monte_carlo_reproducibility()
    print("✅ test_monte_carlo_reproducibility passed")

    test_monte_carlo_num_simulations()
    print("✅ test_monte_carlo_num_simulations passed")

    print("\n🎉 All Monte-Carlo tests passed!")
