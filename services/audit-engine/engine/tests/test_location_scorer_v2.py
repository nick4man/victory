"""F3 — расширения location_scorer.py: новые POI-типы + breakdown в ответе.

Pure-unit-тесты на helper-функции и форму ответа. Интеграционные тесты
с реальной PostGIS — в test_location_scorer.py.
"""
from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

import pytest

from audit_engine.location_scorer import (
    _ALL_POI_TYPES,
    _DISTANCE_THRESHOLDS_M,
    _PRIMARY_POI_TYPES,
    _SCORE_WEIGHTS,
    _SECONDARY_POI_TYPES,
    _density_component,
    _distance_component,
)


# -----------------------------------------------------------------------
# _distance_component
# -----------------------------------------------------------------------

class TestDistanceComponent:
    def test_none_distance_returns_zero(self):
        assert _distance_component(None, 1500.0) == 0.0

    def test_zero_distance_returns_one(self):
        assert _distance_component(0, 1500.0) == 1.0

    def test_threshold_distance_returns_zero(self):
        assert _distance_component(1500, 1500.0) == 0.0

    def test_beyond_threshold_clipped_to_zero(self):
        assert _distance_component(3000, 1500.0) == 0.0

    def test_halfway_returns_half(self):
        assert _distance_component(750, 1500.0) == 0.5


# -----------------------------------------------------------------------
# _density_component
# -----------------------------------------------------------------------

class TestDensityComponent:
    def test_zero_poi_returns_zero(self):
        assert _density_component(0) == 0.0

    def test_negative_returns_zero(self):
        assert _density_component(-5) == 0.0

    def test_saturation_cap(self):
        # ≥ 12 POI → 1.0
        assert _density_component(12) == 1.0
        assert _density_component(100) == 1.0

    def test_partial_density(self):
        # 6 / 12 = 0.5
        assert _density_component(6) == 0.5


# -----------------------------------------------------------------------
# POI types registry (F3 — расширение)
# -----------------------------------------------------------------------

class TestPoiTypeRegistry:
    def test_primary_unchanged(self):
        """Primary не меняем — расстояние до них определяющее."""
        assert set(_PRIMARY_POI_TYPES) == {"metro", "school", "hospital"}

    def test_secondary_extended_for_v2(self):
        """F3: расширили secondary."""
        expected_new = {"clinic", "pharmacy", "fitness", "supermarket"}
        assert expected_new.issubset(set(_SECONDARY_POI_TYPES))

    def test_no_duplicates_between_primary_secondary(self):
        assert set(_PRIMARY_POI_TYPES).isdisjoint(set(_SECONDARY_POI_TYPES))

    def test_all_types_is_union(self):
        assert set(_ALL_POI_TYPES) == set(_PRIMARY_POI_TYPES) | set(_SECONDARY_POI_TYPES)


# -----------------------------------------------------------------------
# Score weights (sanity)
# -----------------------------------------------------------------------

class TestScoreWeights:
    def test_weights_sum_to_one(self):
        total = sum(_SCORE_WEIGHTS.values())
        assert abs(total - 1.0) < 0.001

    def test_metro_has_highest_weight(self):
        """Метро всегда самый важный POI для аудита."""
        max_key = max(_SCORE_WEIGHTS, key=_SCORE_WEIGHTS.get)
        assert max_key == "metro"

    def test_distance_thresholds_cover_primary(self):
        for t in _PRIMARY_POI_TYPES:
            assert t in _DISTANCE_THRESHOLDS_M
            assert _DISTANCE_THRESHOLDS_M[t] > 0


# -----------------------------------------------------------------------
# LocationScore model — components field (F3 addition)
# -----------------------------------------------------------------------

def test_location_score_accepts_components():
    """LocationScore теперь принимает components dict."""
    from audit_engine.models import LocationScore

    ls = LocationScore(
        lat=55.75,
        lon=37.62,
        score=0.85,
        total_poi_within_1km=8,
        components={"metro": 0.9, "school": 0.7, "hospital": 0.5, "poi_density": 0.67},
    )
    assert ls.components["metro"] == 0.9
    assert ls.score == 0.85


def test_location_score_components_default_empty():
    """Backwards-compat: старые вызовы без components — пустой dict."""
    from audit_engine.models import LocationScore

    ls = LocationScore(lat=55.75, lon=37.62, score=0.5)
    assert ls.components == {}
