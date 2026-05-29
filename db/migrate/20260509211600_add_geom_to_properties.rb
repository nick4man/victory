# frozen_string_literal: true

# Adds a PostGIS geography(Point, 4326) column to properties + GiST index +
# backfill from existing latitude/longitude. Property#within_radius is later
# rewritten to ST_DWithin against this column for accurate metric distances.
#
# Why geography (not geometry): PostGIS geography uses true earth-distance
# math (meters), so radius searches don't suffer from longitude-stretching
# at higher latitudes. Slightly slower than projected geometry but correct
# without per-region SRID picks.
class AddGeomToProperties < ActiveRecord::Migration[7.1]
  def up
    execute <<~SQL.squish
      ALTER TABLE properties
        ADD COLUMN geom geography(Point, 4326)
    SQL
    execute <<~SQL.squish
      CREATE INDEX idx_properties_geom_gist ON properties USING gist (geom)
    SQL
    execute <<~SQL.squish
      UPDATE properties
         SET geom = ST_SetSRID(ST_MakePoint(longitude::float8, latitude::float8), 4326)::geography
       WHERE latitude IS NOT NULL AND longitude IS NOT NULL
    SQL
  end

  def down
    execute 'DROP INDEX IF EXISTS idx_properties_geom_gist'
    execute 'ALTER TABLE properties DROP COLUMN IF EXISTS geom'
  end
end
