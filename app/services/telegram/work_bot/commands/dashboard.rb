# frozen_string_literal: true

module Telegram
  module WorkBot
    module Commands
      # Phase 15 — /dashboard команда для директора в DM.
      # Возвращает consolidated snapshot (4 секции + alerts + inline-drill кнопки).
      #
      # Manager+ only. Работает в DM и в group (если кто-то хочет полную сводку
      # в group чат), но primary use case — DM.
      class Dashboard < Base
        manager_only

        def handle
          result = Telegram::WorkBot::DirectorDashboard.new(tg_user: tg_user, period: :today).call

          @client.send_message(
            result.markdown,
            chat_id: @message.dig('chat', 'id'),
            reply_to_message_id: @message['message_id'],
            message_thread_id: @message['message_thread_id'],
            parse_mode: 'HTML',
            reply_markup: result.keyboard
          )
        end
      end
    end
  end
end
