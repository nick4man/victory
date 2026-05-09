# frozen_string_literal: true

# We don't use the activerecord-postgis-adapter; the AR adapter remains
# `postgresql`. To silence "unknown OID" warnings for the geography(Point,
# 4326) column on properties.geom and districts.boundary, register both as
# plain strings (we read/write them as EWKT and never via Ruby objects).
#
# Reads return EWKB hex blobs; queries that need them as text use raw SQL
# (`ST_AsText(geom)` etc.) — never via attribute access.
Rails.application.config.to_prepare do
  ActiveSupport.on_load(:active_record) do
    if ActiveRecord::Base.connection.adapter_name.start_with?('PostgreSQL')
      ActiveRecord::Base.connection.exec_query(
        "SELECT oid, typname FROM pg_type WHERE typname IN ('geography', 'geometry')"
      ).rows.each do |oid, _name|
        ActiveRecord::Base.connection.send(:type_map).register_type(
          oid.to_i,
          ActiveModel::Type::String.new
        )
      end
    end
  rescue StandardError => e
    Rails.logger.warn("[postgis_types initializer] #{e.class}: #{e.message}")
  end
end
