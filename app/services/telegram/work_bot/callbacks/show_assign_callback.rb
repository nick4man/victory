# frozen_string_literal: true

module Telegram
  module WorkBot
    module Callbacks
      # BOTTLENECK — «кто поедет на показ». callback_data:
      # "show_assign:<lead_event_id>:<telegram_user_id>".
      #
      # Тёмный код стека C: кнопки появляются только при SHOW_ROUTING_ENABLED=true.
      # Назначенный попадает в lead.metadata['show_conductor_id'] — оттуда его
      # читает ShowReports::Intake#conductor_for, когда отчёт надиктует кто-то
      # другой.
      class ShowAssignCallback < Base
        def handle
          lead = lead_event
          return ack('🚫 Назначает assignee лида или руководитель', alert: true) unless authorized?(lead)

          conductor = TelegramUser.active.find_by(id: @args[1].to_i)
          return ack('⚠️ Сотрудник не найден или неактивен', alert: true) if conductor.nil?
          return ack("ℹ️ Уже назначен: #{conductor.display_name}") if lead.metadata['show_conductor_id'] == conductor.id

          lead.with_lock do
            lead.reload
            lead.update!(metadata: lead.metadata.merge('show_conductor_id' => conductor.id,
                                                       'show_conductor_set_at' => Time.current.iso8601,
                                                       'show_conductor_set_by' => actor_mention))
          end
          task = create_show_task(lead, conductor)
          dm_conductor(lead, conductor, task)
          strike_prompt("\n\n✅ Показывает <b>#{escape(conductor.display_name)}</b> (задача ##{task.id})")
          ack("✅ #{conductor.display_name}")
        end

        private

        def authorized?(lead)
          return false if tg_user.nil?

          lead.assigned_to_id == tg_user.id || tg_user.manager_or_director?
        end

        def create_show_task(lead, conductor)
          ::Task.create!(lead_event: lead, assignee: conductor, created_by: tg_user, kind: 'show', priority: 'normal',
                         status: 'open', title: "Показ: #{address(lead)}"[0, 255], assigned_at: Time.current)
        end

        def dm_conductor(lead, conductor, task)
          chat_id = conductor.dm_chat_id || conductor.tg_user_id
          return if chat_id.blank?

          text = "🏠 <b>Показ за тобой</b> — #{escape(address(lead))}\n" \
                 "Покупатель: #{escape(lead.metadata['name'].presence || "лид ##{lead.id}")} · #{lead.segment_label}\n" \
                 "После показа — голосовое боту или <code>/show #{lead.id} …</code>. Задача ##{task.id}."
          client.send_message(text, chat_id: chat_id, parse_mode: 'HTML')
        rescue Telegram::Client::Error => e
          Rails.logger.warn("[ShowAssignCallback] DM failed: #{e.message}")
        end

        def strike_prompt(suffix)
          msg = callback_query['message']
          return if msg.blank?

          client.edit_message_text("#{msg['text']}#{suffix}", chat_id: msg.dig('chat', 'id'), message_id: msg['message_id'],
                                                              parse_mode: 'HTML', reply_markup: { inline_keyboard: [] })
        rescue Telegram::Client::Error => e
          Rails.logger.warn("[ShowAssignCallback] edit failed: #{e.message}")
        end

        def address(lead)
          lead.property&.address.presence || "лид ##{lead.id}"
        end

        def escape(text)
          text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
        end
      end
    end
  end
end
