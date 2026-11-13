# frozen_string_literal: true

module Telegram
  # When a Conversation transitions to `escalated`, posts a structured
  # message to the staff Telegram group and stores the resulting
  # message_id on the Conversation so future replies (Reply-to in TG)
  # can be matched back to the right conversation.
  class EscalationNotifier
    MAX_HISTORY_PREVIEW = 6

    def initialize(conversation, summary, client: Telegram::Client.new)
      @conv    = conversation
      @summary = summary.to_s
      @client  = client
    end

    def call
      chat_id = target_chat_id
      return nil if chat_id.blank?

      result = @client.send_message(format_message, chat_id: chat_id, parse_mode: 'HTML')

      @conv.update(
        telegram_chat_id:    result.dig('chat', 'id'),
        telegram_message_id: result['message_id']
      )

      result
    end

    private

    # Тест-режим чат-бота (issue #214): probe-диалог эскалирует в тестовый
    # чат, а не в рабочий staff-chat. Без TELEGRAM_TEST_CHAT_ID — пропуск с
    # warning: рабочая группа не трогается.
    def target_chat_id
      unless @conv.respond_to?(:test_probe?) && @conv.test_probe?
        chat_id = ENV['TELEGRAM_STAFF_CHAT_ID']
        raise Telegram::Client::Error, 'TELEGRAM_STAFF_CHAT_ID not set' if chat_id.blank?
        return chat_id
      end

      test_chat = ENV['TELEGRAM_TEST_CHAT_ID'].presence
      Rails.logger.warn("[EscalationNotifier] conversation=#{@conv.id} test probe, TELEGRAM_TEST_CHAT_ID не задан — пропуск") if test_chat.blank?
      test_chat&.to_i
    end

    def format_message
      lines = []
      title = "🆕 <b>Новая заявка #{@conv.id}</b>"
      title = "🧪 ТЕСТ · #{title}" if @conv.respond_to?(:test_probe?) && @conv.test_probe?
      lines << title
      lines << ''
      lines << "👤 #{escape(@conv.display_name)}#{phone_line}#{email_line}"
      lines << '🌐 Источник: чат на сайте'

      if @summary.present?
        lines << ''
        lines << '📝 <b>Контекст:</b>'
        lines << escape(@summary)
      end

      preview = @conv.chat_messages.last(MAX_HISTORY_PREVIEW)
      if preview.any?
        lines << ''
        lines << '💬 <b>Последние сообщения:</b>'
        preview.each do |m|
          icon = role_icon(m.role)
          lines << "#{icon} #{escape(m.body.to_s.truncate(280))}"
        end
      end

      lines << ''
      lines << '▶️ <i>Ответьте на это сообщение — клиент получит ответ в чате.</i>'
      lines.join("\n")
    end

    def phone_line
      @conv.phone.present? ? " · #{escape(@conv.phone)}" : ''
    end

    def email_line
      @conv.email.present? ? " · #{escape(@conv.email)}" : ''
    end

    def role_icon(role)
      case role
      when 'user'      then '👤'
      when 'assistant' then '🤖'
      when 'agent'     then '👨‍💼'
      else                  '⚙️'
      end
    end

    # Telegram HTML mode requires escaping these three characters.
    def escape(text)
      text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
    end
  end
end
