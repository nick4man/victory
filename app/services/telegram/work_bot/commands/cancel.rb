# frozen_string_literal: true

module Telegram
  module WorkBot
    module Commands
      # Phase 7.3+ — `/cancel <task_id> [причина]` — отмена задачи.
      # Auth: assignee (своя задача) ИЛИ manager (любая).
      #
      # status=canceled, не done — для KPI учитывается отдельно
      # (canceled не входит в tasks_completed).
      class Cancel < Base
        def handle
          parts = args.to_s.split(/\s+/, 2)
          task_id = parts[0].to_i
          reason  = parts[1].to_s.strip

          return reply('Формат: <code>/cancel 42 [причина]</code>') if task_id.zero?

          task = ::Task.find_by(id: task_id)
          return reply("⚠️ Задача ##{task_id} не найдена.") if task.nil?

          unless authorized?(task)
            return reply("🚫 Эта задача назначена #{task.assignee&.mention || 'другому'} — отменить может только assignee или manager.")
          end

          if task.status_canceled?
            return reply("ℹ️ Задача ##{task.id} уже отменена #{task.updated_at.strftime('%d.%m.%y %H:%M')}.")
          end

          if task.status_done?
            return reply("ℹ️ Задача ##{task.id} уже выполнена — отменить нельзя. Создай новую через /task.")
          end

          task.update!(status: 'canceled')

          if reason.present?
            Rails.logger.info("[Cancel] task ##{task.id} cancelled by #{tg_user.mention}: #{reason}")
          end

          msg = "✖️ Задача ##{task.id} <s>#{escape(task.title.to_s[0, 60])}</s> отменена"
          msg += " · причина: #{escape(reason)}" if reason.present?
          reply(msg)
        end

        private

        def authorized?(task)
          return false if tg_user.nil?

          task.assignee_id == tg_user.id || tg_user.is_manager?
        end

        def escape(text)
          text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
        end
      end
    end
  end
end
