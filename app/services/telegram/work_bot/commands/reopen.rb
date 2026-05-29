# frozen_string_literal: true

module Telegram
  module WorkBot
    module Commands
      # Phase 11 Iter 24 — `/reopen <task_id>` — отмена решения «done/canceled»,
      # возврат задачи в работу. Узкое окно — 24 часа от completed_at/updated_at:
      # позже — следы в digest/KPI уже зафиксированы, легче создать новую задачу.
      #
      # Зачем: до этого фикса ошибочные /done или /cancel требовали SQL —
      # манагерская ошибка задерживала клиента (закрытая задача → исчезла
      # из digest → никто не вспомнил).
      #
      # Гарантии:
      #   • Authorized: assignee своей задачи ИЛИ manager (для override)
      #   • Окно 24h (REOPEN_WINDOW) — после — reject + предложить создать новую
      #   • Status open → no-op + friendly reply
      #   • Reset completed_at/acked_method/suspicious_flag, оставить first_acked_at
      #     (запись «работа была начата»)
      #   • DM assignee когда manager reopen'ит чужую (audit-trail)
      #   • Refresh digest auto через after_commit (Task lifecycle)
      class Reopen < Base
        REOPEN_WINDOW = 24.hours

        def handle
          task_id = args.split(/\s+/).first.to_i
          return reply('Формат: <code>/reopen 42</code> — где 42 это task_id.') if task_id.zero?

          task = ::Task.find_by(id: task_id)
          return reply("⚠️ Задача ##{task_id} не найдена.") if task.nil?

          unless authorized?(task)
            return reply("🚫 Задача назначена #{task.assignee&.mention || 'другому'} — " \
                         'переоткрыть может только assignee или manager.')
          end

          if task.status_open?
            return reply("ℹ️ Задача ##{task.id} и так в работе (status=open).")
          end

          closed_at = task.completed_at || task.updated_at
          if closed_at && closed_at < REOPEN_WINDOW.ago
            return reply("⚠️ Задача закрыта #{closed_at.strftime('%d.%m.%y %H:%M')} — " \
                         "более #{REOPEN_WINDOW.in_hours.to_i}ч назад. Окно reopen истекло, " \
                         'создай новую через <code>/task dd.MM.yy текст</code>.')
          end

          prev_status = task.status
          ::Task.transaction do
            task.assign_attributes(
              status: 'open',
              completed_at: nil,
              acked_method: nil,
              suspicious_flag: false
              # first_acked_at, started_at, notified_at — сохраняем (история работы)
            )
            task.save!
          end

          notify_assignee_if_third_party(task, prev_status)

          reply("↩️ Задача ##{task.id} переоткрыта (была <b>#{prev_status}</b>).")
        end

        private

        def authorized?(task)
          return false if tg_user.nil?

          task.assignee_id == tg_user.id || tg_user.is_manager?
        end

        # Manager reopen'ит чужую задачу → assignee должен узнать.
        def notify_assignee_if_third_party(task, prev_status)
          return if task.assignee.nil?
          return if task.assignee_id == tg_user.id # сам себя переоткрыл — DM не нужен

          due_str = task.due_at ? "до #{task.due_at.strftime('%d.%m.%y %H:%M')}" : 'без срока'
          text = "↩️ <b>Твоя задача снова в работе</b> ##{task.id}\n" \
                 "📋 #{escape_html(task.title)}\n" \
                 "⏰ #{due_str}\n" \
                 "Была: <b>#{prev_status}</b> · переоткрыл: #{tg_user.mention}"
          dm(text, to: task.assignee)
        end
      end
    end
  end
end
