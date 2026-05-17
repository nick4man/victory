# frozen_string_literal: true

module Telegram
  module WorkBot
    module Callbacks
      # Нажатие кнопки [👤 Назначить] под якорной карточкой.
      # callback_data: "assign:<lead_event_id>"
      #
      # Эффект: бот постит в тот же топик новое сообщение «Кому назначить?» с
      # inline-кнопками per-агент (callback_data "assign_to:<lead>:<user_id>").
      # ID этого picker-сообщения сохраняется в LeadEvent.metadata['assign_picker_message_id']
      # — чтобы AssignToCallback мог его удалить после выбора.
      class AssignCallback < Base
        manager_only

        MAX_USERS = 10
        BUTTONS_PER_ROW = 2

        def handle
          lead = lead_event
          users = TelegramUser.assignable.where.not(id: lead.assigned_to_id).limit(MAX_USERS).order(:tg_username)
          return ack('Нет активных сотрудников для назначения.', alert: true) if users.empty?

          msg = callback_query['message'] || {}
          chat_id   = msg.dig('chat', 'id')
          thread_id = msg['message_thread_id']

          buttons = users.map do |u|
            { text: "👤 #{u.display_name}", callback_data: "assign_to:#{lead.id}:#{u.id}" }
          end
          rows = buttons.each_slice(BUTTONS_PER_ROW).to_a
          rows << [{ text: '✖️ Отмена', callback_data: "assign_cancel:#{lead.id}" }]

          picker = client.send_message(
            "Кому назначить лид ##{lead.id}?",
            chat_id: chat_id,
            message_thread_id: thread_id,
            reply_markup: { inline_keyboard: rows },
            parse_mode: 'HTML'
          )

          if picker.is_a?(Hash) && picker['message_id']
            lead.update!(metadata: lead.metadata.merge('assign_picker_message_id' => picker['message_id']))
          end

          ack
        end
      end
    end
  end
end
