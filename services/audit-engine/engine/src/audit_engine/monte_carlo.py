"""
Monte-Carlo Simulator — Ядро стохастического анализа v2.0.

Вместо 3 детерминированных сценариев запускает N=10000 случайных прогонов
с параметрами из нормального распределения. Оценивает вероятность
целесообразности покупки.

Алгоритм:
1. Для каждой из N итераций:
   a. Сгенерировать случайные параметры (price_growth, mortgage_rate, deposit_rate)
   b. Рассчитать EI для каждой из 3 стратегий
   c. Определить лучшую стратегию
2. Агрегировать: mean, median, p5, p25, p75, p95, std
3. buy_probability = count(EI > threshold) / N
4. Построить гистограмму для фронтенда
"""

from __future__ import annotations
import logging
import numpy as np
from typing import Optional

from audit_engine.models import (
    AuditInput,
    MonteCarloResult,
    MonteCarloSummary,
)
from audit_engine.ei_calculator import (
    calculate_mortgage_scenario,
    calculate_cash_scenario,
    calculate_deposit_scenario,
)
from audit_engine.config import settings

logger = logging.getLogger(__name__)


class MonteCarloSimulator:
    """
    Stochastic EI simulator using Monte-Carlo method.

    Parameters are drawn from truncated normal distributions:
    - price_growth_annual: N(μ=base, σ=mc_price_growth_std)
    - mortgage_rate: N(μ=base, σ=mc_mortgage_rate_std), clipped to [1, 50]
    - deposit_rate: N(μ=base, σ=mc_deposit_rate_std), clipped to [0.5, 50]
    """

    def __init__(
        self,
        base_input: AuditInput,
        num_simulations: int = settings.mc_default_simulations,
        seed: Optional[int] = None,
        ei_threshold: Optional[float] = None,
    ):
        self.base_input = base_input
        self.num_simulations = num_simulations
        self.rng = np.random.default_rng(seed)
        self.ei_threshold = ei_threshold or settings.ei_buy_threshold

    def _generate_params(self) -> np.ndarray:
        """
        Generate N sets of random parameters.

        Returns:
            ndarray of shape (N, 3) — [price_growth, mortgage_rate, deposit_rate]
        """
        n = self.num_simulations
        base = self.base_input

        price_growth = self.rng.normal(
            base.price_growth_annual, settings.mc_price_growth_std, n
        )
        mortgage_rate = np.clip(
            self.rng.normal(base.mortgage_rate, settings.mc_mortgage_rate_std, n),
            1.0, 50.0,
        )
        deposit_rate = np.clip(
            self.rng.normal(base.deposit_rate, settings.mc_deposit_rate_std, n),
            0.5, 50.0,
        )

        return np.column_stack([price_growth, mortgage_rate, deposit_rate])

    def _run_single(
        self, price_growth: float, mortgage_rate: float, deposit_rate: float
    ) -> dict:
        """Run EI calculation for one set of parameters."""
        modified = self.base_input.model_copy(update={
            "price_growth_annual": float(price_growth),
            "mortgage_rate": float(mortgage_rate),
            "deposit_rate": float(deposit_rate),
        })
        try:
            m = calculate_mortgage_scenario(modified)
            c = calculate_cash_scenario(modified)
            d = calculate_deposit_scenario(modified)
            return {"cash": c.ei, "mortgage": m.ei, "deposit": d.ei}
        except (ZeroDivisionError, ValueError, ArithmeticError) as exc:
            logger.warning(
                "MC iter failed (params: price_growth=%.3f, mortgage=%.3f, deposit=%.3f): %s",
                price_growth, mortgage_rate, deposit_rate, exc,
            )
            return {"cash": 0.0, "mortgage": 0.0, "deposit": 0.0, "failed": True}

    def run(self) -> MonteCarloSummary:
        """
        Execute full Monte-Carlo simulation.

        Returns:
            MonteCarloSummary with results for all 3 strategies.
        """
        params = self._generate_params()

        # Vectorized would be ideal, but EI formulas have conditionals
        # Use list comprehension for clarity
        results = [
            self._run_single(p[0], p[1], p[2]) for p in params
        ]

        failures = sum(1 for r in results if r.get("failed"))
        if failures / max(len(results), 1) > 0.01:
            logger.error(
                "MC failure rate %.2f%% exceeds 1%% threshold (%d/%d iters failed) — "
                "input likely pathological (division-by-zero in EI formulas)",
                failures / len(results) * 100, failures, len(results),
            )

        # Separate by strategy
        cash_eis = np.array([r["cash"] for r in results])
        mortgage_eis = np.array([r["mortgage"] for r in results])
        deposit_eis = np.array([r["deposit"] for r in results])

        mc_cash = self._aggregate("cash", cash_eis)
        mc_mortgage = self._aggregate("mortgage", mortgage_eis)
        mc_deposit = self._aggregate("deposit", deposit_eis)

        # Determine recommended strategy
        means = {
            "cash": mc_cash.ei_mean,
            "mortgage": mc_mortgage.ei_mean,
            "deposit": mc_deposit.ei_mean,
        }
        recommended = max(means, key=means.get)

        # Confidence level based on buy probability of best strategy
        best_prob = max(mc_cash.buy_probability, mc_mortgage.buy_probability, mc_deposit.buy_probability)
        if best_prob >= 70:
            confidence = "high"
        elif best_prob >= 40:
            confidence = "medium"
        else:
            confidence = "low"

        return MonteCarloSummary(
            cash=mc_cash,
            mortgage=mc_mortgage,
            deposit=mc_deposit,
            recommended_strategy=recommended,
            confidence_level=confidence,
        )

    def _aggregate(self, strategy: str, eis: np.ndarray) -> MonteCarloResult:
        """Aggregate EI array into MonteCarloResult."""
        # Filter out zeros (failed calculations)
        valid = eis[eis > 0]
        if len(valid) == 0:
            valid = eis  # fallback

        buy_count = np.sum(valid >= self.ei_threshold)
        buy_prob = float(buy_count / len(valid) * 100)

        # Single pass: compute all percentiles at once
        p1, p5, p25, p50, p75, p95, p99 = np.quantile(
            valid, [0.01, 0.05, 0.25, 0.50, 0.75, 0.95, 0.99]
        )

        # Build histogram (30 bins)
        hist, bin_edges = np.histogram(valid, bins=30)
        distribution_data = {
            "counts": hist.tolist(),
            "bin_edges": [round(float(e), 4) for e in bin_edges],
            "bin_centers": [
                round(float((bin_edges[i] + bin_edges[i + 1]) / 2), 4)
                for i in range(len(hist))
            ],
        }

        return MonteCarloResult(
            num_simulations=self.num_simulations,
            strategy=strategy,
            ei_mean=round(float(np.mean(valid)), 4),
            ei_median=round(float(p50), 4),
            ei_p1=round(float(p1), 4),
            ei_p5=round(float(p5), 4),
            ei_p25=round(float(p25), 4),
            ei_p75=round(float(p75), 4),
            ei_p95=round(float(p95), 4),
            ei_p99=round(float(p99), 4),
            ei_std=round(float(np.std(valid)), 4),
            buy_probability=round(buy_prob, 2),
            distribution_data=distribution_data,
        )


def run_monte_carlo(
    input_data: AuditInput,
    num_simulations: int = settings.mc_default_simulations,
    seed: int | None = None,
) -> MonteCarloSummary:
    """
    Convenience function to run Monte-Carlo simulation.

    Args:
        input_data: Base audit parameters.
        num_simulations: Number of random trials (default 10000).
        seed: Random seed for reproducibility (None = random).

    Returns:
        MonteCarloSummary with results for all strategies.
    """
    sim = MonteCarloSimulator(input_data, num_simulations, seed)
    return sim.run()
