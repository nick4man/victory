# frozen_string_literal: true

# == Schema Information
#
# Table name: property_embeddings
#
#  id           :bigint   not null, primary key
#  property_id  :bigint   not null (unique)
#  content_hash :string   not null   # SHA256 of content_text — re-embed when changes
#  content_text :text     not null   # The full template fed to gemini-embedding-001
#  embedding    :vector(768) not null
#  embedded_at  :datetime not null
#  created_at   :datetime not null
#  updated_at   :datetime not null
#
# HNSW index on embedding (cosine distance) — see migration 20260509211500.
#
# `has_neighbors :embedding` (from neighbor gem) exposes
# PropertyEmbedding.nearest_neighbors(:embedding, query_vector, distance: :cosine).
class PropertyEmbedding < ApplicationRecord
  has_neighbors :embedding

  belongs_to :property
end
