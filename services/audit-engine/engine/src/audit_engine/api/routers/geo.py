"""Geo-query endpoints — PostGIS ST_DWithin / ST_Contains.

Дополняют `location.score` низкоуровневым доступом к POI:
* `GET /api/v2/geo/nearby` — POI в радиусе R от точки.
* `POST /api/v2/geo/in-polygon` — POI внутри произвольного полигона
  (`coords: [[lat, lon], ...]`, ≥ 3 точек, замыкание автодобавляется).

`points_of_interest.geom` — `geometry(Point, 4326)` с GIST-индексом.
"""
from __future__ import annotations

from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, Field
from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from audit_engine.api.deps import get_db


router = APIRouter(prefix="/geo", tags=["geo"])


class POI(BaseModel):
    id: int
    poi_type: str
    name: str
    latitude: float
    longitude: float
    distance_m: Optional[float] = None
    city: Optional[str] = None
    district: Optional[str] = None


class PolygonQuery(BaseModel):
    coords: list[tuple[float, float]] = Field(..., min_length=3, description="[(lat, lon), …] ≥ 3 точек")
    poi_type: Optional[str] = None
    limit: int = Field(500, ge=1, le=5000)


@router.get("/nearby", response_model=list[POI])
async def nearby(
    lat: float = Query(..., ge=-90.0, le=90.0),
    lon: float = Query(..., ge=-180.0, le=180.0),
    radius_km: float = Query(1.0, gt=0.0, le=20.0),
    poi_type: Optional[str] = Query(None, description="Фильтр по типу POI (school, metro, …)"),
    limit: int = Query(100, ge=1, le=1000),
    db: AsyncSession = Depends(get_db),
):
    """Список POI в радиусе `radius_km` от точки, с расстоянием в метрах.

    PostGIS: `ST_DWithin(geom::geography, ST_MakePoint(lon, lat)::geography, R)`.
    Сортировка по `ST_Distance` ASC.
    """
    radius_m = radius_km * 1000.0
    sql = (
        "SELECT id, poi_type, name, latitude, longitude, city, district, "
        "  ST_Distance(geom::geography, ST_SetSRID(ST_MakePoint(:lon, :lat), 4326)::geography) AS distance_m "
        "FROM points_of_interest "
        "WHERE geom IS NOT NULL "
        "  AND ST_DWithin("
        "    geom::geography, "
        "    ST_SetSRID(ST_MakePoint(:lon, :lat), 4326)::geography, "
        "    :radius_m"
        "  ) "
    )
    params = {"lat": lat, "lon": lon, "radius_m": radius_m, "limit": limit}
    if poi_type:
        sql += "  AND poi_type = :poi_type "
        params["poi_type"] = poi_type
    sql += "ORDER BY distance_m ASC LIMIT :limit"

    rows = (await db.execute(text(sql), params)).mappings().all()
    return [POI(**dict(r)) for r in rows]


@router.post("/in-polygon", response_model=list[POI])
async def in_polygon(query: PolygonQuery, db: AsyncSession = Depends(get_db)):
    """Список POI внутри полигона (lat, lon в WGS84).

    Полигон замыкается автоматически (первая точка дописывается в конец).
    PostGIS: `ST_Contains(ST_GeomFromText('POLYGON((…))', 4326), geom)`.
    """
    coords = list(query.coords)
    if len(coords) < 3:
        raise HTTPException(status_code=400, detail="Polygon needs ≥ 3 points")
    if coords[0] != coords[-1]:
        coords.append(coords[0])

    # WKT POLYGON((lon lat, lon lat, …))
    wkt_pts = ", ".join(f"{lon} {lat}" for lat, lon in coords)
    wkt = f"POLYGON(({wkt_pts}))"

    sql = (
        "SELECT id, poi_type, name, latitude, longitude, city, district "
        "FROM points_of_interest "
        "WHERE geom IS NOT NULL "
        "  AND ST_Contains(ST_GeomFromText(:wkt, 4326), geom) "
    )
    params: dict = {"wkt": wkt, "limit": query.limit}
    if query.poi_type:
        sql += "  AND poi_type = :poi_type "
        params["poi_type"] = query.poi_type
    sql += "LIMIT :limit"

    rows = (await db.execute(text(sql), params)).mappings().all()
    return [POI(**dict(r)) for r in rows]
