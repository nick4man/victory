# frozen_string_literal: true

# Phase 16.5 — semantic embedding для TelegramGroupMessage.
# Pattern from PropertyEmbedding (Phase 11 semantic search infra).
#
# Storage: vector(768) — gemini-embedding-001 Matryoshka-truncated head
# (95% качества vs full 3072d при 4x меньше index size). HNSW cosine index
# = sub-millisecond similarity search на 10K+ rows.
#
# Use cases:
#   • «найди похожие сообщения на это» — semantic find
#   • SearchGroupMessages mode='semantic' — alternative к tsvector FTS,
#     лучше для concept queries («трудности с подписанием» vs точный текст)
#   • Lead duplicate detection — semantic match similar inquiries
#
# Re-embed: after_commit hook на TelegramGroupMessage если body изменился
# (обычно immutable — set on intake / backfill; но защита есть).
class TelegramGroupMessageEmbedding < ApplicationRecord
  has_neighbors :embedding

  belongs_to :telegram_group_message
end
