# frozen_string_literal: true

# Phase 7 — article embeddings for semantic "related" suggestions on /news/:slug.
# Mirrors property_embeddings (Phase 1) — same gemini-embedding-001 model
# (768-dim Matryoshka truncation), same HNSW cosine index, same content_hash
# skip-if-unchanged pattern.
class CreateArticleEmbeddings < ActiveRecord::Migration[7.1]
  def change
    create_table :article_embeddings do |t|
      t.references :article, null: false, foreign_key: true, index: { unique: true }
      t.string  :content_hash, null: false
      t.text    :content_text, null: false
      t.column  :embedding, 'vector(768)', null: false
      t.datetime :embedded_at, null: false
      t.timestamps
    end

    add_index :article_embeddings, :embedding, using: :hnsw,
              opclass: :vector_cosine_ops, name: 'idx_article_embeddings_cosine'
  end
end
