# frozen_string_literal: true

class TelegramNotifyJob < ApplicationJob
  queue_as :default

  def perform(conversation_id, summary)
    conv = Conversation.find_by(id: conversation_id)
    return unless conv

    Telegram::EscalationNotifier.new(conv, summary).call
  rescue StandardError => e
    Rails.logger.error("[TelegramNotifyJob] conversation ##{conversation_id}: #{e.class} #{e.message}")
  end
end
