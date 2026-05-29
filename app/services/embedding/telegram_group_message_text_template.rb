# frozen_string_literal: true

module Embedding
  # Phase 16.5 — text template для feed'инга TelegramGroupMessage в
  # gemini-embedding-001. Минималистичный — body + sender + topic context,
  # без noise (timestamps / ids — semantics, не fingerprint).
  #
  # @example
  #   text = Embedding::TelegramGroupMessageTextTemplate.build(msg)
  #   # => "От @oks07victory в КВАРТИРЫ: квартира 3-комн в Канищево..."
  module TelegramGroupMessageTextTemplate
    def self.build(message)
      return nil if message.body.to_s.strip.empty?

      sender = message.sender_username.presence || message.sender_first_name.presence || "сотрудник"
      topic = topic_label(message.tg_thread_id)

      prefix = "От @#{sender}"
      prefix += " в #{topic}" if topic

      "#{prefix}: #{message.body.to_s.strip}".truncate(2000)
    end

    def self.topic_label(thread_id)
      return nil if thread_id.blank?

      # Reverse TopicRegistry — найти key по thread_id, затем title
      key = ::Telegram::TopicRegistry.all_keys.find { |k| ::Telegram::TopicRegistry.thread_id(k) == thread_id }
      key && ::Telegram::TopicRegistry.title(key)
    rescue StandardError
      nil
    end
  end
end
