"""API-тесты для /bank-offers + /audit/{id}/compare-offers.

БД замокана NoopDB, доступы к БД — через monkeypatch на функции модуля.
"""
from __future__ import annotations

import os
import sys
from datetime import date
from types import SimpleNamespace

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

import pytest

try:
    from fastapi.testclient import TestClient
except ImportError:
    TestClient = None  # type: ignore

from audit_engine.models import (
    AuditInput,
    BankOffer,
    BankProductType,
    MonteCarloResult,
    MonteCarloSummary,
    MultiOfferMCResult,
    OfferMCSummary,
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


def _offer(bank: str = "Сбер") -> BankOffer:
    return BankOffer(
        id="00000000-0000-0000-0000-00000000aaaa",
        bank_name=bank,
        product_type=BankProductType.MORTGAGE,
        product_name="Ипотека на готовое жильё",
        rate_min=18.0,
        rate_max=22.0,
        term_years_min=1,
        term_years_max=30,
        down_payment_min_pct=15.0,
        max_loan_amount=100_000_000,
        requirements={},
        valid_from=date(2026, 1, 1),
    )


def _fake_mc_summary() -> MonteCarloSummary:
    def _r(strategy, median):
        return MonteCarloResult(
            num_simulations=10,
            strategy=strategy,
            ei_mean=median,
            ei_median=median,
            ei_p5=median - 0.1,
            ei_p25=median - 0.05,
            ei_p75=median + 0.05,
            ei_p95=median + 0.1,
            ei_std=0.05,
            buy_probability=60.0,
            distribution_data={},
        )

    return MonteCarloSummary(
        cash=_r("cash", 1.0),
        mortgage=_r("mortgage", 1.2),
        deposit=_r("deposit", 0.9),
        recommended_strategy="mortgage",
        confidence_level="medium",
    )


class _NoopDB:
    async def execute(self, *args, **kwargs):
        return SimpleNamespace(
            first=lambda: None,
            fetchall=lambda: [],
            scalar=lambda: None,
            rowcount=0,
        )


@pytest.fixture
def client(monkeypatch):
    if TestClient is None:
        pytest.skip("fastapi not installed")

    from audit_engine.api.app import app
    from audit_engine.api.deps import get_db

    async def _override_db():
        yield _NoopDB()

    app.dependency_overrides[get_db] = _override_db
    yield TestClient(app), monkeypatch
    app.dependency_overrides.clear()


def test_get_bank_offers_returns_list(client):
    tc, monkeypatch = client
    from audit_engine.api.routers import bank_offers as router_mod

    async def _fake_list(db, product_type=None, today=None):
        return [_offer("Сбер"), _offer("ВТБ")]

    monkeypatch.setattr(router_mod, "list_active_offers", _fake_list)

    resp = tc.get("/api/v2/bank-offers/")
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert len(body) == 2
    assert body[0]["bank_name"] == "Сбер"


def test_get_bank_offer_404(client):
    tc, monkeypatch = client
    from audit_engine.api.routers import bank_offers as router_mod

    async def _fake_get(db, offer_id):
        return None

    monkeypatch.setattr(router_mod, "get_offer", _fake_get)

    resp = tc.get("/api/v2/bank-offers/00000000-0000-0000-0000-000000000001")
    assert resp.status_code == 404


def test_compare_offers_endpoint(client):
    """POST /audit/{id}/compare-offers — запускает multi-offer MC."""
    tc, monkeypatch = client
    from audit_engine.api.routers import audit as audit_router

    async def _fake_load(db, audit_id):
        return _audit_input()

    monkeypatch.setattr(audit_router, "_load_audit_input", _fake_load)

    fake_result = MultiOfferMCResult(
        audit_id="00000000-0000-0000-0000-000000000001",
        num_simulations=100,
        num_offers=1,
        per_offer=[
            OfferMCSummary(
                offer=_offer("Сбер"),
                effective_rate=20.0,
                monte_carlo=_fake_mc_summary(),
                ei_mortgage_median=1.2,
                ei_mortgage_mean=1.2,
                ei_mortgage_p5=1.1,
                ei_mortgage_p95=1.3,
                buy_probability=60.0,
            ),
        ],
        recommended_offer_id="00000000-0000-0000-0000-00000000aaaa",
        recommended_bank="Сбер",
        recommended_product="Ипотека на готовое жильё",
        skipped_ineligible=0,
    )

    async def _fake_run(db, audit_input, **kw):
        return fake_result

    monkeypatch.setattr(audit_router, "run_monte_carlo_all_offers", _fake_run)

    async def _fake_save(db, audit_id, result):
        return None

    monkeypatch.setattr(audit_router, "save_multi_offer_run", _fake_save)

    resp = tc.post(
        "/api/v2/audit/00000000-0000-0000-0000-000000000001/compare-offers",
        params={"num_simulations": 100, "seed": 42},
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["num_offers"] == 1
    assert body["recommended_bank"] == "Сбер"
    assert len(body["per_offer"]) == 1


def test_compare_offers_rejects_over_ceiling(client):
    tc, monkeypatch = client
    from audit_engine.api.routers import audit as audit_router
    from audit_engine.config import settings

    async def _fake_load(db, audit_id):
        return _audit_input()

    monkeypatch.setattr(audit_router, "_load_audit_input", _fake_load)

    resp = tc.post(
        "/api/v2/audit/00000000-0000-0000-0000-000000000001/compare-offers",
        params={"num_simulations": settings.mc_max_simulations + 1},
    )
    assert resp.status_code == 413
