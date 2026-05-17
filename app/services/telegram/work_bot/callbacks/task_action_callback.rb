# frozen_string_literal: true

module Telegram
  module WorkBot
    module Callbacks
      # Phase 7.3 — Inline-button handler для DM-карточек задач.
      # callback_data: "task:<task_id>:done" или "task:<task_id>:start".
      #
      # Authorization: только assignee (или manager override). Toast'ом
      # сообщаем о результате.
      #
      # На 'done' — Task#mark_completed!(acked_method: 'button') + edit DM
      # message с маркером ✅ перед задачей.
      # На 'start' — Task#mark_started! + edit с маркером ▶.
      class TaskActionCallback < Base
        def handle
          task_id = @args[0].to_i
          action  = @args[1].to_s

          task = ::Task.find_by(id: task_id)
          return ack('⚠️ Задача не найдена', alert: true) if task.nil?

          unless authorized?(task)
            return ack('🚫 Это не твоя задача', alert: true)
          end

          case action
          when 'done'  then mark_done(task)
          when 'start' then mark_start(task)
          else ack('⚠️ Неизвестное действие', alert: true)
          end
        end

        private

        def authorized?(task)
          task.assignee_id == tg_user.id || tg_user.is_manager?
        end

        def mark_done(task)
          if task.status_done?
            return ack("ℹ️ Уже выполнено #{task.completed_at&.strftime('%d.%m.%y %H:%M')}", alert: false)
          end

          task.mark_completed!(acked_method: 'button')
          duration = task.completion_duration_sec
          suffix = task.suspicious_flag? ? ' ⚠️ suspicious' : ''
          ack("✅ ##{task.id} выполнено#{suffix} (#{format_duration(duration)})")
        end

        def mark_start(task)
          task.mark_started!
          ack("▶ Принято в работу ##{task.id}")
        end

        def format_duration(seconds)
          return '—' if seconds.nil?
          return "#{seconds}с" if seconds < 60
          return "#{(seconds / 60.0).round(1)} мин" if seconds < 3600

          "#{(seconds / 3600.0).round(1)} ч"
        end
      end
    end
  end
end
