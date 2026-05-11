"""Тесты для orchestrator-а `multi_offer_mc.run_monte_carlo_all_offers`.

БД мокается (подменяем `list_active_offers`), симулятор тоже —
проверяем что orchestrator правильно фильтрует, параллельно запускает
и выбирает лучший оффер по `ei_mortgage_median`.
"""
from __future__ import annotations

import asyncio
import os
import sys
from datetime import date

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

import pytest

from audit_engine.models import (
    AuditInput,
    BankOffer,
    BankProductType,
    MonteCarloResult,
    MonteCarloSummary,
)


def _audit_input() -> AuditInput:
    return AuditInput(
        complex_name="ЖК Тест",
        apartment_type="2BR",
        area_sqm=60.0,
        price_total=10_000_000,
        monthly_rent=45_000,
        mortgage_rate=17.0,
        mortgage_term_years=20,
        down_payment_pct=20.0,
        deposit_rate=14.0,
        price_growth_annual=7.9,
        horizon_years=5,
    )


def _offer(bank: str, rate: float, *, product=BankProductType.MORTGAGE) -> BankOffer:
    return BankOffer(
        id=f"00000000-0000-0000-0000-{bank:>012}",
        bank_name=bank,
        product_type=product,
        product_name="Ипотека",
        rate_min=rate,
        rate_max=rate + 2.0,
        term_years_min=1,
        term_years_max=30,
        down_payment_min_pct=15.0,
        max_loan_amount=100_000_000,
        requirements={},
        valid_from=date(2026, 1, 1),
    )


def _fake_mc(ei_median: float, ei_mean: float | None = None) -> MonteCarloSummary:
    """Детерминированный MC-Summary с заданным mortgage EI (для теста выбора)."""
    em = ei_mean if ei_mean is not None else ei_median
    return MonteCarloSummary(
        cash=MonteCarloResult(
            num_simulations=10,
            strategy="cash",
            ei_mean=1.0,
            ei_median=1.0,
            ei_p5=0.9,
            ei_p25=0.95,
            ei_p75=1.05,
            ei_p95=1.1,
            ei_std=0.05,
            buy_probability=50.0,
            distribution_data={},
        ),
        mortgage=MonteCarloResult(
            num_simulations=10,
            strategy="mortgage",
            ei_mean=em,
            ei_median=ei_median,
            ei_p5=ei_median - 0.1,
            ei_p25=ei_median - 0.05,
            ei_p75=ei_median + 0.05,
            ei_p95=ei_median + 0.1,
            ei_std=0.05,
            buy_probability=60.0,
            distribution_data={},
        ),
        deposit=MonteCarloResult(
            num_simulations=10,
            strategy="deposit",
            ei_mean=1.0,
            ei_median=1.0,
            ei_p5=0.9,
            ei_p25=0.95,
            ei_p75=1.05,
            ei_p95=1.1,
            ei_std=0.05,
            buy_probability=50.0,
            distribution_data={},
        ),
        recommended_strategy="mortgage",
        confidence_level="medium",
    )


@pytest.mark.anyio
async def test_runs_mc_for_each_eligible_offer(monkeypatch):
    from audit_engine import multi_offer_mc

    offers = [
        _offer("A", 17.0),
        _offer("B", 18.0),
        _offer("C", 19.0),
    ]

    async def _fake_list(db, product_type=None, today=None):
        return offers
    monkeypatch.setattr(multi_offer_mc, "list_active_offers", _fake_list)

    # Каждому оффферу — свой ei_median (чем ниже ставка, тем выше EI).
    ei_by_rate = {17.0: 1.25, 18.0: 1.15, 19.0: 1.05}

    class _FakeSim:
        def __init__(self, base_input, num_simulations, seed=None):
            self.base_input = base_input

        def run_for_offer(self, mortgage_rate, term_years=None):
            # rate = середина [rate_min, rate_max] = rate_min + 1.0
            # значит ключ в ei_by_rate — rate - 1.0
            key = round(mortgage_rate - 1.0, 2)
            return _fake_mc(ei_by_rate[key])

    monkeypatch.setattr(multi_offer_mc, "MonteCarloSimulatorFast", _FakeSim)

    result = await multi_offer_mc.run_monte_carlo_all_offers(
        db=None,
        audit_input=_audit_input(),
        audit_id="11111111-1111-1111-1111-111111111111",
        num_simulations=100,
        seed=42,
    )
    assert result.num_offers == 3
    assert len(result.per_offer) == 3
    banks = {po.offer.bank_name for po in result.per_offer}
    assert banks == {"A", "B", "C"}


@pytest.mark.anyio
async def test_recommends_highest_median_ei(monkeypatch):
    from audit_engine import multi_offer_mc

    offers = [
        _offer("A", 17.0),
        _offer("B", 18.0),
        _offer("C", 19.0),
    ]

    async def _fake_list(db, product_type=None, today=None):
        return offers
    monkeypatch.setattr(multi_offer_mc, "list_active_offers", _fake_list)

    # «C» (19%) даёт лучший EI — проверяем, что rate не единственный критерий.
    ei_by_rate = {17.0: 1.05, 18.0: 1.15, 19.0: 1.30}

    class _FakeSim:
        def __init__(self, base_input, num_simulations, seed=None):
            pass

        def run_for_offer(self, mortgage_rate, term_years=None):
            key = round(mortgage_rate - 1.0, 2)
            return _fake_mc(ei_by_rate[key])

    monkeypatch.setattr(multi_offer_mc, "MonteCarloSimulatorFast", _FakeSim)

    result = await multi_offer_mc.run_monte_carlo_all_offers(
        db=None,
        audit_input=_audit_input(),
        num_simulations=100,
    )
    assert result.recommended_bank == "C"


@pytest.mark.anyio
async def test_counts_skipped_ineligible(monkeypatch):
    from audit_engine import multi_offer_mc

    inp = _audit_input()
    # Первый — слишком жёсткий ПВ, второй — слишком короткий срок
    bad1 = _offer("Bad1", 17.0)
    bad1 = bad1.model_copy(update={"down_payment_min_pct": 99.0})
    bad2 = _offer("Bad2", 17.0)
    bad2 = bad2.model_copy(update={"term_years_max": 1})
    good = _offer("Good", 17.0)

    async def _fake_list(db, product_type=None, today=None):
        return [bad1, bad2, good]
    monkeypatch.setattr(multi_offer_mc, "list_active_offers", _fake_list)

    class _FakeSim:
        def __init__(self, *a, **kw):
            pass

        def run_for_offer(self, mortgage_rate, term_years=None):
            return _fake_mc(1.2)

    monkeypatch.setattr(multi_offer_mc, "MonteCarloSimulatorFast", _FakeSim)

    result = await multi_offer_mc.run_monte_carlo_all_offers(
        db=None,
        audit_input=inp,
        num_simulations=100,
    )
    assert result.num_offers == 1
    assert result.skipped_ineligible == 2
    assert result.recommended_bank == "Good"


@pytest.mark.anyio
async def test_empty_offers_returns_zero(monkeypatch):
    from audit_engine import multi_offer_mc

    async def _fake_list(db, product_type=None, today=None):
        return []
    monkeypatch.setattr(multi_offer_mc, "list_active_offers", _fake_list)

    result = await multi_offer_mc.run_monte_carlo_all_offers(
        db=None,
        audit_input=_audit_input(),
        num_simulations=100,
    )
    assert result.num_offers == 0
    assert result.per_offer == []
    assert result.recommended_offer_id is None


# ---- anyio backend pin: asyncio only (trio не нужен в этом проекте) -------

@pytest.fixture
def anyio_backend():
    return "asyncio"
