# frozen_string_literal: true

module Telegram
  module WorkBot
    module Commands
      # Назначение лида агенту.
      #   • В group: `/assign @user` reply на якорную карточку
      #   • В DM (Phase 15): `/assign <lead_id> @user` — explicit lead_id первым
      #     ИЛИ `/assign <lead_id>` (без user) → inline picker с top-10 staff
      # Manager-only.
      class Assign < Base
        manager_only

        PICKER_MAX_USERS = 10
        PICKER_BUTTONS_PER_ROW = 2

        def handle
          # Phase 15 — resolve_lead! сначала «съест» lead_id если он есть в @args.
          # После этого @args содержит только username (или пусто).
          lead = resolve_lead!
          return reply(lead_not_found_hint('assign')) unless lead

          username = @args.to_s.strip

          # Phase 15 polish — если username пустой, показываем inline picker
          # (как AssignCallback в group). UX-консистенция: DM пользователь
          # пишет /assign 87 → видит кнопки top-10 staff.
          if username.blank?
            return render_picker(lead)
          end

          # rubocop:disable Rails/DynamicFindBy -- custom class method, не Rails dynamic finder
          assignee = TelegramUser.find_by_username(username)
          # rubocop:enable Rails/DynamicFindBy
          return reply("⚠️ Сотрудник #{username} не зарегистрирован. Попроси его написать /whoami.") unless assignee

          result = Telegram::WorkBot::LeadAssignment.new(lead, assignee: assignee, actor: tg_user, client: client).call
          if result.success?
            msg = "✅ Лид ##{lead.id} → #{assignee.mention}"
            msg += " <i>(#{result.error_message})</i>" if result.error_message
            reply(msg)
          else
            reply("⚠️ #{result.error_message}")
          end
        end

        private

        # Phase 15 polish — picker для DM-mode /assign без username.
        # Логика идентична Callbacks::AssignCallback#handle (тот же
        # callback_data `assign_to:<lead_id>:<user_id>`), но триггерится
        # из command-context (без callback_query).
        def render_picker(lead)
          # NULL-safe ordering — staff без tg_username (Надежда) в конец списка.
          users = TelegramUser.assignable
                              .where.not(id: lead.assigned_to_id)
                              .order(Arel.sql('CASE WHEN tg_username IS NULL THEN 1 ELSE 0 END'), :tg_username, :id)
                              .limit(PICKER_MAX_USERS)
          return reply('⚠️ Нет активных сотрудников для назначения.') if users.empty?

          buttons = users.map do |u|
            { text: "👤 #{u.display_name}", callback_data: "assign_to:#{lead.id}:#{u.id}" }
          end
          rows = buttons.each_slice(PICKER_BUTTONS_PER_ROW).to_a
          rows << [{ text: '✖️ Отмена', callback_data: "assign_cancel:#{lead.id}" }]

          picker = @client.send_message(
            "Кому назначить лид ##{lead.id}?",
            chat_id: @message.dig('chat', 'id'),
            reply_to_message_id: @message['message_id'],
            message_thread_id: @message['message_thread_id'],
            reply_markup: { inline_keyboard: rows },
            parse_mode: 'HTML'
          )

          if picker.is_a?(Hash) && picker['message_id']
            lead.update!(metadata: lead.metadata.merge('assign_picker_message_id' => picker['message_id']))
          end
        end
      end
    end
  end
end
