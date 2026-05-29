# frozen_string_literal: true

require 'digest'

# Phase 16.6 — генерирует / обновляет gemini-embedding-001 вектор для
# LeadEvent. Skip если content_hash не изменился (re-embed cheap, но Google
# free tier — 100 rpm).
#
# Triggers:
#   • LeadEvent after_commit on create/update если metadata-relevant fields
#     изменились (name / summary / notes / stage / topic)
#   • Backfill rake task `rake telegram:backfill_lead_event_embeddings`
class EmbedLeadEventJob < ApplicationJob
  queue_as :low_priority

  retry_on ::Embedding::GoogleClient::Error, wait: :polynomially_longer, attempts: 5

  def perform(lead_event_id)
    le = LeadEvent.find_by(id: lead_event_id)
    return unless le

    text = ::Embedding::LeadEventTextTemplate.build(le)
    return if text.blank?

    hash = Digest::SHA256.hexdigest(text)

    record = LeadEventEmbedding.find_or_initialize_by(lead_event_id: le.id)
    if record.persisted? && record.content_hash == hash
      Rails.logger.debug("[EmbedLeadEventJob] le=#{le.id} unchanged, skip")
      return
    end

    vector = ::Embedding::GoogleClient.new.embed(text)

    record.update!(
      content_hash: hash,
      embedding:    vector,
      embedded_at:  Time.current
    )
  rescue ::Embedding::GoogleClient::Error => e
    raise # retry_on
  rescue StandardError => e
    Rails.logger.warn("[EmbedLeadEventJob] le=#{lead_event_id}: #{e.class} #{e.message}")
  end
end
