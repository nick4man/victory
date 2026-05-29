"""Загрузка POI из OpenStreetMap через Overpass API.

Использование:
    python -m scripts.load_poi_osm --city ryazan
    python -m scripts.load_poi_osm --bbox 54.55,39.60,54.72,39.85 --city-label "Рязань"
    python -m scripts.load_poi_osm --city moscow --types metro,school

Что делает:
1. Для каждого из 7 `poi_type` (metro, school, hospital, park, mall,
   kindergarten, university) формирует Overpass QL-запрос по bbox.
2. Раздёргивает ответ в tuple (name, poi_type, lat, lon, address).
3. Идемпотентный UPSERT в `points_of_interest` по натуральному ключу
   (poi_type, latitude, longitude, rounded до 5 знаков ≈ 1.1 м).

Колонка `geom` заполняется триггером `trg_poi_sync_geom` (миграция
g5b3d8f1a932), поэтому сам скрипт пишет только lat/lon.

Оффлайн-режим: передай `--input some.json` — пропустит HTTP и прочитает
dump Overpass из файла. Удобно для тестов/reproducibility.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import logging
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

logger = logging.getLogger("load_poi_osm")

OVERPASS_URL = "https://overpass-api.de/api/interpreter"
OVERPASS_TIMEOUT = 180
HTTP_TIMEOUT = 300

# Предзаданные bbox (south, west, north, east). Расширяются по запросу.
CITIES: dict[str, tuple[float, float, float, float]] = {
    "ryazan":  (54.55, 39.60, 54.73, 39.86),
    "moscow":  (55.48, 37.32, 55.96, 37.95),
    "spb":     (59.77, 30.08, 60.10, 30.58),
}

# Маппинг наших poi_type → Overpass-фильтры.
# Каждый poi_type = список фильтров (OR). Элемент: tag=value или tag~regex.
POI_TAGS: dict[str, list[str]] = {
    "metro":        ["railway=station[station=subway]", "railway=subway_entrance", "station=subway"],
    "school":       ["amenity=school"],
    "hospital":     ["amenity=hospital", "amenity=clinic"],
    "park":         ["leisure=park"],
    "mall":         ["shop=mall", "amenity=marketplace"],
    "kindergarten": ["amenity=kindergarten"],
    "university":   ["amenity=university", "amenity=college"],
}


@dataclass(frozen=True)
class POI:
    name: str
    poi_type: str
    latitude: float
    longitude: float
    address: str | None
    city: str | None
    osm_id: int | None
    raw_tags: dict


def build_overpass_query(
    bbox: tuple[float, float, float, float],
    poi_types: Iterable[str],
) -> str:
    """Собрать Overpass QL-запрос по bbox для указанных poi_type.

    Возвращает out center — берёт центроид для way/relation (не только node).
    """
    south, west, north, east = bbox
    filters: list[str] = []
    for ptype in poi_types:
        for spec in POI_TAGS.get(ptype, []):
            # spec = "amenity=school" или "railway=station[station=subway]"
            # Преобразуем в Overpass-фильтр: node/way/relation["amenity"="school"]
            if "[" in spec:
                main, extra = spec.split("[", 1)
                extra = "[" + extra  # оставляем как есть
            else:
                main, extra = spec, ""
            tag, val = main.split("=", 1)
            for elem in ("node", "way", "relation"):
                filters.append(
                    f'{elem}["{tag}"="{val}"]{extra}({south},{west},{north},{east});'
                )

    body = "\n  ".join(filters)
    return f"""[out:json][timeout:{OVERPASS_TIMEOUT}];
(
  {body}
);
out center tags;
""".strip()


def _infer_poi_type(tags: dict) -> str | None:
    """По тэгам OSM определить наш poi_type. Возвращает первый match."""
    if tags.get("railway") == "station" and tags.get("station") == "subway":
        return "metro"
    if tags.get("railway") == "subway_entrance":
        return "metro"
    if tags.get("station") == "subway":
        return "metro"

    amenity = tags.get("amenity")
    if amenity == "school":
        return "school"
    if amenity in ("hospital", "clinic"):
        return "hospital"
    if amenity == "kindergarten":
        return "kindergarten"
    if amenity in ("university", "college"):
        return "university"
    if amenity == "marketplace":
        return "mall"

    if tags.get("leisure") == "park":
        return "park"
    if tags.get("shop") == "mall":
        return "mall"
    return None


def _extract_address(tags: dict) -> str | None:
    parts = []
    for key in ("addr:street", "addr:housenumber", "addr:city"):
        v = tags.get(key)
        if v:
            parts.append(v)
    return ", ".join(parts) if parts else None


def parse_overpass_response(
    payload: dict,
    *,
    city_label: str | None,
) -> list[POI]:
    """Раздёргать ответ Overpass в список POI."""
    elements = payload.get("elements") or []
    out: list[POI] = []
    for el in elements:
        tags = el.get("tags") or {}
        poi_type = _infer_poi_type(tags)
        if not poi_type:
            continue
        name = tags.get("name") or tags.get("name:ru") or tags.get("official_name")
        if not name:
            continue
        if el.get("type") == "node":
            lat, lon = el.get("lat"), el.get("lon")
        else:
            center = el.get("center") or {}
            lat, lon = center.get("lat"), center.get("lon")
        if lat is None or lon is None:
            continue
        out.append(
            POI(
                name=str(name)[:255],
                poi_type=poi_type,
                latitude=round(float(lat), 7),
                longitude=round(float(lon), 7),
                address=_extract_address(tags),
                city=city_label,
                osm_id=el.get("id"),
                raw_tags=tags,
            )
        )
    return out


async def fetch_overpass(query: str) -> dict:
    import httpx

    logger.info("Overpass query: %d chars", len(query))
    async with httpx.AsyncClient(timeout=HTTP_TIMEOUT) as client:
        resp = await client.post(OVERPASS_URL, data={"data": query})
        resp.raise_for_status()
        return resp.json()


async def upsert_pois(session, pois: list[POI]) -> tuple[int, int]:
    """Вставить/обновить список POI. Возвращает (inserted, updated)."""
    from sqlalchemy import text

    inserted = 0
    updated = 0
    for poi in pois:
        existing = await session.execute(
            text(
                "SELECT id FROM points_of_interest "
                "WHERE poi_type = :pt "
                "  AND ROUND(latitude,  5) = ROUND(CAST(:lat AS numeric), 5) "
                "  AND ROUND(longitude, 5) = ROUND(CAST(:lon AS numeric), 5)"
            ),
            {"pt": poi.poi_type, "lat": poi.latitude, "lon": poi.longitude},
        )
        row = existing.first()
        params = {
            "name": poi.name,
            "pt": poi.poi_type,
            "lat": poi.latitude,
            "lon": poi.longitude,
            "addr": poi.address,
            "city": poi.city,
            "attrs": json.dumps(
                {"osm_id": poi.osm_id, "tags": poi.raw_tags}, ensure_ascii=False
            ),
            "src": "osm_overpass",
        }
        if row:
            await session.execute(
                text(
                    "UPDATE points_of_interest "
                    "SET name = :name, address = :addr, city = :city, "
                    "    attributes = CAST(:attrs AS jsonb), source = :src, "
                    "    updated_at = now() "
                    "WHERE id = :id"
                ),
                {**params, "id": row.id},
            )
            updated += 1
        else:
            await session.execute(
                text(
                    "INSERT INTO points_of_interest "
                    "(name, poi_type, latitude, longitude, address, city, "
                    " attributes, source) "
                    "VALUES (:name, :pt, :lat, :lon, :addr, :city, "
                    "        CAST(:attrs AS jsonb), :src)"
                ),
                params,
            )
            inserted += 1
    return inserted, updated


async def load(
    bbox: tuple[float, float, float, float],
    poi_types: list[str],
    city_label: str | None,
    *,
    input_file: Path | None = None,
    dry_run: bool = False,
) -> None:
    query = build_overpass_query(bbox, poi_types)
    if input_file:
        logger.info("Offline: читаю %s", input_file)
        payload = json.loads(input_file.read_text(encoding="utf-8"))
    else:
        payload = await fetch_overpass(query)

    pois = parse_overpass_response(payload, city_label=city_label)
    logger.info(
        "Получено %d элементов из Overpass, %d релевантных POI",
        len(payload.get("elements") or []), len(pois),
    )

    if dry_run:
        for p in pois[:20]:
            print(f"  [{p.poi_type:13s}] {p.latitude:.5f},{p.longitude:.5f}  {p.name}")
        if len(pois) > 20:
            print(f"  ... и ещё {len(pois) - 20}")
        return

    from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

    from audit_engine.config import settings

    async_url = settings.database_url.replace(
        "postgresql://", "postgresql+asyncpg://"
    )
    engine = create_async_engine(async_url, echo=False)
    Session = async_sessionmaker(engine, expire_on_commit=False)
    async with Session() as session:
        async with session.begin():
            inserted, updated = await upsert_pois(session, pois)
    logger.info("✅ POI загружены: +%d, обновлено %d", inserted, updated)


def _parse_bbox(s: str) -> tuple[float, float, float, float]:
    parts = [float(x) for x in s.split(",")]
    if len(parts) != 4:
        raise argparse.ArgumentTypeError("bbox должен быть south,west,north,east")
    return tuple(parts)  # type: ignore[return-value]


def main() -> int:
    logging.basicConfig(
        level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s"
    )
    ap = argparse.ArgumentParser(description=__doc__)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--city", choices=sorted(CITIES.keys()))
    g.add_argument("--bbox", type=_parse_bbox, help="south,west,north,east")
    ap.add_argument(
        "--types",
        default=",".join(sorted(POI_TAGS.keys())),
        help="Через запятую (по умолчанию все 7)",
    )
    ap.add_argument("--city-label", help="Название города для записи в `city` (если --bbox)")
    ap.add_argument(
        "--input", type=Path, help="Оффлайн: путь к JSON-dump от Overpass"
    )
    ap.add_argument("--dry-run", action="store_true", help="Не писать в БД")
    args = ap.parse_args()

    poi_types = [t.strip() for t in args.types.split(",") if t.strip()]
    bad = set(poi_types) - set(POI_TAGS.keys())
    if bad:
        print(f"Неизвестные poi_type: {bad}", file=sys.stderr)
        return 2

    if args.city:
        bbox = CITIES[args.city]
        label = args.city_label or args.city
    else:
        bbox = args.bbox
        label = args.city_label

    asyncio.run(
        load(
            bbox=bbox,
            poi_types=poi_types,
            city_label=label,
            input_file=args.input,
            dry_run=args.dry_run,
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
