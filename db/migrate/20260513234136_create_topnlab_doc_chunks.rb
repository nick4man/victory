# frozen_string_literal: true

# Phase 2B Item 7 — semantic search over Topnlab API documentation.
#
# Different shape from property/article_embeddings (which embed one record
# as one vector at the model level). Here we chunk markdown by H2 headers;
# each chunk is a row. Multiple rows per source file.
#
# Same Gemini gemini-embedding-001 model, 768-dim Matryoshka, HNSW + cosine.
class CreateTopnlabDocChunks < ActiveRecord::Migration[7.1]
  def change
    create_table :topnlab_doc_chunks do |t|
      t.string  :source_file,    null: false  # 'listings-and-mls.md', 'call-center.md', ...
      t.integer :chunk_index,    null: false  # 0-based position within the file
      t.string  :section_title              # e.g. '## 4. Получать объекты МЛС из Topnlab'
      t.integer :line_start                  # line number in the source markdown (best-effort)
      t.text    :chunk_text,     null: false # the text actually embedded
      t.string  :content_hash,   null: false # SHA256(chunk_text) — skip re-embed when unchanged
      t.column  :embedding, 'vector(768)', null: false
      t.datetime :embedded_at,   null: false
      t.timestamps

      t.index %i[source_file chunk_index], unique: true,
              name: 'idx_topnlab_doc_chunks_source_pos'
    end

    add_index :topnlab_doc_chunks, :embedding, using: :hnsw,
              opclass: :vector_cosine_ops, name: 'idx_topnlab_doc_chunks_cosine'
  end
end
