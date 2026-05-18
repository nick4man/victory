# frozen_string_literal: true

module Telegram
  module WorkBot
    # Сканер хэштегов в сообщениях рабочего чата.
    #
    # В Фазе 2 поддерживается ТОЛЬКО `#ахтунг` (красная кнопка — клиент уходит,
    # сделка срывается). Остальные `#отчет`/`#вопрос` придут в Phase 5
    # (требуют LLM-контекста).
    #
    # Что делает при #ахтунг:
    #   1. Ищет LeadEvent по reply_to_message.anchor_message_id (если reply на якорь)
    #   2. Помечает metadata['priority'] = 'high' → карточка теперь с префиксом ⚡
    #   3. Шлёт DM всем TelegramUser.managers со ссылкой на якорь
    #   4. Не блокирует обычную обработку сообщения — это side-effect handler
    class HashtagHandler
      AHTUNG_REGEX = /(?:\A|\s)#ахтунг(?:\s|\z|[[:punct:]])/i

      def initialize(message, client: Telegram::Client.new)
        @msg    = message.is_a?(Hash) ? message : {}
        @client = client
      end

      def call
        text = @msg['text'].to_s
        return :no_hashtag unless text.match?(AHTUNG_REGEX)

        lead = find_lead_via_reply
        # Phase 14 Iter 53 — wrap priority-flip + anchor edit в lock чтобы
        # параллельный #ахтунг + /stage не race'или mutation + edit.
        # Notify managers идёт outside lock (TG-calls долгие, не должны блокировать).
        if lead
          lead.with_lock do
            lead.reload
            mark_priority!(lead)
            edit_card_if_anchor(lead)
          end
        end
        notify_managers(lead, text)

        :handled
      rescue StandardError => e
        Rails.logger.error("[HashtagHandler] #{e.class}: #{e.message}")
        :error
      end

      private

      def find_lead_via_reply
        reply_to = @msg['reply_to_message']
        return nil unless reply_to

        LeadEvent.find_by(anchor_message_id: reply_to['message_id'])
      end

      def mark_priority!(lead)
        lead.update!(metadata: lead.metadata.merge('priority' => 'high', 'ahtung_at' => Time.current.iso8601))
      end

      def edit_card_if_anchor(lead)
        return if lead.blank? || lead.anchor_message_id.blank?

        text = LeadAnnouncer.new(lead, client: @client).format_card_text
        @client.edit_message_text(
          text,
          chat_id: lead.tg_chat_id,
          message_id: lead.anchor_message_id,
          parse_mode: 'HTML'
        )
      rescue StandardError => e
        Rails.logger.warn("[HashtagHandler] edit_message_text failed: #{e.message}")
      end

      def notify_managers(lead, original_text)
        managers = TelegramUser.managers.active
        return if managers.empty?

        author = @msg.dig('from', 'username').presence || @msg.dig('from', 'id').to_s
        topic  = lead ? "##{Telegram::TopicRegistry.title(lead.anchor_topic_key) || lead.anchor_topic_key}" : '(вне карточки лида)'
        anchor_link = lead ? "\n#{lead.anchor_url}" : ''

        dm_text = "🚨 <b>#ахтунг</b> от @#{escape(author)} в #{escape(topic)}\n" \
                  "<i>#{escape(original_text.to_s[0, 500])}</i>#{anchor_link}"

        managers.find_each do |mgr|
          chat_id = mgr.dm_chat_id || mgr.tg_user_id
          next if chat_id.blank?

          begin
            @client.send_message(dm_text, chat_id: chat_id, parse_mode: 'HTML')
          rescue Telegram::Client::Error => e
            Rails.logger.warn("[HashtagHandler] DM to #{mgr.mention} failed: #{e.message}")
          end
        end
      end

      def escape(text)
        text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
      end
    end
  end
end
