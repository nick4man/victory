# frozen_string_literal: true

# Enables Postgres extensions used by the AI chatbot:
#   * vector   — pgvector for semantic property search.
#   * pg_trgm  — trigram similarity (fuzzy match on districts/streets).
#   * unaccent — accent-stripped ILIKE comparisons.
#   * postgis  — geography columns and ST_DWithin / ST_Within radius queries.
#
# The custom postgis-pgvector image (Dockerfile.postgres) ships the underlying
# .so files; this migration just CREATEs the extensions in this database.
class EnableSearchExtensions < ActiveRecord::Migration[7.1]
  def change
    enable_extension 'vector'
    enable_extension 'pg_trgm'
    enable_extension 'unaccent'
    enable_extension 'postgis'
  end
end
