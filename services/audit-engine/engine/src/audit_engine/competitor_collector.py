"""Чтение/запись снапшотов конкурентов в БД.

Собственно скрапинг CIAN/Avito вынесен в `data-collector/price_parsers/*`
и его cron-джоб (см. `jobs/competitor_refresh.py`). Этот модуль — тонкая
прослойка поверх `competitors` для чтения ретро-данных аналайзером и
записи снапшотов из scraper-ов.
"""
from __future__ import annotations

from datetime import date, datetime, timedelta
from typing import Any

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession

from audit_engine.geo import bounding_box, haversine_distance_km
from audit_engine.models import Competitor


async def fetch_competitors_by_complex(
    db: AsyncSession,
    complex_name: str,
    days_back: int = 90,
) -> list[Competitor]:
    """Свежие компы по названию ЖК за последние `days_back` дней."""
    cutoff = date.today() - timedelta(days=days_back)
    sql = text(
        """
        SELECT id, complex_name, snapshot_date, competitor_name,
               latitude, longitude, distance_m, price_total, price_per_sqm,
               area_sqm, rooms, property_type, source, url, scraped_at
        FROM competitors
        WHERE complex_name = :name
          AND snapshot_date >= :cutoff
        ORDER BY snapshot_date DESC, price_per_sqm ASC
        """
    )
    result = await db.execute(sql, {"name": complex_name, "cutoff": cutoff})
    rows = result.fetchall()
    return [_row_to_model(r) for r in rows]


async def fetch_competitors_by_radius(
    db: AsyncSession,
    lat: float,
    lon: float,
    radius_m: int = 2000,
    days_back: int = 90,
    property_type: str | None = None,
) -> list[Competitor]:
    """Компы в радиусе `radius_m` метров от точки (lat, lon).

    Сначала bbox-префильтр по SQL, затем точная haversine-фильтрация в
    памяти. При наличии у компа координат проставляется актуальное
    `distance_m` до аудитной точки (если координаты отсутствуют — оставляем
    тот distance_m, что сохранён в БД, либо None).
    """
    radius_km = radius_m / 1000.0
    mnlat, mxlat, mnlon, mxlon = bounding_box(lat, lon, radius_km)
    cutoff = date.today() - timedelta(days=days_back)

    params: dict[str, Any] = {
        "mnlat": mnlat, "mxlat": mxlat,
        "mnlon": mnlon, "mxlon": mxlon,
        "cutoff": cutoff,
    }
    ptype_clause = ""
    if property_type:
        ptype_clause = " AND property_type = :ptype"
        params["ptype"] = property_type

    sql = text(
        f"""
        SELECT id, complex_name, snapshot_date, competitor_name,
               latitude, longitude, distance_m, price_total, price_per_sqm,
               area_sqm, rooms, property_type, source, url, scraped_at
        FROM competitors
        WHERE latitude BETWEEN :mnlat AND :mxlat
          AND longitude BETWEEN :mnlon AND :mxlon
          AND snapshot_date >= :cutoff
          {ptype_clause}
        """
    )
    result = await db.execute(sql, params)
    rows = result.fetchall()

    competitors: list[Competitor] = []
    for row in rows:
        comp = _row_to_model(row)
        if comp.latitude is not None and comp.longitude is not None:
            dist_km = haversine_distance_km(lat, lon, comp.latitude, comp.longitude)
            if dist_km * 1000.0 > radius_m:
                continue
            comp.distance_m = int(round(dist_km * 1000.0))
        competitors.append(comp)
    competitors.sort(key=lambda c: (c.distance_m if c.distance_m is not None else 10**9))
    return competitors


async def store_competitor_snapshot(
    db: AsyncSession,
    competitor: Competitor,
) -> None:
    """Вставить снапшот компа. Дедупликация лежит на вызывающем скрапере
    (через `(source, url, snapshot_date)`)."""
    sql = text(
        """
        INSERT INTO competitors (
            complex_name, snapshot_date, competitor_name,
            latitude, longitude, distance_m, price_total, price_per_sqm,
            area_sqm, rooms, property_type, source, url, scraped_at
        ) VALUES (
            :complex_name, :snapshot_date, :competitor_name,
            :latitude, :longitude, :distance_m, :price_total, :price_per_sqm,
            :area_sqm, :rooms, :property_type, :source, :url, :scraped_at
        )
        """
    )
    await db.execute(
        sql,
        {
            "complex_name": competitor.complex_name,
            "snapshot_date": competitor.snapshot_date,
            "competitor_name": competitor.competitor_name,
            "latitude": competitor.latitude,
            "longitude": competitor.longitude,
            "distance_m": competitor.distance_m,
            "price_total": competitor.price_total,
            "price_per_sqm": competitor.price_per_sqm,
            "area_sqm": competitor.area_sqm,
            "rooms": competitor.rooms,
            "property_type": competitor.property_type,
            "source": competitor.source,
            "url": competitor.url,
            "scraped_at": competitor.scraped_at or datetime.utcnow().isoformat(),
        },
    )


def _row_to_model(row: Any) -> Competitor:
    m = row._mapping
    scraped = m.get("scraped_at")
    return Competitor(
        id=m.get("id"),
        complex_name=m["complex_name"],
        snapshot_date=m["snapshot_date"],
        competitor_name=m["competitor_name"],
        latitude=float(m["latitude"]) if m.get("latitude") is not None else None,
        longitude=float(m["longitude"]) if m.get("longitude") is not None else None,
        distance_m=int(m["distance_m"]) if m.get("distance_m") is not None else None,
        price_total=float(m["price_total"]) if m.get("price_total") is not None else None,
        price_per_sqm=float(m["price_per_sqm"]),
        area_sqm=float(m["area_sqm"]) if m.get("area_sqm") is not None else None,
        rooms=int(m["rooms"]) if m.get("rooms") is not None else None,
        property_type=m.get("property_type") or "APARTMENT",
        source=m["source"],
        url=m.get("url"),
        scraped_at=scraped.isoformat() if hasattr(scraped, "isoformat") else scraped,
    )
