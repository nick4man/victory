# frozen_string_literal: true

# Phase 6 — news ingestion + soft-hide moderation. Adds the fields
# the /webhooks/news_ingest endpoint and the Admin UI rely on:
#   - external_id        — dedup key from chat-host (urgent_<ts>, digest_<ts>)
#   - external_source    — provenance tag (chat_urgent | chat_digest | manual | macro_snapshot)
#   - hidden_at          — soft-hide for moderator-flagged content
#   - metadata           — jsonb for hashtags, source URLs, ingest timestamps
class ExtendArticlesForIngest < ActiveRecord::Migration[7.1]
  def change
    add_column :articles, :external_id, :string
    add_column :articles, :external_source, :string
    add_column :articles, :hidden_at, :datetime
    add_column :articles, :metadata, :jsonb, default: {}, null: false

    add_index :articles, :external_id, unique: true, where: 'external_id IS NOT NULL'
    add_index :articles, :hidden_at
    add_index :articles, :metadata, using: :gin
  end
end
