# frozen_string_literal: true

# == Schema Information
#
# Table name: property_valuation_embeddings
#
#  id                   :bigint   not null, primary key
#  property_valuation_id :bigint  not null (unique)
#  content_hash         :string   not null   # SHA256 of content_text — re-embed when changes
#  content_text         :text     not null   # The full template fed to gemini-embedding-001
#  embedding            :vector(768) not null
#  embedded_at          :datetime not null
#  created_at           :datetime not null
#  updated_at           :datetime not null
#
# HNSW index on embedding (cosine distance) — see migration 20261108120000.
#
# `has_neighbors :embedding` (from neighbor gem) exposes
# PropertyValuationEmbedding.nearest_neighbors(:embedding, query_vector, distance: :cosine).
#
# Re-embed trigger: PropertyValuation after_commit при переходе в completed.
# Backfill: `rake embeddings:valuations`.
class PropertyValuationEmbedding < ApplicationRecord
  has_neighbors :embedding

  belongs_to :property_valuation
end
