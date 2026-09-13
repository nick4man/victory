# frozen_string_literal: true

module Telegram
  module WorkBot
    module Wizard
      # Мастер «Переоткрытие задачи»: одна кнопка из списка недавно закрытых.
      #
      # Время закрытия написано на каждой кнопке — истёкшее окно 24 часа не
      # сюрприз. Задача за окном всё равно в списке: вместо молчаливого отказа
      # мастер объясняет, почему нельзя, и сразу предлагает новую задачу по
      # тому же лиду.
      class ReopenFlow < Flow
        flow 'reopen', 'Переоткрытие задачи'

        LIST_LIMIT = 6
        LIST_PERIOD = 3.days

        def steps
          [
            Step.new(id: 'task', kind: :choice, per_row: 1,
                     prompt: recent_tasks.any? ? 'Какую задачу переоткрыть?' : 'Какую задачу переоткрыть? Недавно закрытых в списке нет.',
                     hint: "Переоткрыть можно в течение #{TaskReopen::REOPEN_WINDOW.in_hours.to_i} часов после закрытия.",
                     options: recent_tasks.map { |t| [task_label(t), t.id.to_s] },
                     manual: '⌨️ Ввести номер задачи',
                     manual_prompt: 'Напиши номер задачи цифрами.')
          ]
        end

        def gate
          return nil if ctx['task'].blank?

          _, error = accept_task(ctx['task'])
          error && "⚠️ #{error}"
        end

        def accept(step, value, manual: false)
          step.id == 'task' ? accept_task(value) : [value, nil]
        end

        def finish
          task = ::Task.find_by(id: ctx['task'])
          return { text: '⚠️ Задача не найдена — возможно, её удалили.' } unless task

          result = TaskReopen.new(task, actor: tg_user, client: client).call

          case result.status
          when :reopened
            { text: "♻️ <b>Задача ##{task.id} переоткрыта</b> (была #{result.prev_status}).\n" \
                    "Исполнитель: #{escape_html(task.assignee&.mention || '—')}",
              keyboard: [[{ text: '✅ Выполнить', callback_data: "task:#{task.id}:done" }]] }
          when :expired
            { text: "⚠️ <b>Окно #{TaskReopen::REOPEN_WINDOW.in_hours.to_i} часа истекло:</b> задача ##{task.id} " \
                    "закрыта #{Formatters::DateFormat.fmt_dt(result.closed_at)}.\n" \
                    '<i>Следы в дайджесте и KPI уже зафиксированы — поставь новую задачу.</i>',
              keyboard: [[{ text: '➕ Новая задача', callback_data: new_task_callback(task) }]] }
          when :already_open
            { text: "ℹ️ Задача ##{task.id} и так в работе." }
          else
            { text: '🚫 Переоткрыть может только исполнитель задачи или руководитель.' }
          end
        end

        private

        def recent_tasks
          @recent_tasks ||= begin
            scope = ::Task.where(status: ['done', 'canceled'], updated_at: LIST_PERIOD.ago..)
            scope = scope.for_assignee(tg_user) unless tg_user.is_manager?
            scope.order(updated_at: :desc).limit(LIST_LIMIT).to_a
          end
        end

        def task_label(task)
          "##{task.id} · #{task.title.to_s.squish.truncate(36)} — #{closed_ago(TaskReopen.closed_at(task))}"
        end

        def closed_ago(at)
          return 'закрыта' if at.nil?

          hours = ((Time.current - at) / 1.hour).floor
          return 'закрыта только что' if hours < 1
          return "закрыта #{hours} ч назад" if hours < 48

          "закрыта #{Formatters::DateFormat.fmt(at)}"
        end

        def accept_task(value)
          raw = value.to_s.strip.delete_prefix('#')
          return [nil, "Номер задачи — целое число. Получено: «#{escape_html(raw)}»."] unless raw.match?(/\A\d+\z/)

          task = ::Task.find_by(id: raw.to_i)
          return [nil, "Задача ##{raw} не найдена."] unless task
          return [nil, "Задача ##{task.id} и так в работе."] if task.status_open?
          unless TaskReopen.authorized?(task, tg_user)
            return [nil, "Задача ##{task.id} назначена #{escape_html(task.assignee&.mention || 'другому')} — " \
                         'переоткрыть может только исполнитель или руководитель.']
          end

          [task.id.to_s, nil]
        end

        def new_task_callback(task)
          task.lead_event_id ? "wiz:s:task:#{task.lead_event_id}" : 'wiz:s:task'
        end
      end
    end
  end
end
