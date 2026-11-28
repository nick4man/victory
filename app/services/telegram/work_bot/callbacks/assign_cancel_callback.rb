# frozen_string_literal: true

module Telegram
  module WorkBot
    module Callbacks
      # Клик по кнопке [✖️ Отмена] в picker-сообщении назначения.
      # callback_data: "assign_cancel:<lead_event_id>"
      class AssignCancelCallback < Base
        manager_only

        def handle
          delete_picker(lead_event)
          ack('Отменено')
        end

        private

        # Picker живёт в том чате, где нажали «Назначить»: с карточки
        # дашборда (issue #277) это DM руководителя, а не рабочая группа —
        # удалять надо там, иначе picker с живыми кнопками остаётся висеть,
        # а metadata уже очищена (ревью #280). Зеркалит AssignToCallback#delete_picker.
        def delete_picker(lead)
          msg = callback_query['message'] || {}
          chat_id = msg.dig('chat', 'id') || lead.tg_chat_id
          picker_id = msg['message_id'] || lead.metadata['assign_picker_message_id']
          return if picker_id.blank?

          begin
            client.delete_message(chat_id: chat_id, message_id: picker_id)
          rescue Telegram::Client::Error => e
            # Picker мог быть уже удалён — ключ из metadata всё равно чистим,
            # иначе следующий picker перезапишет его, а этот зависнет.
            Rails.logger.warn("[AssignCancelCallback] picker delete failed: #{e.message}")
          end
          lead.update!(metadata: lead.metadata.except('assign_picker_message_id'))
        end
      end
    end
  end
end
