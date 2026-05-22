# frozen_string_literal: true

# Phase 16.5 — semantic embeddings для group messages (semantic search).
# Pattern идентичен PropertyEmbedding (миграция 20260509211500):
#   • vector(768) — Matryoshka-truncated gemini-embedding-001
#   • content_hash SHA256 для skip-if-unchanged re-embed
#   • HNSW индекс с cosine distance
#
# Связь one-to-one с TelegramGroupMessage. Re-embed запускается after_commit
# когда body меняется (хотя body обычно immutable — set on intake/backfill).
class CreateTelegramGroupMessageEmbeddings < ActiveRecord::Migration[7.1]
  def up
    enable_extension 'vector' unless extension_enabled?('vector')

    create_table :telegram_group_message_embeddings do |t|
      t.references :telegram_group_message, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.string   :content_hash, null: false, limit: 64
      t.datetime :embedded_at,  null: false
      t.timestamps
    end

    # Vector column через raw SQL — pgvector column type не support'ится
    # стандартными add_column DSL.
    execute <<~SQL
      ALTER TABLE telegram_group_message_embeddings
        ADD COLUMN embedding vector(768) NOT NULL;
    SQL

    # HNSW index с cosine distance — neighbor gem использует cosine_distance scope.
    # m=16, ef_construction=64 — defaults pgvector; ok для 1000-10000 rows.
    execute <<~SQL
      CREATE INDEX idx_tgm_embeddings_vector_hnsw
        ON telegram_group_message_embeddings
        USING hnsw (embedding vector_cosine_ops)
        WITH (m = 16, ef_construction = 64);
    SQL
  end

  def down
    execute 'DROP INDEX IF EXISTS idx_tgm_embeddings_vector_hnsw;'
    drop_table :telegram_group_message_embeddings
  end
end
