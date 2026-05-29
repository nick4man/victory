"""Геопримитивы для audit-engine: haversine + bounding-box префильтр.

Зачем свой модуль, а не ORM-версия из `workspace-conveyor`:
* У нас async asyncpg-стек с raw SQL через `text()` — не тащим sync Session.
* haversine над bbox-префильтром достаточно быстр без PostGIS
  (bbox отсекает >99% строк индексом).
"""
from __future__ import annotations

import math
from typing import Final

EARTH_RADIUS_KM: Final[float] = 6371.0
# На широте Москвы 1° широты ≈ 111 км, 1° долготы ≈ 63 км.
_KM_PER_DEG_LAT: Final[float] = 111.0


def haversine_distance_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Большое круговое расстояние между двумя точками на Земле (км)."""
    lat1_rad = math.radians(lat1)
    lat2_rad = math.radians(lat2)
    dlat = math.radians(lat2 - lat1)
    dlon = math.radians(lon2 - lon1)

    a = (
        math.sin(dlat / 2.0) ** 2
        + math.cos(lat1_rad) * math.cos(lat2_rad) * math.sin(dlon / 2.0) ** 2
    )
    c = 2.0 * math.atan2(math.sqrt(a), math.sqrt(1.0 - a))
    return EARTH_RADIUS_KM * c


def bounding_box(
    lat: float, lon: float, radius_km: float
) -> tuple[float, float, float, float]:
    """Грубый прямоугольник (min_lat, max_lat, min_lon, max_lon) вокруг точки.

    Используется как префильтр в SQL: `WHERE latitude BETWEEN ... AND ...`.
    Широта — константа; для долготы корректируем по cos(lat), чтобы бокс
    не «сжимался» на полюсах.
    """
    dlat = radius_km / _KM_PER_DEG_LAT
    cos_lat = max(math.cos(math.radians(lat)), 1e-6)
    dlon = radius_km / (_KM_PER_DEG_LAT * cos_lat)
    return (lat - dlat, lat + dlat, lon - dlon, lon + dlon)
