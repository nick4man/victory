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
          unless assignee
            log_soft_error('assignee_not_found', "lead=#{lead&.id} args=#{@args.inspect}")
            return ack('⚠️ Сотрудник не найден', alert: true)
          end

          # Phase 11 Iter 29 — capture audit trail (prev assignee) BEFORE call.
          # Iter 22 handles DM to prev; here мы фиксируем структурированный
          # audit-log для observability + future KPI (reassignment frequency).
          prev_assignee = lead.assigned_to
          log_reassignment_audit(lead, prev_assignee, assignee)

          result = Telegram::WorkBot::LeadAssignment.new(lead, assignee: assignee, actor: tg_user, client: client).call

          delete_picker(lead)

          if result.success?
            text = "✅ Назначен: #{assignee.display_name}"
            text += " (#{result.error_message})" if result.error_message
            ack(text[0, 200])
          else
            log_soft_error('lead_assignment_failed', result.error_message.to_s)
            ack("⚠️ #{result.error_message[0, 180]}", alert: true)
          end
        end

        private

        def log_reassignment_audit(lead, prev_assignee, new_assignee)
          return if prev_assignee.nil? # initial assign — не reassignment

          # Структурированный audit: BotCommandLog уже логирует "callback:assign_to"
          # с args="assign_to:<lead>:<user>", но из этого нельзя восстановить prev.
          # Добавляем JSON в args для full diff (старый → новый assignee + lead context).
          BotCommandLog.create!(
            tg_user_id: tg_user.tg_user_id,
            command: 'callback:assign_to:reassignment',
            args: {
              lead_event_id: lead.id,
              prev_assignee_id: prev_assignee.id,
              prev_assignee_mention: prev_assignee.mention,
              new_assignee_id: new_assignee.id,
              new_assignee_mention: new_assignee.mention,
              actor_mention: tg_user.mention,
              anchor_topic_key: lead.anchor_topic_key
            }.to_json,
            result: 'reassignment'
          )
        rescue StandardError => e
          Rails.logger.warn("[AssignToCallback#log_reassignment_audit] #{e.class}: #{e.message}")
        end

        # Phase 16.7 — soft-error logger: ack() возвращает успешно (TG callback
        # quited без exception), но это error-class outcome для admin /health
        # dashboard. Дублируем msg в error_message column для structured queries.
        def log_soft_error(result, error_msg)
          BotCommandLog.create!(
            tg_user_id: tg_user&.tg_user_id || callback_query.dig('from', 'id'),
            command: 'callback:assign_to:soft_error',
            args: error_msg.to_s.truncate(500),
            result: result,
            error_message: error_msg.to_s.truncate(500)
          )
        rescue StandardError => e
          Rails.logger.warn("[AssignToCallback#log_soft_error] #{e.class}: #{e.message}")
        end

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
