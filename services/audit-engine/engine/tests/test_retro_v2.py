"""Tests for RetroAnalyzerV2 — DB-backed retro + what-if."""
from __future__ import annotations

import os
import sys
from datetime import date, timedelta
from types import SimpleNamespace

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

import pytest

from audit_engine.models import AuditInput, WhatIfResult
from audit_engine.retro_analyzer import RetroAnalyzerV2, _ei_verdict


def make_input() -> AuditInput:
    return AuditInput(
        complex_name="ЖК Мостовая 5",
        apartment_type="2BR",
        area_sqm=60.0,
        price_total=12_000_000,
        monthly_rent=50_000,
        mortgage_rate=17.0,
        mortgage_term_years=20,
        down_payment_pct=20.0,
        deposit_rate=14.0,
        price_growth_annual=7.9,
        horizon_years=5,
        cash_discount_pct=10.0,
    )


class FakeResult:
    """Имитирует результат SQLAlchemy execute()."""

    def __init__(self, rows: list[dict]):
        self._rows = rows

    def fetchall(self):
        return [SimpleNamespace(_mapping=r) for r in self._rows]


class FakeSession:
    """Минимальный AsyncSession-подобный мок.

    Принимает список «ответов» — выдаёт в порядке вызова execute().
    """

    def __init__(self, responses: list[list[dict]]):
        self._responses = list(responses)
        self.queries: list[tuple[str, dict]] = []

    async def execute(self, stmt, params=None):
        # sqlalchemy.text -> .text; но мок принимает и сырую строку
        sql = getattr(stmt, "text", str(stmt))
        self.queries.append((sql, params or {}))
        if not self._responses:
            return FakeResult([])
        return FakeResult(self._responses.pop(0))


@pytest.mark.asyncio
async def test_load_historical_data_splits_prices_and_macro():
    today = date.today()
    prices_rows = [
        {
            "snapshot_date": today - timedelta(days=365),
            "price_per_sqm": 180_000,
            "source": "cian",
            "macro_snapshot": {
                "mortgage_rate": 11.0, "deposit_rate": 7.5,
                "inflation": 6.0, "price_growth": 8.0,
            },
        },
        {
            "snapshot_date": today - timedelta(days=730),
            "price_per_sqm": 160_000,
            "source": "avito",
            "macro_snapshot": {
                "mortgage_rate": 9.0, "deposit_rate": 6.0,
                "inflation": 5.5, "price_growth": 12.0,
            },
        },
    ]
    session = FakeSession([prices_rows])
    analyzer = RetroAnalyzerV2(session)

    prices, macro = await analyzer.load_historical_data("ЖК Мостовая 5", "2BR")
    assert len(prices) == 2
    assert prices[0]["source"] == "cian"
    assert prices[0]["price_per_sqm"] == 180_000
    assert len(macro) == 2
    assert macro[0]["mortgage_rate"] == 11.0
    # SQL должен был получить complex_name и apartment_type
    assert session.queries[0][1]["cn"] == "ЖК Мостовая 5"
    assert session.queries[0][1]["at"] == "2BR"


@pytest.mark.asyncio
async def test_load_historical_falls_back_to_macro_economics_when_no_snapshot():
    today = date.today()
    prices_rows = [
        {
            "snapshot_date": today - timedelta(days=365),
            "price_per_sqm": 180_000,
            "source": "cian",
            "macro_snapshot": None,
        },
    ]
    macro_rows = [
        {
            "date": today - timedelta(days=365),
            "avg_mortgage_rate": 11.5,
            "avg_deposit_rate": 7.8,
            "inflation_annual": 6.2,
            "cbr_key_rate": 8.5,
        },
    ]
    session = FakeSession([prices_rows, macro_rows])
    analyzer = RetroAnalyzerV2(session)

    prices, macro = await analyzer.load_historical_data("ЖК Мостовая 5", "2BR")
    assert len(prices) == 1
    assert len(macro) == 1
    assert macro[0]["mortgage_rate"] == 11.5
    assert macro[0]["deposit_rate"] == 7.8
    # Второй запрос — из macro_economics
    assert len(session.queries) == 2


@pytest.mark.asyncio
async def test_what_if_returns_points_for_each_year():
    today = date.today()
    # current_value = 60 sqm * 200_000 ppsm = 12_000_000 => snapshots должны быть ниже
    snaps = [
        (1, 180_000, 10.0, 7.5),
        (2, 160_000, 9.0, 6.5),
        (3, 140_000, 8.0, 6.0),
        (5, 110_000, 12.0, 8.0),
    ]
    prices_rows = []
    for years, ppsm, mr, dr in snaps:
        snap_date = today - timedelta(days=365 * years)
        prices_rows.append({
            "snapshot_date": snap_date,
            "price_per_sqm": ppsm,
            "source": "manual",
            "macro_snapshot": {
                "mortgage_rate": mr, "deposit_rate": dr,
                "inflation": 6.0, "price_growth": 8.0,
                "date": snap_date.isoformat(),
            },
        })

    session = FakeSession([prices_rows])
    analyzer = RetroAnalyzerV2(session)
    results = await analyzer.what_if_analysis(make_input(), [1, 2, 3, 5])

    assert len(results) == 4
    for r in results:
        assert isinstance(r, WhatIfResult)
        assert r.current_value == 12_000_000
        assert r.purchase_price > 0
        # чем давнее — тем больше прибыль (цены исторически ниже)
        assert r.profit_absolute > 0
        assert r.ei_verdict in (
            "Отличная покупка", "Хорошая", "Нейтрально", "Убыток",
        )


@pytest.mark.asyncio
async def test_what_if_skips_years_without_snapshots():
    today = date.today()
    prices_rows = [{
        "snapshot_date": today - timedelta(days=365 * 2),
        "price_per_sqm": 170_000,
        "source": "manual",
        "macro_snapshot": {
            "mortgage_rate": 9.0, "deposit_rate": 6.5,
            "date": (today - timedelta(days=365 * 2)).isoformat(),
        },
    }]
    session = FakeSession([prices_rows])
    analyzer = RetroAnalyzerV2(session)
    results = await analyzer.what_if_analysis(make_input(), [1, 2, 5])
    # Есть только snapshot для ~2 лет назад
    assert len(results) == 1
    assert results[0].years_ago == 2


@pytest.mark.asyncio
async def test_what_if_empty_years_back_returns_empty():
    session = FakeSession([[]])
    analyzer = RetroAnalyzerV2(session)
    assert await analyzer.what_if_analysis(make_input(), []) == []


def test_ei_verdict_thresholds():
    assert _ei_verdict(1.5) == "Отличная покупка"
    assert _ei_verdict(1.2) == "Хорошая"
    assert _ei_verdict(1.0) == "Нейтрально"
    assert _ei_verdict(0.8) == "Убыток"


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
