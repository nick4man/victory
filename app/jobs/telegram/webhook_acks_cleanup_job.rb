# frozen_string_literal: true

module Telegram
  # Phase 9 Iter 8 — Weekly cleanup TelegramWebhookAck rows старше 7 дней.
  # Telegram retries webhook'и в пределах нескольких часов; rows >7d можно
  # безопасно удалить чтобы предотвратить рост table.
  class WebhookAcksCleanupJob
    include Sidekiq::Job
    sidekiq_options queue: :scheduled, retry: 1

    def perform
      count = TelegramWebhookAck.stale.delete_all
      Rails.logger.info("[Telegram::WebhookAcksCleanupJob] deleted #{count} acks > 7d")
      { deleted: count }
    end
  end
end
