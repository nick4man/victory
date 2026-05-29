# frozen_string_literal: true

module Telegram
  module WorkBot
    module Callbacks
      # Клик по кнопке [✖️ Отмена] в picker-сообщении назначения.
      # callback_data: "assign_cancel:<lead_event_id>"
      class AssignCancelCallback < Base
        manager_only

        def handle
          lead = lead_event
          picker_id = lead.metadata['assign_picker_message_id']
          if picker_id.present?
            begin
              client.delete_message(chat_id: lead.tg_chat_id, message_id: picker_id)
            rescue Telegram::Client::Error => e
              Rails.logger.warn("[AssignCancel] delete failed: #{e.message}")
            end
            lead.update!(metadata: lead.metadata.except('assign_picker_message_id'))
          end
          ack('Отменено')
        end
      end
    end
  end
end
