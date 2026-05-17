# frozen_string_literal: true

module Telegram
  module WorkBot
    # Phase 7.5 — Триггер для StaffChatResponder из #ВОПРОС/ОТВЕТ топика.
    #
    # MVP условия:
    #   1. chat.type='supergroup' AND chat.id = WORK_CHAT_ID
    #   2. message_thread_id == TopicRegistry.thread_id('qna')
    #   3. text mentions bot (@anvictorybot) ИЛИ начинается с /ask
    #   4. from — known TelegramUser (active staff)
    #
    # 2-min silence trigger (без mention) — Phase 7.5+ TODO. Сейчас MVP
    # требует explicit @mention чтобы избежать ложных срабатываний.
    #
    # На match → StaffChatResponder.call → reply в топик.
    class QnaHandler
      WORK_CHAT_ID = -1_003_779_115_845

      def self.applies?(msg)
        return false unless msg.is_a?(Hash)
        return false unless msg.dig('chat', 'id') == WORK_CHAT_ID
        return false unless msg.dig('chat', 'type') == 'supergroup'

        thread = msg['message_thread_id']
        qna_thread = Telegram::TopicRegistry.thread_id('qna')
        return false if thread.blank? || qna_thread.blank? || thread.to_i != qna_thread.to_i

        bot_mentioned?(msg) || text_starts_with_ask?(msg)
      end

      def self.bot_mentioned?(msg)
        # Telegram передаёт entities с type='mention' (для @username) или
        # 'text_mention' (для не-username профилей). Проверяем оба.
        bot_username = (ENV['TELEGRAM_BOT_USERNAME'] || 'anvictorybot').downcase
        text = msg['text'].to_s.downcase
        return true if text.include?("@#{bot_username}")

        Array(msg['entities']).any? do |e|
          e['type'] == 'mention' && text[e['offset'], e['length'].to_i].to_s.downcase == "@#{bot_username}"
        end
      end

      def self.text_starts_with_ask?(msg)
        msg['text'].to_s.strip.match?(%r{\A/ask(\s|@|\z)}i)
      end

      def initialize(msg, client: Telegram::Client.new)
        @msg    = msg
        @client = client
      end

      def call
        from_id = @msg.dig('from', 'id')
        tg_user = TelegramUser.find_by(tg_user_id: from_id)
        return refuse_unregistered(from_id) if tg_user.nil?
        return refuse_inactive(tg_user) unless tg_user.status == 'active'

        question = strip_mention(@msg['text'].to_s).strip
        return reply('Сформулируй вопрос после упоминания бота.') if question.empty?

        result = Llm::StaffChatResponder.call(question: question, asked_by: tg_user, msg: @msg)
        reply_text = format_answer(result)
        reply(reply_text)
        result
      rescue StandardError => e
        Rails.logger.error("[QnaHandler] #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
        reply("⚠️ Внутренняя ошибка: #{e.message.to_s.truncate(120)}")
        :error
      end

      private

      def strip_mention(text)
        bot_username = (ENV['TELEGRAM_BOT_USERNAME'] || 'anvictorybot').downcase
        text.gsub(/@#{Regexp.escape(bot_username)}/i, '').gsub(%r{\A/ask(@\S+)?\s*}i, '')
      end

      def format_answer(result)
        return result.answer if result.success? && result.kind == 'escalation'

        suffix = []
        suffix << "<i>(#{result.used_tools.join(', ')})</i>" if result.used_tools&.any?
        [result.answer, *suffix].join("\n")
      end

      def reply(text)
        @client.send_message(text,
                             chat_id: @msg.dig('chat', 'id'),
                             message_thread_id: @msg['message_thread_id'],
                             reply_to_message_id: @msg['message_id'],
                             parse_mode: 'HTML')
      end

      def refuse_unregistered(from_id)
        reply('🚫 Бот отвечает только сотрудникам АН. Привязка: <code>/whoami email@victory.ru</code>')
        Rails.logger.info("[QnaHandler] unregistered tg_user_id=#{from_id} mention в qna")
        :refused
      end

      def refuse_inactive(tg_user)
        reply("🚫 #{tg_user.mention}: твой статус <code>#{tg_user.status}</code> — нужна активация через manager'а (/promote).")
        :refused
      end
    end
  end
end
