# frozen_string_literal: true

# == Schema Information
#
# Table name: article_embeddings
#
#  id           :bigint   not null, primary key
#  article_id   :bigint   not null (unique)
#  content_hash :string   not null   # SHA256 of content_text — re-embed when changes
#  content_text :text     not null   # The full template fed to gemini-embedding-001
#  embedding    :vector(768) not null
#  embedded_at  :datetime not null
#  created_at   :datetime not null
#  updated_at   :datetime not null
#
# HNSW index on embedding (cosine distance) — see migration 20260513000000.
#
# `has_neighbors :embedding` exposes
# ArticleEmbedding.nearest_neighbors(:embedding, query_vector, distance: :cosine).
class ArticleEmbedding < ApplicationRecord
  has_neighbors :embedding

  belongs_to :article
end
