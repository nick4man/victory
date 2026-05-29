# frozen_string_literal: true

module Telegram
  module WorkBot
    # Phase 5.3 — Q&A в DM от staff. Agent в личном чате с ботом может
    # задать вопрос natural language — без /команды, без @mention.
    # Если known staff пишет в DM не-командное сообщение → StaffChatResponder.
    #
    # Trigger conditions:
    #   • chat.type='private'
    #   • from — known active TelegramUser
    #   • text present (не photo/voice/sticker)
    #   • НЕ /command (Router сам handle команды как было)
    #
    # Voice от directors routes через VoiceIntakeProcessor (Phase 7.2) — этот
    # handler не conflictует, идёт ПОСЛЕ voice check.
    #
    # WHY separate from QnaHandler:
    # QnaHandler требует supergroup + mention/ask. DM — другой context, не
    # нужен mention. Plus DM может быть высоким traffic (каждое staff сообщение
    # → LLM call) — отдельный handler позволяет добавить rate-limit specific
    # для DM позже.
    class DmQnaHandler
      def self.applies?(msg, tg_user = nil)
        return false unless msg.is_a?(Hash)
        return false unless msg.dig('chat', 'type') == 'private'

        text = msg['text'].to_s.strip
        return false if text.empty? || text.start_with?('/')

        from_id = msg.dig('from', 'id')
        return false if from_id.blank? || msg.dig('from', 'is_bot')

        tg_user ||= ::TelegramUser.find_by(tg_user_id: from_id)
        return false unless tg_user
        return false unless tg_user.status == 'active'

        true
      end

      def self.call(msg)
        new(msg).call
      end

      def initialize(msg, client: ::Telegram::Client.new)
        @msg = msg
        @client = client
      end

      def call
        from_id = @msg.dig('from', 'id')
        tg_user = ::TelegramUser.find_by(tg_user_id: from_id)
        return :no_tg_user unless tg_user

        question = @msg['text'].to_s.strip
        return :empty if question.empty?

        # Iter 61 (DM ack UX) — отправляем «💭 Принял, думаю…» ДО LLM-вызова.
        # StaffChatResponder может занять 5-30s при rate-limit на groq +
        # fallback chain на gemini-2.5-flash. Без ack пользователь видит
        # «бот молчит». ack_message_id хранится для edit-in-place финального
        # ответа (не плодим два сообщения). Pattern идентичен
        # VoiceIntakeProcessor.edit_ack.
        ack_msg = send_ack('💭 <i>Принял, думаю…</i>')
        @ack_message_id = ack_msg&.dig('message_id')

        result = Llm::StaffChatResponder.call(question: question, asked_by: tg_user, msg: @msg)
        deliver(format_answer(result))
        result
      rescue StandardError => e
        Rails.logger.error("[DmQnaHandler] #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
        deliver("⚠️ Внутренняя ошибка: #{e.message.to_s.truncate(120)}")
        :error
      end

      private

      def format_answer(result)
        return result.answer if result.success? && result.kind == 'escalation'

        suffix = []
        suffix << "<i>(#{result.used_tools.join(', ')})</i>" if result.used_tools&.any?
        [result.answer, *suffix].join("\n")
      end

      # Initial ack-сообщение (replies to user). Soft-fail — если не ушло,
      # @ack_message_id остаётся nil, deliver упадёт на fallback reply.
      def send_ack(text)
        @client.send_message(text,
                             chat_id: @msg.dig('chat', 'id'),
                             reply_to_message_id: @msg['message_id'],
                             parse_mode: 'HTML')
      rescue ::Telegram::Client::Error => e
        Rails.logger.warn("[DmQnaHandler#send_ack] #{e.message}")
        nil
      end

      # Финальная доставка: edit ack-сообщения in-place если есть; иначе reply.
      # Если edit упал (старое сообщение / TG 400) — fallback на reply.
      def deliver(text)
        return reply(text) if @ack_message_id.blank?

        @client.edit_message_text(text,
                                  chat_id: @msg.dig('chat', 'id'),
                                  message_id: @ack_message_id,
                                  parse_mode: 'HTML')
      rescue ::Telegram::Client::Error => e
        Rails.logger.warn("[DmQnaHandler#deliver] edit failed, fallback to reply: #{e.message}")
        reply(text)
      end

      def reply(text)
        @client.send_message(text,
                             chat_id: @msg.dig('chat', 'id'),
                             reply_to_message_id: @msg['message_id'],
                             parse_mode: 'HTML')
      end
    end
  end
end
