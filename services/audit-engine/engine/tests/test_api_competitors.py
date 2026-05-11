"""API-тесты `GET /audit/{id}/competitors` с подменёнными зависимостями.

Мокаем `_load_audit_input` (возвращает фикстурный AuditInput с lat/lon
Кремля) и `fetch_competitors_by_radius` (возвращает 10 фикстурных компов).
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

from audit_engine.models import AuditInput, Competitor


def _build_audit_input_with_coords() -> AuditInput:
    return AuditInput(
        complex_name="ЖК Символ",
        apartment_type="2BR",
        area_sqm=60.0,
        price_total=18_000_000,   # 300k/м²
        monthly_rent=60_000,
        mortgage_rate=17.0,
        deposit_rate=14.0,
        price_growth_annual=7.9,
        horizon_years=5,
        lat=55.7520,
        lon=37.6175,
    )


def _build_audit_input_no_coords() -> AuditInput:
    return AuditInput(
        complex_name="ЖК Без-координат",
        apartment_type="2BR",
        area_sqm=60.0,
        price_total=12_000_000,  # 200k/м²
        monthly_rent=45_000,
        mortgage_rate=17.0,
        deposit_rate=14.0,
        price_growth_annual=7.9,
        horizon_years=5,
    )


def _mk_comp(price_sqm: float, name: str) -> Competitor:
    return Competitor(
        complex_name="ЖК Символ",
        snapshot_date=date(2026, 4, 1),
        competitor_name=name,
        latitude=55.7530,
        longitude=37.6180,
        distance_m=150,
        price_per_sqm=price_sqm,
        source="cian",
    )


class _NoopDB:
    async def execute(self, *args, **kwargs):
        return SimpleNamespace(first=lambda: None, fetchall=lambda: [])


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

    yield TestClient(app), monkeypatch, audit_router
    app.dependency_overrides.clear()


def test_competitors_endpoint_returns_overpay_signal(client):
    tc, monkeypatch, audit_router = client

    async def _fake_load(db, audit_id):
        return _build_audit_input_with_coords()

    # 10 компов со средней ценой ~200k/м² — наша 300k/м² в верхнем квартиле.
    comps = [_mk_comp(200_000.0 + i * 10_000, f"c{i}") for i in range(10)]

    async def _fake_fetch_radius(db, lat, lon, radius_m, days_back, property_type=None):
        assert abs(lat - 55.7520) < 1e-6
        assert abs(lon - 37.6175) < 1e-6
        return comps

    monkeypatch.setattr(audit_router, "_load_audit_input", _fake_load)
    monkeypatch.setattr(audit_router, "fetch_competitors_by_radius", _fake_fetch_radius)

    resp = tc.get("/api/v2/audit/abc/competitors?radius_m=1500&days_back=60")
    assert resp.status_code == 200
    body = resp.json()
    assert body["sample_size"] == 10
    assert body["radius_m"] == 1500
    assert body["signal"] == "OVERPAY"
    assert body["percentile"] >= 75.0
    assert len(body["top5"]) == 5


def test_competitors_endpoint_falls_back_to_complex_name_when_no_coords(client):
    tc, monkeypatch, audit_router = client

    async def _fake_load(db, audit_id):
        return _build_audit_input_no_coords()

    called = {"by_complex": 0, "by_radius": 0}

    async def _fake_fetch_complex(db, complex_name, days_back):
        called["by_complex"] += 1
        assert complex_name == "ЖК Без-координат"
        return [_mk_comp(200_000.0 + i * 5_000, f"c{i}") for i in range(8)]

    async def _fake_fetch_radius(db, lat, lon, radius_m, days_back, property_type=None):
        called["by_radius"] += 1
        return []

    monkeypatch.setattr(audit_router, "_load_audit_input", _fake_load)
    monkeypatch.setattr(audit_router, "fetch_competitors_by_complex", _fake_fetch_complex)
    monkeypatch.setattr(audit_router, "fetch_competitors_by_radius", _fake_fetch_radius)

    resp = tc.get("/api/v2/audit/xyz/competitors")
    assert resp.status_code == 200
    assert called["by_complex"] == 1
    assert called["by_radius"] == 0
    body = resp.json()
    assert body["sample_size"] == 8


def test_competitors_endpoint_insufficient_when_few_comps(client):
    tc, monkeypatch, audit_router = client

    async def _fake_load(db, audit_id):
        return _build_audit_input_with_coords()

    async def _fake_fetch_radius(db, lat, lon, radius_m, days_back, property_type=None):
        return [_mk_comp(250_000.0, "one"), _mk_comp(260_000.0, "two")]

    monkeypatch.setattr(audit_router, "_load_audit_input", _fake_load)
    monkeypatch.setattr(audit_router, "fetch_competitors_by_radius", _fake_fetch_radius)

    resp = tc.get("/api/v2/audit/abc/competitors")
    assert resp.status_code == 200
    body = resp.json()
    assert body["signal"] == "INSUFFICIENT"
    assert body["sample_size"] == 2


def test_competitors_endpoint_rejects_bad_radius(client):
    tc, _, _ = client
    resp = tc.get("/api/v2/audit/abc/competitors?radius_m=0")
    assert resp.status_code == 400
    resp = tc.get("/api/v2/audit/abc/competitors?radius_m=100000")
    assert resp.status_code == 400


def test_competitors_endpoint_rejects_bad_days_back(client):
    tc, _, _ = client
    resp = tc.get("/api/v2/audit/abc/competitors?days_back=0")
    assert resp.status_code == 400
    resp = tc.get("/api/v2/audit/abc/competitors?days_back=1000")
    assert resp.status_code == 400
