# frozen_string_literal: true

module Telegram
  module WorkBot
    module Callbacks
      # Клик по конкретному агенту в picker-сообщении («Кому назначить?»).
      # callback_data: "assign_to:<lead_event_id>:<telegram_user_id>"
      #
      # Делает реальное назначение через LeadAssignment-сервис, после чего
      # удаляет picker-сообщение (его id хранится в LeadEvent.metadata).
      class AssignToCallback < Base
        manager_only

        def handle
          lead     = lead_event
          assignee = TelegramUser.find_by(id: @args[1])
          return ack('⚠️ Сотрудник не найден', alert: true) unless assignee

          result = Telegram::WorkBot::LeadAssignment.new(lead, assignee: assignee, actor: tg_user, client: client).call

          delete_picker(lead)

          if result.success?
            text = "✅ Назначен: #{assignee.display_name}"
            text += " (#{result.error_message})" if result.error_message
            ack(text[0, 200])
          else
            ack("⚠️ #{result.error_message[0, 180]}", alert: true)
          end
        end

        private

        def delete_picker(lead)
          picker_id = lead.metadata['assign_picker_message_id']
          return if picker_id.blank?

          client.delete_message(chat_id: lead.tg_chat_id, message_id: picker_id)
          lead.update!(metadata: lead.metadata.except('assign_picker_message_id'))
        rescue Telegram::Client::Error => e
          Rails.logger.warn("[AssignToCallback] picker delete failed: #{e.message}")
        end
      end
    end
  end
end
