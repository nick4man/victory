# frozen_string_literal: true

# Polygon boundaries for city districts (Воронеж first, others later).
# Used by the chatbot tool find_in_district_polygon to filter properties via
# ST_Within against the boundary, instead of relying on the (sometimes stale)
# free-text properties.district column.
#
# Loading is decoupled from this migration — table is created empty;
# populate via `rake districts:import_voronezh`.
class CreateDistricts < ActiveRecord::Migration[7.1]
  def up
    execute <<~SQL.squish
      CREATE TABLE districts (
        id          bigserial PRIMARY KEY,
        name        varchar NOT NULL,
        city        varchar,
        boundary    geometry(MultiPolygon, 4326) NOT NULL,
        created_at  timestamp(6) NOT NULL,
        updated_at  timestamp(6) NOT NULL
      )
    SQL
    execute <<~SQL.squish
      CREATE INDEX idx_districts_boundary_gist
        ON districts USING gist (boundary)
    SQL
    execute <<~SQL.squish
      CREATE UNIQUE INDEX idx_districts_city_name
        ON districts (city, name)
    SQL
  end

  def down
    execute 'DROP TABLE IF EXISTS districts'
  end
end
