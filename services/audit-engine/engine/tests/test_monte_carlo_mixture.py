"""Тесты `MonteCarloSimulatorMixture` — смесь bull/base/bear сценариев."""
from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

import numpy as np

from audit_engine.config import settings
from audit_engine.models import AuditInput
from audit_engine.monte_carlo_fast import MonteCarloSimulatorFast
from audit_engine.monte_carlo_mixture import MonteCarloSimulatorMixture


def _inp() -> AuditInput:
    return AuditInput(
        complex_name="ЖК Тест",
        apartment_type="2BR",
        area_sqm=65.0,
        price_total=12_000_000,
        monthly_rent=45_000,
        mortgage_rate=17.0,
        deposit_rate=14.0,
        price_growth_annual=7.9,
        horizon_years=5,
    )


def test_mixture_basic_runs_and_returns_summary():
    sim = MonteCarloSimulatorMixture(_inp(), num_simulations=2000, seed=42)
    result = sim.run_vectorized()
    assert result.cash is not None
    assert result.mortgage is not None
    assert result.deposit is not None
    assert 0.0 < result.mortgage.ei_mean < 5.0


def test_mixture_mean_matches_weighted_scenario_mean():
    """Средний price_growth из сэмплов ≈ Σ w_k · (μ + shift_k).

    На 50k симуляциях отклонение < 0.2 п.п.
    """
    base = _inp()
    sim = MonteCarloSimulatorMixture(base, num_simulations=50_000, seed=123)
    samples = sim._generate_params_with_correlation()
    growth_samples = samples[:, 0]

    expected = (
        settings.mc_scenario_weights_bull * (base.price_growth_annual + settings.mc_scenario_mu_shift_bull)
        + settings.mc_scenario_weights_base * (base.price_growth_annual + settings.mc_scenario_mu_shift_base)
        + settings.mc_scenario_weights_bear * (base.price_growth_annual + settings.mc_scenario_mu_shift_bear)
    )
    weight_sum = (
        settings.mc_scenario_weights_bull
        + settings.mc_scenario_weights_base
        + settings.mc_scenario_weights_bear
    )
    expected /= weight_sum

    empirical = float(np.mean(growth_samples))
    assert abs(empirical - expected) < 0.2


def test_mixture_has_heavier_tails_than_plain_fast():
    """Mixture → std по price_growth больше, чем у плоского fast — потому что
    bull/bear сдвигают моду и bear имеет увеличенный σ.
    """
    base = _inp()
    fast = MonteCarloSimulatorFast(base, num_simulations=20_000, seed=7)
    mix = MonteCarloSimulatorMixture(base, num_simulations=20_000, seed=7)

    fast_samples = fast._generate_params_with_correlation()[:, 0]
    mix_samples = mix._generate_params_with_correlation()[:, 0]

    assert np.std(mix_samples) > np.std(fast_samples)


def test_mixture_location_score_reduces_volatility():
    """Высокий location_score → σ меньше (связка фазы D и F)."""
    base = _inp()
    low_score = MonteCarloSimulatorMixture(
        base, num_simulations=20_000, seed=11, location_score=0.0,
    )
    high_score = MonteCarloSimulatorMixture(
        base, num_simulations=20_000, seed=11, location_score=1.0,
    )

    low_samples = low_score._generate_params_with_correlation()[:, 0]
    high_samples = high_score._generate_params_with_correlation()[:, 0]

    assert np.std(high_samples) < np.std(low_samples)
