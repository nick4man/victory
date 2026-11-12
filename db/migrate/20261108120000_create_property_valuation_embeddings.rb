# frozen_string_literal: true

# Semantic embeddings для завершённых PropertyValuation (work_bot 2/3).
# Pattern идентичен PropertyEmbedding (Phase 11) / LeadEventEmbedding (Phase 16.6):
#   • vector(768) — gemini-embedding-001 Matryoshka head
#   • content_hash + content_text — skip re-embed когда шаблон не изменился
#   • HNSW индекс с cosine distance
#
# Назначение: LLM-инструменты (work_bot) находят похожие прошлые оценки
# по параметрам объекта — semantic nearest-neighbor по этой таблице.
class CreatePropertyValuationEmbeddings < ActiveRecord::Migration[7.1]
  def up
    create_table :property_valuation_embeddings do |t|
      t.references :property_valuation, null: false, foreign_key: { on_delete: :cascade },
                                        index: { unique: true }
      t.string   :content_hash, null: false, limit: 64
      t.text     :content_text, null: false
      t.column   :embedding, 'vector(768)', null: false
      t.datetime :embedded_at, null: false
      t.timestamps
    end

    execute <<~SQL.squish
      CREATE INDEX idx_property_valuation_embeddings_cosine
        ON property_valuation_embeddings
        USING hnsw (embedding vector_cosine_ops)
    SQL
  end

  def down
    execute 'DROP INDEX IF EXISTS idx_property_valuation_embeddings_cosine;'
    drop_table :property_valuation_embeddings
  end
end
