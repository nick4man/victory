"""Расчёт локационного скора объекта (фаза D).

Алгоритм:
1. bbox-префильтр в SQL (индекс `(poi_type, latitude, longitude)`).
2. haversine-фильтрация в Python — отбрасываем углы bbox'а.
3. Для каждого ключевого `poi_type` — ближайший POI.
4. Композитный скор ∈ [0, 1] на основе:
   - расстояния до метро / школы / больницы (чем ближе, тем лучше),
   - общей POI-плотности в радиусе 1 км (парки, ТРЦ, детсады и т.п.).

Веса — константы в `_SCORE_WEIGHTS`. Подстраиваются под продуктовые
гипотезы; не зашиваем их в settings, пока нет A/B.
"""
from __future__ import annotations

from datetime import datetime, timezone
from typing import Final, Optional

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession
from audit_engine.geo import haversine_distance_km


from audit_engine.models import LocationScore, POIHit


# Типы POI, которые напрямую влияют на скор через расстояние.
_PRIMARY_POI_TYPES: Final[tuple[str, ...]] = ("metro", "school", "hospital")
# Дополнительные типы считаем «плотностными» — важно сколько их в радиусе.
# F3 (Полу-v2.1): расширены — добавлены clinic, pharmacy, fitness, supermarket.
_SECONDARY_POI_TYPES: Final[tuple[str, ...]] = (
    "park", "mall", "kindergarten", "university",
    "clinic", "pharmacy", "fitness", "supermarket",
)
_ALL_POI_TYPES: Final[tuple[str, ...]] = _PRIMARY_POI_TYPES + _SECONDARY_POI_TYPES

# Параметры нормализации расстояний (чем ближе, тем лучше).
# Формула: component = max(0, 1 - distance_m / threshold_m).
_DISTANCE_THRESHOLDS_M: Final[dict[str, float]] = {
    "metro": 1500.0,     # до 1.5 км — линейно от 1 до 0.
    "school": 1500.0,
    "hospital": 3000.0,  # до 3 км — медицина реже.
}

# Вклад компонентов в итоговый скор (сумма = 1).
_SCORE_WEIGHTS: Final[dict[str, float]] = {
    "metro": 0.35,
    "school": 0.20,
    "hospital": 0.15,
    "poi_density": 0.30,  # функция от total_poi_within_1km.
}

# Насыщение плотностной компоненты: при ≥ _DENSITY_SATURATE POI в 1км скор = 1.
_DENSITY_SATURATE: Final[int] = 12


def _distance_component(distance_m: Optional[int], threshold_m: float) -> float:
    if distance_m is None:
        return 0.0
    return max(0.0, 1.0 - distance_m / threshold_m)


def _density_component(total_poi_1km: int) -> float:
    if total_poi_1km <= 0:
        return 0.0
    return min(1.0, total_poi_1km / _DENSITY_SATURATE)


async def score_location(
    db: AsyncSession,
    lat: float,
    lon: float,
    radius_km: float = 2.0,
) -> LocationScore:
    """Посчитать `LocationScore` для координаты.

    Делает один SQL-запрос с PostGIS ST_DWithin для фильтрации POI в радиусе
    и ST_DistanceSphere для расчёта расстояний. Радиус по умолчанию — 2 км
    (ближайшие объекты + плотность).
    """
    if not (-90.0 <= lat <= 90.0):
        raise ValueError(f"lat must be in [-90, 90], got {lat}")
    if not (-180.0 <= lon <= 180.0):
        raise ValueError(f"lon must be in [-180, 180], got {lon}")
    if radius_km <= 0 or radius_km > 50:
        raise ValueError(f"radius_km must be in (0, 50], got {radius_km}")

    radius_m = radius_km * 1000.0
    rows = await db.execute(
        text(
            "SELECT name, poi_type, "
            "       CAST(latitude AS double precision) AS latitude, "
            "       CAST(longitude AS double precision) AS longitude, "
            "       ST_DistanceSphere(geom, ST_SetSRID(ST_MakePoint(:lon, :lat), 4326)) AS distance_m "
            "FROM points_of_interest "
            "WHERE poi_type = ANY(:types) "
            "  AND ST_DWithin("
            "    geom::geography,"
            "    ST_SetSRID(ST_MakePoint(:lon, :lat), 4326)::geography,"
            "    :radius_m"
            "  )"
            "ORDER BY distance_m"
        ),
        {
            "types": list(_ALL_POI_TYPES),
            "lat": lat,
            "lon": lon,
            "radius_m": radius_m,
        },
    )

    # Все строки уже отфильтрованы ST_DWithin по радиусу и отсортированы по расстоянию.
    all_within: list[tuple[float, dict]] = []
    for r in rows.fetchall():
        m = r._mapping
        distance_m = m.get("distance_m")
        if distance_m is not None:
            dist_km = distance_m / 1000.0
        else:
            # fallback для старых данных или тестов
            dist_km = haversine_distance_km(lat, lon, m["latitude"], m["longitude"])
        # Проверяем радиус (для fallback)
        if dist_km > radius_km:
            continue
        all_within.append((
            dist_km,
            {
                "name": m["name"],
                "poi_type": m["poi_type"],
                "lat": float(m["latitude"]),
                "lon": float(m["longitude"]),
            },
        ))

    # Группировка по типам + ближайший для каждого.
    nearest: dict[str, Optional[POIHit]] = {t: None for t in _ALL_POI_TYPES}
    counts_1km: dict[str, int] = {t: 0 for t in _ALL_POI_TYPES}
    total_1km = 0

    for dist_km, poi in sorted(all_within, key=lambda x: x[0]):
        t = poi["poi_type"]
        if nearest.get(t) is None:
            nearest[t] = POIHit(
                poi_type=t,
                name=poi["name"],
                distance_m=int(round(dist_km * 1000)),
                lat=poi["lat"],
                lon=poi["lon"],
            )
        if dist_km <= 1.0:
            counts_1km[t] = counts_1km.get(t, 0) + 1
            total_1km += 1

    # Компоненты скора.
    components = {
        t: _distance_component(
            nearest[t].distance_m if nearest[t] else None,
            _DISTANCE_THRESHOLDS_M[t],
        )
        for t in _PRIMARY_POI_TYPES
    }
    components["poi_density"] = _density_component(total_1km)

    score = sum(components[k] * _SCORE_WEIGHTS[k] for k in _SCORE_WEIGHTS)
    score = max(0.0, min(1.0, score))

    # F3: добавляем breakdown по компонентам в ответ (для отладки + UI tooltip)
    breakdown = {k: round(v, 4) for k, v in components.items()}

    return LocationScore(
        lat=lat,
        lon=lon,
        nearest=nearest,
        poi_counts_1km=counts_1km,
        total_poi_within_1km=total_1km,
        score=round(score, 4),
        components=breakdown,
        computed_at=datetime.now(timezone.utc).isoformat(),
    )
