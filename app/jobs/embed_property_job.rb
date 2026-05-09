# frozen_string_literal: true

require 'digest'

# Generates / refreshes the gemini-embedding-001 vector for a Property.
# Skips work if the template text has not changed (content_hash match).
#
# Triggers:
#   * Property after_commit when relevant fields changed (see Property#enqueue_embed_if_changed)
#   * End of TopnlabPropertyImportJob after photo sync
#   * `rake embeddings:backfill` for one-shot bulk
class EmbedPropertyJob < ApplicationJob
  queue_as :low_priority

  # Don't retry forever on permanent 4xx (e.g. invalid API key).
  retry_on Embedding::GoogleClient::Error, wait: :polynomially_longer, attempts: 5

  def perform(property_id)
    property = Property.unscoped.find_by(id: property_id)
    return unless property

    text = Embedding::PropertyTextTemplate.build(property)
    return if text.blank?

    hash = Digest::SHA256.hexdigest(text)

    record = PropertyEmbedding.find_or_initialize_by(property_id: property.id)
    if record.persisted? && record.content_hash == hash
      Rails.logger.debug("[EmbedPropertyJob] property=#{property.id} unchanged, skip")
      return
    end

    vector = Embedding::GoogleClient.new.embed(text)

    record.update!(
      content_hash: hash,
      content_text: text,
      embedding:    vector,
      embedded_at:  Time.current
    )
    Rails.logger.info("[EmbedPropertyJob] embedded property=#{property.id} dim=#{vector.size}")
  end
end
