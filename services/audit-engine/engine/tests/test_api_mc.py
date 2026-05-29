"""Integration-style tests for MC / Retro / What-If API endpoints.

Тесты работают без живой Postgres: мокаем `get_db` зависимость FastAPI
и подменяем `RetroAnalyzerV2` / `get_latest_monte_carlo` / `_load_audit_input`.
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
except ImportError:  # fastapi не установлен — фактически будет собрано вместе с проектом
    TestClient = None  # type: ignore

from audit_engine.models import AuditInput, MonteCarloSummary, WhatIfResult


def _build_audit_input() -> AuditInput:
    return AuditInput(
        complex_name="ЖК Тест",
        apartment_type="2BR",
        area_sqm=60.0,
        price_total=12_000_000,
        monthly_rent=45_000,
        mortgage_rate=17.0,
        deposit_rate=14.0,
        price_growth_annual=7.9,
        horizon_years=5,
    )


class _NoopDB:
    """Подменяет AsyncSession для ручек, которые ходят в БД только через моки."""

    async def execute(self, *args, **kwargs):
        return SimpleNamespace(
            first=lambda: None,
            fetchall=lambda: [],
            scalar=lambda: None,
        )


@pytest.fixture
def client(monkeypatch):
    if TestClient is None:
        pytest.skip("fastapi not installed")

    from audit_engine.api.app import app
    from audit_engine.api.deps import get_db
    from audit_engine.api.routers import audit as audit_router

    async def _override_db():
        yield _NoopDB()

    app.dependency_overrides[get_db] = _override_db

    # Общий мок: _load_audit_input всегда возвращает фикстурный AuditInput
    async def _fake_load(db, audit_id):  # noqa: D401
        return _build_audit_input()

    monkeypatch.setattr(audit_router, "_load_audit_input", _fake_load)

    yield TestClient(app), monkeypatch, audit_router

    app.dependency_overrides.clear()


def test_run_monte_carlo_endpoint(client):
    tc, monkeypatch, audit_router = client

    # save_monte_carlo_run — no-op
    async def _fake_save(db, audit_id, summary, params=None):
        return []
    monkeypatch.setattr(audit_router, "save_monte_carlo_run", _fake_save)

    # Изолируем кеш идемпотентности между тестами
    from audit_engine.mc_storage import mc_cache_clear
    mc_cache_clear()

    resp = tc.post(
        "/api/v2/audit/00000000-0000-0000-0000-000000000001/monte-carlo",
        params={"num_simulations": 500, "seed": 42},
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert "cash" in body and "mortgage" in body and "deposit" in body
    assert body["recommended_strategy"] in ("cash", "mortgage", "deposit")
    assert body["confidence_level"] in ("high", "medium", "low")
    # P1/P99 теперь в payload
    assert "ei_p1" in body["cash"] and "ei_p99" in body["cash"]


def test_run_monte_carlo_rejects_over_ceiling(client):
    tc, monkeypatch, audit_router = client
    from audit_engine.config import settings

    async def _fake_save(db, audit_id, summary, params=None):
        return []
    monkeypatch.setattr(audit_router, "save_monte_carlo_run", _fake_save)

    resp = tc.post(
        "/api/v2/audit/00000000-0000-0000-0000-000000000001/monte-carlo",
        params={"num_simulations": settings.mc_max_simulations + 1, "seed": 42},
    )
    assert resp.status_code == 413, resp.text


def test_run_monte_carlo_idempotent_cache(client):
    """Второй POST с тем же (audit_id, n, seed) — кеш-хит."""
    tc, monkeypatch, audit_router = client

    call_count = {"n": 0}
    original = audit_router.MonteCarloSimulatorFast

    class _CountingSim(original):
        def run_vectorized(self):
            call_count["n"] += 1
            return super().run_vectorized()

    monkeypatch.setattr(audit_router, "MonteCarloSimulatorFast", _CountingSim)

    async def _fake_save(db, audit_id, summary, params=None):
        return []
    monkeypatch.setattr(audit_router, "save_monte_carlo_run", _fake_save)

    from audit_engine.mc_storage import mc_cache_clear
    mc_cache_clear()

    url = "/api/v2/audit/00000000-0000-0000-0000-000000000001/monte-carlo"
    params = {"num_simulations": 500, "seed": 777}

    r1 = tc.post(url, params=params)
    r2 = tc.post(url, params=params)
    assert r1.status_code == 200 and r2.status_code == 200
    assert r1.json() == r2.json()
    assert call_count["n"] == 1, f"second call should be cache hit, got {call_count['n']} runs"


def test_get_monte_carlo_latest_empty_returns_404(client):
    tc, monkeypatch, audit_router = client

    async def _fake_latest(db, audit_id):
        return None
    monkeypatch.setattr(audit_router, "get_latest_monte_carlo", _fake_latest)

    resp = tc.get("/api/v2/audit/00000000-0000-0000-0000-000000000001/monte-carlo")
    assert resp.status_code == 404


def test_get_monte_carlo_history_mode(client):
    tc, monkeypatch, audit_router = client

    async def _fake_hist(db, audit_id):
        return [{"strategy": "cash", "ei_mean": 1.1}]
    monkeypatch.setattr(audit_router, "get_monte_carlo_history", _fake_hist)

    resp = tc.get(
        "/api/v2/audit/00000000-0000-0000-0000-000000000001/monte-carlo",
        params={"history": True},
    )
    assert resp.status_code == 200
    assert resp.json() == [{"strategy": "cash", "ei_mean": 1.1}]


def test_what_if_endpoint(client):
    tc, monkeypatch, audit_router = client

    class _FakeAnalyzer:
        def __init__(self, db):
            self.db = db

        async def what_if_analysis(self, current_input, years_list):
            return [
                WhatIfResult(
                    years_ago=y,
                    purchase_date=f"{date.today().year - y}-01-01",
                    purchase_price=10_000_000 + y * 100_000,
                    purchase_price_sqm=170_000,
                    current_value=12_000_000,
                    profit_absolute=2_000_000 - y * 100_000,
                    profit_pct=20.0 - y,
                    ei_at_purchase=1.1,
                    ei_verdict="Хорошая",
                    mortgage_rate_then=10.0,
                    deposit_rate_then=7.5,
                ) for y in years_list
            ]
        async def analyze_with_db(self, current_input):  # для retro-теста
            return {
                "complex_name": current_input.complex_name,
                "apartment_type": current_input.apartment_type,
                "snapshots": [],
                "delta_analysis": [],
                "ei_history": [],
                "developer_accuracy_pct": None,
                "inflation_adjusted": False,
            }

    monkeypatch.setattr(audit_router, "RetroAnalyzerV2", _FakeAnalyzer)

    resp = tc.get(
        "/api/v2/audit/00000000-0000-0000-0000-000000000001/what-if",
        params={"years_back": "1,2,3,5"},
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert len(body) == 4
    assert {p["years_ago"] for p in body} == {1, 2, 3, 5}


def test_what_if_rejects_bad_years_back(client):
    tc, _monkeypatch, _audit_router = client
    resp = tc.get(
        "/api/v2/audit/00000000-0000-0000-0000-000000000001/what-if",
        params={"years_back": "abc"},
    )
    assert resp.status_code == 400


def test_price_history_not_found(client):
    tc, _monkeypatch, _audit_router = client
    resp = tc.get("/api/v2/price-history/NoSuchComplex")
    assert resp.status_code == 404


def test_post_audit_returns_id(client):
    """POST /audit/ должен возвращать id (uuid) созданной записи.

    Регрессия: ранее AuditResult не имел поля `id`, хотя audit_id
    генерировался и сохранялся в БД — клиент не мог сослаться на запись.
    """
    tc, _monkeypatch, _audit_router = client

    resp = tc.post(
        "/api/v2/audit/",
        json={
            "complex_name": "ЖК Регрессия",
            "apartment_type": "1BR",
            "area_sqm": 40.0,
            "price_total": 8_000_000,
            "monthly_rent": 30_000,
            "mortgage_rate": 16.0,
            "deposit_rate": 13.0,
            "price_growth_annual": 7.0,
            "horizon_years": 5,
            "run_monte_carlo": False,
        },
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert "id" in body, "AuditResult must include `id` (see SKILL §4.1)"
    assert isinstance(body["id"], str) and len(body["id"]) == 36, (
        "id must be a UUID string"
    )


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
