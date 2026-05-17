# frozen_string_literal: true

module Telegram
  module WorkBot
    module Commands
      # Phase 7.3 — `/done <task_id>` — assignee помечает задачу выполненной.
      # Альтернативные пути: inline-кнопка [✅ Выполнено] (Callbacks::TaskActionCallback)
      # или ✅ реакция на task-DM (Telegram::TaskReactionHandler — Phase 7.3+).
      #
      # Authorization: assignee своей задачи ИЛИ manager (для override).
      # На double-done — friendly «уже выполнена».
      # При suspicious_flag=true — warning в reply (но completion проходит).
      class Done < Base
        def handle
          task_id = args.to_s.strip.to_i
          return reply('Формат: <code>/done 42</code> — где 42 это task_id из DM-карточки.') if task_id.zero?

          task = ::Task.find_by(id: task_id)
          return reply("⚠️ Задача ##{task_id} не найдена.") if task.nil?

          unless authorized?(task)
            return reply("🚫 Эта задача назначена #{task.assignee&.mention || 'другому'}, ты не можешь её закрыть.")
          end

          if task.status_done?
            return reply("ℹ️ Задача ##{task.id} уже выполнена #{task.completed_at&.strftime('%d.%m.%y %H:%M')}.")
          end

          if task.status_canceled?
            return reply("ℹ️ Задача ##{task.id} отменена — нельзя пометить выполненной.")
          end

          task.mark_completed!(acked_method: 'command')

          duration = task.completion_duration_sec
          duration_str = duration ? "(за #{format_duration(duration)})" : ''
          msg = "✅ Задача ##{task.id} выполнена #{duration_str}".strip
          msg += "\n⚠️ <i>Помечена suspicious (быстрая ack/без first_contact) — будет в weekly review</i>" if task.suspicious_flag?
          reply(msg)
        end

        private

        def authorized?(task)
          return false if tg_user.nil?

          task.assignee_id == tg_user.id || tg_user.is_manager?
        end

        def format_duration(seconds)
          return "#{seconds}с" if seconds < 60
          return "#{(seconds / 60.0).round(1)} мин" if seconds < 3600
          return "#{(seconds / 3600.0).round(1)} ч" if seconds < 86_400

          "#{(seconds / 86_400.0).round(1)} дн"
        end
      end
    end
  end
end
