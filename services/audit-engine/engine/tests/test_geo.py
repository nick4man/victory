"""Юнит-тесты для `audit_engine.geo` — haversine и bbox."""
from __future__ import annotations

import math
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

from audit_engine.geo import bounding_box, haversine_distance_km


def test_haversine_zero_for_same_point():
    assert haversine_distance_km(55.75, 37.61, 55.75, 37.61) == 0.0


def test_haversine_kremlin_to_red_square():
    """Кремль (55.7520, 37.6175) до Красной площади (55.7539, 37.6208)."""
    d = haversine_distance_km(55.7520, 37.6175, 55.7539, 37.6208)
    # Это примерно 290 м.
    assert 0.2 < d < 0.4


def test_haversine_moscow_to_spb():
    """Москва ↔ СПб ≈ 633 км по прямой."""
    d = haversine_distance_km(55.7558, 37.6173, 59.9343, 30.3351)
    assert 620 < d < 650


def test_haversine_symmetric():
    d1 = haversine_distance_km(55.0, 37.0, 60.0, 30.0)
    d2 = haversine_distance_km(60.0, 30.0, 55.0, 37.0)
    assert abs(d1 - d2) < 1e-9


def test_bounding_box_contains_center_and_radius_point():
    lat, lon = 55.75, 37.61
    radius_km = 2.0
    min_lat, max_lat, min_lon, max_lon = bounding_box(lat, lon, radius_km)

    # Центр внутри.
    assert min_lat < lat < max_lat
    assert min_lon < lon < max_lon

    # Точка на ~1 км к северу должна попадать в bbox.
    north = lat + 1.0 / 111.0
    assert min_lat < north < max_lat


def test_bounding_box_dlon_scales_with_latitude():
    """На высоких широтах bbox по долготе шире (1° долготы короче)."""
    _, _, mnlon_eq, mxlon_eq = bounding_box(0.0, 0.0, 10.0)
    _, _, mnlon_hi, mxlon_hi = bounding_box(70.0, 0.0, 10.0)
    assert (mxlon_hi - mnlon_hi) > (mxlon_eq - mnlon_eq)
