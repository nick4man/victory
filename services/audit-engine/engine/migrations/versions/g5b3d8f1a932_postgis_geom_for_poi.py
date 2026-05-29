"""PostGIS geom column + trigger for points_of_interest

Revision ID: g5b3d8f1a932
Revises: f4a2c7b9e821
Create Date: 2026-04-24 00:00:00.000000

Исправляет существующий разрыв: `location_scorer.score_location()` запрашивает
колонку `geom` и использует `ST_DistanceSphere` / `ST_DWithin`, но прошлая
миграция `e3b1f0a9c210` создала только `latitude/longitude` (Numeric).

Что делает:
- CREATE EXTENSION postgis (idempotent).
- ALTER TABLE points_of_interest ADD COLUMN geom geometry(Point, 4326).
- Backfill: UPDATE ... SET geom = ST_SetSRID(ST_MakePoint(longitude, latitude), 4326).
- GIST-индекс на geom.
- Trigger BEFORE INSERT/UPDATE OF latitude, longitude: перестраивает geom
  из lat/lon, чтобы загружающие скрипты (scripts/load_poi_osm.py,
  ручной INSERT) не обязаны были писать ST_MakePoint вручную.

Downgrade: снимает trigger, индекс, колонку. Extension не трогаем —
могут использовать другие таблицы.
"""
from typing import Sequence, Union

from alembic import op


revision: str = "g5b3d8f1a932"
down_revision: Union[str, Sequence[str], None] = "f4a2c7b9e821"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.execute("CREATE EXTENSION IF NOT EXISTS postgis")
    op.execute(
        "ALTER TABLE points_of_interest "
        "ADD COLUMN IF NOT EXISTS geom geometry(Point, 4326)"
    )
    op.execute(
        "UPDATE points_of_interest "
        "SET geom = ST_SetSRID(ST_MakePoint(longitude::double precision, "
        "                                    latitude::double precision), 4326) "
        "WHERE geom IS NULL"
    )
    op.execute(
        "CREATE INDEX IF NOT EXISTS idx_poi_geom "
        "ON points_of_interest USING GIST (geom)"
    )
    op.execute(
        """
        CREATE OR REPLACE FUNCTION poi_sync_geom() RETURNS trigger AS $$
        BEGIN
            NEW.geom := ST_SetSRID(
                ST_MakePoint(NEW.longitude::double precision,
                             NEW.latitude::double precision),
                4326
            );
            RETURN NEW;
        END;
        $$ LANGUAGE plpgsql
        """
    )
    op.execute("DROP TRIGGER IF EXISTS trg_poi_sync_geom ON points_of_interest")
    op.execute(
        """
        CREATE TRIGGER trg_poi_sync_geom
        BEFORE INSERT OR UPDATE OF latitude, longitude
        ON points_of_interest
        FOR EACH ROW
        EXECUTE FUNCTION poi_sync_geom()
        """
    )


def downgrade() -> None:
    op.execute("DROP TRIGGER IF EXISTS trg_poi_sync_geom ON points_of_interest")
    op.execute("DROP FUNCTION IF EXISTS poi_sync_geom()")
    op.execute("DROP INDEX IF EXISTS idx_poi_geom")
    op.execute("ALTER TABLE points_of_interest DROP COLUMN IF EXISTS geom")
