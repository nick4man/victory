# frozen_string_literal: true

# Stores Google gemini-embedding-001 vectors for each property so the chatbot
# can do semantic search ("тихая квартира для семьи" → cosine-nearest objects).
#
# - vector(768) — 768 dim via the API's outputDimensionality parameter (MRL
#   truncation; full 3072 dim collapses to 768 with ~3% quality loss).
# - HNSW index with vector_cosine_ops — best for ≤100k rows, no training step.
# - content_hash lets us skip re-embedding when the source template is unchanged.
class CreatePropertyEmbeddings < ActiveRecord::Migration[7.1]
  def change
    create_table :property_embeddings do |t|
      t.references :property, null: false, foreign_key: true,
                              index: { unique: true }
      t.string  :content_hash, null: false, limit: 64
      t.text    :content_text, null: false
      t.column  :embedding, 'vector(768)', null: false
      t.datetime :embedded_at, null: false
      t.timestamps
    end

    # HNSW for cosine distance. m/ef_construction left at pgvector defaults
    # (16 / 64) — good balance of recall and build time for our scale.
    execute <<~SQL.squish
      CREATE INDEX idx_property_embeddings_cosine
        ON property_embeddings
        USING hnsw (embedding vector_cosine_ops)
    SQL
  end
end
