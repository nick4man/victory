# frozen_string_literal: true

require 'digest'

# Phase 16.5 — генерирует / обновляет gemini-embedding-001 вектор для
# TelegramGroupMessage. Skip если content_hash не изменился (re-embed
# cheap — но free tier API имеет 100 rpm rate-limit).
#
# Triggers:
#   • TelegramGroupMessage after_commit (если body present, ~5-10ms задержка)
#   • Backfill rake task `rake telegram:backfill_group_message_embeddings`
#
# Errors:
#   • GOOGLE_EMBEDDING_API_KEY не задан → запись skip + warn
#   • API rate limit / network → retry_on с polynomial backoff (до 5 попыток)
#   • Empty text (body blank после template) → skip silently
class EmbedTelegramGroupMessageJob < ApplicationJob
  queue_as :low_priority

  retry_on ::Embedding::GoogleClient::Error, wait: :polynomially_longer, attempts: 5

  def perform(message_id)
    message = TelegramGroupMessage.find_by(id: message_id)
    return unless message

    text = ::Embedding::TelegramGroupMessageTextTemplate.build(message)
    return if text.blank?

    hash = Digest::SHA256.hexdigest(text)

    record = TelegramGroupMessageEmbedding.find_or_initialize_by(telegram_group_message_id: message.id)
    if record.persisted? && record.content_hash == hash
      Rails.logger.debug("[EmbedTelegramGroupMessageJob] msg=#{message.id} unchanged, skip")
      return
    end

    vector = ::Embedding::GoogleClient.new.embed(text)

    record.update!(
      content_hash: hash,
      embedding:    vector,
      embedded_at:  Time.current
    )
  rescue ::Embedding::GoogleClient::Error => e
    raise # ловится retry_on
  rescue StandardError => e
    Rails.logger.warn("[EmbedTelegramGroupMessageJob] msg=#{message_id}: #{e.class} #{e.message}")
  end
end
