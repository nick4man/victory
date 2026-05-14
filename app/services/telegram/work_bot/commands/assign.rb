# frozen_string_literal: true

module Telegram
  module WorkBot
    module Commands
      # Текстовое назначение лида агенту: `/assign @ivan_petrov` reply на якорную карточку.
      # Альтернатива inline-кнопке [👤 Назначить] (см. Callbacks::AssignCallback).
      #
      # Manager-only — назначать может только руководитель.
      class Assign < Base
        manager_only

        def handle
          username = args.to_s.strip
          return reply('Формат: <code>/assign @username</code> (reply на якорную карточку лида).') if username.blank?

          lead = find_lead_via_reply
          return reply('⚠️ Команда должна быть reply на якорную карточку лида.') unless lead

          # rubocop:disable Rails/DynamicFindBy -- это наш custom class method, не Rails dynamic finder
          assignee = TelegramUser.find_by_username(username)
          # rubocop:enable Rails/DynamicFindBy
          return reply("⚠️ Сотрудник #{username} не зарегистрирован. Попроси его написать /whoami.") unless assignee

          result = Telegram::WorkBot::LeadAssignment.new(lead, assignee: assignee, actor: tg_user, client: client).call
          if result.success?
            reply("✅ Назначен: #{assignee.mention}")
          else
            reply("⚠️ #{result.error_message}")
          end
        end

        private

        def find_lead_via_reply
          reply_to = message['reply_to_message']
          return nil unless reply_to

          LeadEvent.find_by(anchor_message_id: reply_to['message_id'])
        end
      end
    end
  end
end
