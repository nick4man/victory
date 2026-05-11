"""Vectorized Monte-Carlo simulator.

Uses NumPy broadcasting to run all N simulations as matrix ops instead of
a Python loop. Correlation (ρ) and σ values come from settings, not literals.
"""
from __future__ import annotations

import numpy as np

from audit_engine.config import settings
from audit_engine.models import MonteCarloSummary
from audit_engine.monte_carlo import MonteCarloSimulator


def _pmt_vec(principal: float, rate_monthly: np.ndarray, n_months: int) -> np.ndarray:
    """Vectorized PMT (monthly annuity payment).

    principal: scalar loan amount.
    rate_monthly: array of monthly rates (not %).
    n_months: integer term.
    """
    pow_r = (1.0 + rate_monthly) ** n_months
    return principal * (rate_monthly * pow_r) / (pow_r - 1.0)


def _confidence_level(best_prob: float) -> str:
    if best_prob >= 70:
        return "high"
    if best_prob >= 40:
        return "medium"
    return "low"


class MonteCarloSimulatorFast(MonteCarloSimulator):
    """Vectorized Stochastic EI simulator (numpy broadcasting).

    Inherits `__init__`, `_aggregate`, and `_generate_params` from the reference
    `MonteCarloSimulator` so all settings (seed, ei_threshold, num_simulations)
    behave identically. The only two overrides here are:

    * `_generate_params_with_correlation` — MVN sampler with ρ(mortgage, deposit)
      read from `settings.mc_correlation_mortgage_deposit`.
    * `run_vectorized` / `run` — same math as reference but applied to numpy
      arrays in one pass.
    """

    def _generate_params_with_correlation(self) -> np.ndarray:
        """Sample (price_growth, mortgage_rate, deposit_rate) with correlation."""
        base = self.base_input
        mu = np.array([
            base.price_growth_annual,
            base.mortgage_rate,
            base.deposit_rate,
        ])
        stds = np.array([
            settings.mc_price_growth_std,
            settings.mc_mortgage_rate_std,
            settings.mc_deposit_rate_std,
        ])
        rho = float(settings.mc_correlation_mortgage_deposit)
        corr = np.array([
            [1.0, 0.0, 0.0],
            [0.0, 1.0, rho],
            [0.0, rho, 1.0],
        ])
        cov = corr * np.outer(stds, stds)
        params = self.rng.multivariate_normal(mu, cov, self.num_simulations)
        # Clip to non-physical regime
        params[:, 1] = np.clip(params[:, 1], 1.0, 50.0)
        params[:, 2] = np.clip(params[:, 2], 0.5, 50.0)
        return params

    def run_vectorized(self) -> MonteCarloSummary:
        """Run all N simulations via broadcasting."""
        params = self._generate_params_with_correlation()
        price_growth = params[:, 0]
        mortgage_rate = params[:, 1]
        deposit_rate = params[:, 2]

        inp = self.base_input
        price = inp.price_total
        rent = inp.monthly_rent
        horizon = inp.horizon_years
        cash_discount = inp.cash_discount_pct / 100.0
        dp_pct = inp.down_payment_pct / 100.0

        # Shared: projected asset value and rent savings (both constant vs. strategy
        # once price_growth is drawn).
        projected_value = price * (1.0 + price_growth / 100.0) ** horizon
        rent_savings = rent * 12 * horizon

        # Deposit compounding over horizon (vector over deposit_rate)
        d_rate_monthly = deposit_rate / 12.0 / 100.0
        pow_d_h = (1.0 + d_rate_monthly) ** (horizon * 12)

        # --- Mortgage ---
        dp = price * dp_pct
        loan = price - dp
        m_rate_monthly = mortgage_rate / 12.0 / 100.0
        m_terms = inp.mortgage_term_years * 12
        monthly_payment = _pmt_vec(loan, m_rate_monthly, m_terms)
        total_payments = monthly_payment * m_terms
        opp_cost_dp = dp * pow_d_h - dp
        mortgage_eis = (projected_value + rent_savings) / (total_payments + opp_cost_dp)

        # --- Cash ---
        price_cash = price * (1.0 - cash_discount)
        opp_cost_cash = price_cash * pow_d_h - price_cash
        cash_eis = (projected_value + rent_savings) / (price_cash + opp_cost_cash)

        # --- Deposit-and-wait ---
        capital_after_horizon = price_cash * pow_d_h
        total_rent_cost = rent * 12 * horizon
        deposit_eis = capital_after_horizon / (projected_value + total_rent_cost)

        mc_cash = self._aggregate("cash", cash_eis)
        mc_mortgage = self._aggregate("mortgage", mortgage_eis)
        mc_deposit = self._aggregate("deposit", deposit_eis)

        means = {
            "cash": mc_cash.ei_mean,
            "mortgage": mc_mortgage.ei_mean,
            "deposit": mc_deposit.ei_mean,
        }
        recommended = max(means, key=means.get)
        best_prob = max(
            mc_cash.buy_probability,
            mc_mortgage.buy_probability,
            mc_deposit.buy_probability,
        )

        return MonteCarloSummary(
            cash=mc_cash,
            mortgage=mc_mortgage,
            deposit=mc_deposit,
            recommended_strategy=recommended,
            confidence_level=_confidence_level(best_prob),
        )

    def run(self) -> MonteCarloSummary:
        return self.run_vectorized()

    def run_for_offer(
        self, mortgage_rate: float, term_years: int | None = None
    ) -> MonteCarloSummary:
        """MC-прогон, где базовая ипотечная ставка подменена на ставку оффера.

        `term_years` — опциональная подмена срока; если оффер не задаёт
        ограничения — остаётся `base_input.mortgage_term_years`. Параметр
        `mortgage_rate_std` из settings сохраняется — оффер задаёт только
        центр распределения.
        """
        updates: dict[str, float | int] = {"mortgage_rate": float(mortgage_rate)}
        if term_years is not None:
            updates["mortgage_term_years"] = int(term_years)
        original = self.base_input
        self.base_input = original.model_copy(update=updates)
        try:
            return self.run_vectorized()
        finally:
            self.base_input = original
