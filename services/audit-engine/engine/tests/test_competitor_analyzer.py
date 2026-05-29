"""Юнит-тесты `competitor_analyzer.analyze` — без БД.

Фикстурный список компов → проверяем перцентиль, сигнал, top-5.
"""
from __future__ import annotations

import os
import sys
from datetime import date

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

from audit_engine.competitor_analyzer import (
    _empirical_percentile,
    _quantile,
    analyze,
)
from audit_engine.models import Competitor, CompetitorSignal


def _mk(price_sqm: float, name: str = "Комп") -> Competitor:
    return Competitor(
        complex_name="ЖК Тест",
        snapshot_date=date(2026, 4, 1),
        competitor_name=name,
        price_per_sqm=price_sqm,
        source="cian",
    )


def test_quantile_linear_interpolation():
    vals = [10.0, 20.0, 30.0, 40.0, 50.0]
    assert _quantile(vals, 0.0) == 10.0
    assert _quantile(vals, 0.5) == 30.0
    assert _quantile(vals, 1.0) == 50.0
    assert _quantile(vals, 0.25) == 20.0
    assert _quantile(vals, 0.75) == 40.0


def test_empirical_percentile_for_median():
    vals = [10.0, 20.0, 30.0, 40.0, 50.0]
    # Середина выборки → ~50-й перцентиль.
    assert abs(_empirical_percentile(vals, 30.0) - 50.0) < 1e-6


def test_empirical_percentile_clamp():
    vals = [10.0, 20.0, 30.0]
    assert _empirical_percentile(vals, 5.0) == 0.0
    assert _empirical_percentile(vals, 100.0) == 100.0


def test_analyze_insufficient_sample():
    comps = [_mk(p) for p in (100_000.0, 110_000.0)]
    result = analyze(audit_price_per_sqm=120_000.0, competitors=comps)
    assert result.signal == CompetitorSignal.INSUFFICIENT
    assert result.sample_size == 2
    assert result.median_price_per_sqm is None
    # Но top-5 всё равно формируется от имеющихся.
    assert len(result.top5) == 2


def test_analyze_overpay_signal():
    """Цена в верхнем квартиле → OVERPAY."""
    comps = [_mk(p) for p in (100_000.0, 110_000.0, 120_000.0, 130_000.0, 140_000.0,
                               150_000.0, 160_000.0, 170_000.0, 180_000.0, 190_000.0)]
    result = analyze(audit_price_per_sqm=185_000.0, competitors=comps)
    assert result.signal == CompetitorSignal.OVERPAY
    assert result.percentile >= 75.0
    assert result.median_price_per_sqm == 145_000.0


def test_analyze_underpay_signal():
    """Цена в нижнем квартиле → UNDERPAY."""
    comps = [_mk(p) for p in (100_000.0, 110_000.0, 120_000.0, 130_000.0, 140_000.0,
                               150_000.0, 160_000.0, 170_000.0, 180_000.0, 190_000.0)]
    result = analyze(audit_price_per_sqm=105_000.0, competitors=comps)
    assert result.signal == CompetitorSignal.UNDERPAY
    assert result.percentile <= 25.0


def test_analyze_fair_signal():
    """Цена у медианы → FAIR."""
    comps = [_mk(p) for p in (100_000.0, 110_000.0, 120_000.0, 130_000.0, 140_000.0,
                               150_000.0, 160_000.0, 170_000.0, 180_000.0, 190_000.0)]
    result = analyze(audit_price_per_sqm=145_000.0, competitors=comps)
    assert result.signal == CompetitorSignal.FAIR
    assert 25.0 < result.percentile < 75.0


def test_analyze_top5_sorted_by_distance_to_target():
    """top5 — компы с ценами, ближайшими к аудитной."""
    comps = [_mk(p, f"c{p}") for p in (100_000.0, 105_000.0, 150_000.0, 152_000.0,
                                        153_000.0, 200_000.0, 250_000.0)]
    result = analyze(audit_price_per_sqm=151_000.0, competitors=comps)
    assert len(result.top5) == 5
    names = [c.competitor_name for c in result.top5]
    # Три ближайших к 151k: 150k, 152k, 153k — должны быть в начале.
    assert names[:3] == ["c150000.0", "c152000.0", "c153000.0"]


def test_analyze_preserves_radius():
    comps = [_mk(100_000.0 + i * 1000) for i in range(20)]
    result = analyze(audit_price_per_sqm=110_000.0, competitors=comps, radius_m=1500)
    assert result.radius_m == 1500
    assert result.sample_size == 20
