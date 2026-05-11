"""Тесты `location_scorer.score_location` — с моком БД.

Мокаем `db.execute` возвращая фикстурный список POI; проверяем логику
расчёта расстояний, счётчиков и итогового скора.
"""
from __future__ import annotations

import os
import sys
from decimal import Decimal
from types import SimpleNamespace
from typing import Any

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "src"))

import pytest

from audit_engine.location_scorer import score_location


class _FakeRow:
    def __init__(self, **kwargs):
        self._mapping = kwargs


class _FakeResult:
    def __init__(self, rows):
        self._rows = rows

    def fetchall(self):
        return self._rows


class _FakeDB:
    """Отдаёт заранее подготовленные POI-строки на любой execute."""

    def __init__(self, pois: list[dict[str, Any]]):
        self._pois = pois

    async def execute(self, *args, **kwargs):
        rows = [_FakeRow(**p) for p in self._pois]
        return _FakeResult(rows)


@pytest.mark.anyio
async def test_score_is_high_near_dense_city_center():
    """Точка рядом с Красной площадью + метро в 200м + школа в 400м + парк
    в 600м → скор высокий."""
    kremlin = (55.7520, 37.6175)
    pois = [
        {"name": "Охотный ряд", "poi_type": "metro",
         "latitude": 55.7560, "longitude": 37.6180},  # ~450m
        {"name": "Школа 57", "poi_type": "school",
         "latitude": 55.7495, "longitude": 37.6200},  # ~350m
        {"name": "Александровский сад", "poi_type": "park",
         "latitude": 55.7530, "longitude": 37.6140},  # ~250m
        {"name": "ЦКБ", "poi_type": "hospital",
         "latitude": 55.7580, "longitude": 37.6250},  # ~850m
        # пять магазинов/детсадов в 1км для плотности
        {"name": "ТРЦ 1", "poi_type": "mall",
         "latitude": 55.7545, "longitude": 37.6190},
        {"name": "ТРЦ 2", "poi_type": "mall",
         "latitude": 55.7500, "longitude": 37.6150},
        {"name": "Детсад 1", "poi_type": "kindergarten",
         "latitude": 55.7510, "longitude": 37.6200},
        {"name": "Детсад 2", "poi_type": "kindergarten",
         "latitude": 55.7535, "longitude": 37.6160},
        {"name": "МГУ", "poi_type": "university",
         "latitude": 55.7530, "longitude": 37.6195},
    ]
    db = _FakeDB(pois)

    score = await score_location(db, kremlin[0], kremlin[1])
    assert score.nearest["metro"] is not None
    assert score.nearest["school"] is not None
    assert score.nearest["hospital"] is not None
    # метро ~450м → distance_m ≈ 450
    assert 300 <= score.nearest["metro"].distance_m <= 700
    assert score.score > 0.7


@pytest.mark.anyio
async def test_score_is_low_without_nearby_poi():
    """Точка в пригороде, POI далеко → скор низкий."""
    remote = (55.0, 37.0)  # далеко от Москвы
    pois = [
        # Все POI — в Москве (50+ км)
        {"name": "Метро Москва", "poi_type": "metro",
         "latitude": 55.75, "longitude": 37.62},
    ]
    db = _FakeDB(pois)

    score = await score_location(db, remote[0], remote[1], radius_km=2.0)
    assert score.nearest["metro"] is None
    assert score.nearest["school"] is None
    assert score.total_poi_within_1km == 0
    assert score.score == 0.0


@pytest.mark.anyio
async def test_poi_counts_within_1km():
    center = (55.7520, 37.6175)
    pois = [
        # В радиусе 1км
        {"name": "M1", "poi_type": "metro",
         "latitude": 55.7560, "longitude": 37.6180},
        {"name": "S1", "poi_type": "school",
         "latitude": 55.7495, "longitude": 37.6200},
        # В 1.5км — попадают в radius_km=2 но не в 1км
        {"name": "M2", "poi_type": "metro",
         "latitude": 55.7640, "longitude": 37.6200},
    ]
    db = _FakeDB(pois)

    score = await score_location(db, *center, radius_km=2.0)
    # В 1км: M1 (metro) + S1 (school) = 2
    assert score.poi_counts_1km["metro"] == 1
    assert score.poi_counts_1km["school"] == 1
    assert score.total_poi_within_1km == 2


@pytest.mark.anyio
async def test_score_monotone_in_metro_distance():
    """Чем ближе метро, тем выше скор (при прочих равных)."""
    base = (55.7520, 37.6175)

    close_metro = [{
        "name": "M", "poi_type": "metro",
        "latitude": 55.7520, "longitude": 37.6195,  # ~120m
    }]
    far_metro = [{
        "name": "M", "poi_type": "metro",
        "latitude": 55.7620, "longitude": 37.6175,  # ~1100m
    }]

    s_close = await score_location(_FakeDB(close_metro), *base)
    s_far = await score_location(_FakeDB(far_metro), *base)
    assert s_close.score > s_far.score


@pytest.fixture
def anyio_backend():
    return "asyncio"
