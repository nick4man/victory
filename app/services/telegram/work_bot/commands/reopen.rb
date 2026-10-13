# frozen_string_literal: true

module Telegram
  module WorkBot
    module Commands
      # Phase 11 Iter 24 — `/reopen <task_id>` — отмена решения «done/canceled»,
      # возврат задачи в работу. Узкое окно — 24 часа от completed_at/updated_at.
      # Правила и побочные эффекты — в Telegram::WorkBot::TaskReopen.
      #
      # Зачем: до этого фикса ошибочные /done или /cancel требовали SQL —
      # манагерская ошибка задерживала клиента (закрытая задача → исчезла
      # из digest → никто не вспомнил).
      #
      # Без id открывает мастер в личке: задача выбирается из списка недавно
      # закрытых, время закрытия видно на кнопке. См. Wizard::ReopenFlow.
      class Reopen < Base
        REOPEN_WINDOW = TaskReopen::REOPEN_WINDOW

        def handle
          return open_wizard('reopen') if args.blank?

          task_id = args.split(/\s+/).first.to_i
          return reply('Формат: <code>/reopen 42</code> — где 42 это task_id.') if task_id.zero?

          task = ::Task.find_by(id: task_id)
          return reply("⚠️ Задача ##{task_id} не найдена.") if task.nil?

          result = TaskReopen.new(task, actor: tg_user, client: client).call
          case result.status
          when :forbidden
            reply("🚫 Задача назначена #{task.assignee&.mention || 'другому'} — " \
                  'переоткрыть может только assignee или manager.')
          when :already_open
            reply("ℹ️ Задача ##{task.id} и так в работе (status=open).")
          when :expired
            reply("⚠️ Задача закрыта #{result.closed_at.strftime('%d.%m.%y %H:%M')} — " \
                  "более #{REOPEN_WINDOW.in_hours.to_i}ч назад. Окно reopen истекло, " \
                  'создай новую через <code>/task dd.MM.yy текст</code>.')
          else
            reply("↩️ Задача ##{task.id} переоткрыта (была <b>#{result.prev_status}</b>).")
          end
        end
      end
    end
  end
end
