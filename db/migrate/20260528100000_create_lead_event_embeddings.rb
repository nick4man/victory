# frozen_string_literal: true

# Phase 16.6 — semantic embeddings для LeadEvent. Pattern идентичен
# PropertyEmbedding + TelegramGroupMessageEmbedding (Phase 11 / 16.5):
#   • vector(768) — gemini-embedding-001 Matryoshka head
#   • content_hash SHA256 — skip re-embed когда не изменилось
#   • HNSW индекс с cosine distance
#
# Связь one-to-one с LeadEvent. Re-embed запускается after_commit когда
# metadata.summary / metadata.name / metadata.notes изменились.
class CreateLeadEventEmbeddings < ActiveRecord::Migration[7.1]
  def up
    enable_extension 'vector' unless extension_enabled?('vector')

    create_table :lead_event_embeddings do |t|
      t.references :lead_event, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.string   :content_hash, null: false, limit: 64
      t.datetime :embedded_at,  null: false
      t.timestamps
    end

    execute <<~SQL
      ALTER TABLE lead_event_embeddings
        ADD COLUMN embedding vector(768) NOT NULL;
    SQL

    execute <<~SQL
      CREATE INDEX idx_lead_event_embeddings_vector_hnsw
        ON lead_event_embeddings
        USING hnsw (embedding vector_cosine_ops)
        WITH (m = 16, ef_construction = 64);
    SQL
  end

  def down
    execute 'DROP INDEX IF EXISTS idx_lead_event_embeddings_vector_hnsw;'
    drop_table :lead_event_embeddings
  end
end
