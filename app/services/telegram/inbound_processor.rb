# frozen_string_literal: true

module Telegram
  # Parses an inbound Telegram webhook update. The two paths we care about:
  #
  # 1. Reply-to-bot:
  #    Staff member long-presses one of our escalation messages and replies.
  #    update.message.reply_to_message.message_id matches Conversation.telegram_message_id
  #    → save ChatMessage(role: :agent), broadcast to widget.
  #
  # 2. Slash commands inside a conversation thread:
  #    /close, /assign — operate on the matched conversation.
  #
  # Anything else is logged and ignored (silent ack so Telegram doesn't retry).
  class InboundProcessor
    def initialize(payload)
      @update = payload.is_a?(Hash) ? payload : (JSON.parse(payload.to_s) rescue {})
    end

    def call
      msg = @update['message'] || @update['edited_message']
      return :ignored unless msg

      reply_to_id = msg.dig('reply_to_message', 'message_id')
      return log_and_ignore('no reply_to_message_id') if reply_to_id.blank?

      conv = Conversation.find_by(telegram_message_id: reply_to_id)
      return log_and_ignore("no conversation for tg_message_id=#{reply_to_id}") unless conv

      text = msg['text'].to_s.strip
      return :ignored if text.empty?

      return handle_command(conv, text, msg) if text.start_with?('/')

      handle_reply(conv, text, msg)
      :delivered
    rescue StandardError => e
      Rails.logger.error("[Telegram::InboundProcessor] #{e.class} #{e.message}")
      :error
    end

    private

    def handle_reply(conv, text, msg)
      author = resolve_author(msg)

      message = ChatMessage.create!(
        conversation:        conv,
        role:                :agent,
        body:                text,
        author:              author,
        telegram_message_id: msg['message_id']
      )

      ConversationChannel.broadcast_to(conv,
        type: 'message',
        message: serialize(message)
      )

      Rails.logger.info("[Telegram] agent reply ##{message.id} on conversation ##{conv.id}")
    end

    def handle_command(conv, text, _msg)
      cmd, *_args = text.split(/\s+/, 2)
      case cmd.downcase
      when '/close'
        conv.update(status: :closed)
        ChatMessage.create!(conversation: conv, role: :system,
                            body: 'Диалог закрыт сотрудником.')
        ConversationChannel.broadcast_to(conv, type: 'closed')
        :closed
      else
        log_and_ignore("unknown command #{cmd}")
      end
    end

    # Telegram users have no link to our User table by default. We fall back
    # to looking up by username if it matches a User#email prefix; otherwise
    # author stays nil and we record the Telegram username in metadata.
    def resolve_author(msg)
      from = msg['from'] || {}
      username = from['username'].to_s
      return nil if username.blank?
      User.where('LOWER(email) LIKE ?', "#{username.downcase}@%").first
    end

    def serialize(m)
      {
        id:         m.id,
        role:       m.role,
        body:       m.body,
        author:     m.author&.short_name,
        created_at: m.created_at.iso8601
      }
    end

    def log_and_ignore(reason)
      Rails.logger.info("[Telegram::InboundProcessor] ignored: #{reason}")
      :ignored
    end
  end
end
