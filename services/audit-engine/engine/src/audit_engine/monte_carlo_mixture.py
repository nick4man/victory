"""Mixture Monte-Carlo (Phase F).

Вместо одной MVN сэмплируем (price_growth, mortgage_rate, deposit_rate) из
смеси трёх сценариев:
  - bull (веса/μ-shift/σ-multipliers из `settings.mc_scenario_*_bull`)
  - base
  - bear

Каждая симуляция сначала тянет метку сценария из Categorical(weights), затем
из соответствующего MVN. Итоговое распределение EI мультимодальное: это
честнее отражает неопределённость макро-прогноза, чем одна Gauss-MVN.

Опционально — `location_score ∈ [0, 1]`: масштабирует σ для всех компонент
как `σ *= max(0.5, base - slope*score)`, т.е. локации с высоким скором
(метро/школы рядом) оцениваются как менее волатильные.
"""
from __future__ import annotations

from typing import Optional

import numpy as np

from audit_engine.config import settings
from audit_engine.monte_carlo_fast import MonteCarloSimulatorFast


class MonteCarloSimulatorMixture(MonteCarloSimulatorFast):
    """MC-симулятор со смесью bull/base/bear сценариев."""

    def __init__(self, *args, location_score: Optional[float] = None, **kwargs):
        super().__init__(*args, **kwargs)
        self.location_score = location_score

    def _vol_multiplier(self) -> float:
        if self.location_score is None:
            return 1.0
        score = max(0.0, min(1.0, float(self.location_score)))
        mult = settings.mc_location_vol_base - settings.mc_location_vol_slope * score
        return max(0.5, mult)

    def _component_samples(
        self,
        count: int,
        mu_shift: float,
        std_mult: float,
    ) -> np.ndarray:
        """Сэмплы MVN для одной компоненты смеси."""
        if count <= 0:
            return np.empty((0, 3))
        base = self.base_input
        mu = np.array([
            base.price_growth_annual + mu_shift,
            base.mortgage_rate,
            base.deposit_rate,
        ])
        vol = self._vol_multiplier() * std_mult
        stds = np.array([
            settings.mc_price_growth_std * vol,
            settings.mc_mortgage_rate_std * vol,
            settings.mc_deposit_rate_std * vol,
        ])
        rho = float(settings.mc_correlation_mortgage_deposit)
        corr = np.array([
            [1.0, 0.0, 0.0],
            [0.0, 1.0, rho],
            [0.0, rho, 1.0],
        ])
        cov = corr * np.outer(stds, stds)
        return self.rng.multivariate_normal(mu, cov, count)

    def _generate_params_with_correlation(self) -> np.ndarray:
        """Mixture-сэмплинг: Categorical → MVN per component."""
        weights = np.array([
            settings.mc_scenario_weights_bull,
            settings.mc_scenario_weights_base,
            settings.mc_scenario_weights_bear,
        ], dtype=float)
        weights = weights / weights.sum()
        shifts = (
            settings.mc_scenario_mu_shift_bull,
            settings.mc_scenario_mu_shift_base,
            settings.mc_scenario_mu_shift_bear,
        )
        mults = (
            settings.mc_scenario_std_mult_bull,
            settings.mc_scenario_std_mult_base,
            settings.mc_scenario_std_mult_bear,
        )

        labels = self.rng.choice(3, size=self.num_simulations, p=weights)
        samples = np.empty((self.num_simulations, 3))
        for k, (shift, mult) in enumerate(zip(shifts, mults)):
            idx = np.where(labels == k)[0]
            if idx.size == 0:
                continue
            samples[idx] = self._component_samples(idx.size, shift, mult)

        samples[:, 1] = np.clip(samples[:, 1], 1.0, 50.0)
        samples[:, 2] = np.clip(samples[:, 2], 0.5, 50.0)
        return samples
