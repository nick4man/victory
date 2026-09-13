# frozen_string_literal: true

module Telegram
  module WorkBot
    module Wizard
      # Мастер «Задача с дедлайном»: лид → срок → что сделать → исполнитель.
      # Замена `/task <lead_id> <dd.MM.yy> <текст>`, где любая опечатка в любом
      # из трёх аргументов роняла всю команду.
      class TaskFlow < Flow
        include LeadPicking

        flow 'task', 'Задача с дедлайном'

        TITLE_MAX = 255

        def steps
          [
            lead_step,
            Step.new(id: 'due', kind: :input,
                     prompt: 'До какого числа?',
                     hint: 'Формат dd.MM.yy, например 15.05.26. Или нажми кнопку — она посчитает дату сама.',
                     quick: quick_dates),
            Step.new(id: 'title', kind: :input,
                     prompt: 'Что нужно сделать?',
                     hint: "Одна фраза, до #{TITLE_MAX} символов — это заголовок задачи."),
            Step.new(id: 'assignee', kind: :choice, per_row: 1,
                     prompt: 'На кого ставим?',
                     hint: 'По умолчанию задача уходит ответственному по лиду.',
                     options: assignee_options)
          ]
        end

        # Выбор исполнителя нужен, только когда у лида есть ответственный и
        # это не сам автор. Иначе задача остаётся на авторе, как в `/task`.
        def skip?(step)
          return false unless step.id == 'assignee'

          owner = lead&.assigned_to
          owner.nil? || owner.id == tg_user.id
        end

        def gate
          lead_gate
        end

        def accept(step, value, manual: false)
          case step.id
          when 'lead'     then accept_lead(value)
          when 'due'      then accept_due(value)
          when 'title'    then accept_title(value)
          when 'assignee' then accept_assignee(value)
          else [value, nil]
          end
        end

        def finish
          current_lead = ::LeadEvent.find(ctx['lead'])
          due_date = Formatters::DateFormat.parse(ctx['due'])
          assignee = ctx['assignee'].present? ? ::TelegramUser.find_by(id: ctx['assignee']) : nil

          result = LeadTaskCreator.new(current_lead, due_date: due_date, title: ctx['title'],
                                                     actor: tg_user, assignee: assignee).call
          task = result.task

          lines = ["📅 <b>Задача ##{task.id} создана</b> для лида ##{current_lead.id}: #{escape_html(task.title)}"]
          lines << "до #{Formatters::DateFormat.fmt(due_date)} · исполнитель: #{escape_html(task.assignee&.mention)}"
          lines << crm_line(result.crm)
          { text: lines.compact.join("\n"),
            keyboard: [[{ text: '✅ Выполнить', callback_data: "task:#{task.id}:done" }]] }
        end

        private

        def quick_dates
          today = Date.current
          friday = today + ((5 - today.wday) % 7).then { |d| d.zero? ? 7 : d }
          [['Завтра', today + 1], ['+3 дня', today + 3], ['Пятница', friday]]
            .uniq { |_, date| date }
            .map { |label, date| [label, Formatters::DateFormat.fmt(date)] }
        end

        def assignee_options
          owner = lead&.assigned_to
          return [] unless owner

          [["👤 #{owner.display_name} — ответственный по лиду", owner.id.to_s],
           ['🙋 Себе', tg_user.id.to_s]]
        end

        def accept_due(value)
          date = Formatters::DateFormat.parse(value)
          unless date
            return [nil, "Не понимаю дату «#{escape_html(value)}». Формат dd.MM.yy — например, " \
                         "#{Formatters::DateFormat.fmt(Date.current + 2)}."]
          end
          if date < Date.current
            return [nil, "Дедлайн в прошлом (#{Formatters::DateFormat.fmt(date)}). Укажи сегодняшнюю или будущую дату."]
          end

          [Formatters::DateFormat.fmt(date), nil]
        end

        def accept_title(value)
          text = value.to_s.squish
          return [nil, 'Пустой ответ. Напиши хотя бы одну фразу — она станет заголовком задачи.'] if text.empty?
          if text.length > TITLE_MAX
            return [nil, "Слишком длинно: #{text.length} символов, в заголовок влезает #{TITLE_MAX}. " \
                         "Сократи на #{text.length - TITLE_MAX}."]
          end

          [text, nil]
        end

        def accept_assignee(value)
          user = ::TelegramUser.find_by(id: value)
          return [nil, 'Сотрудник не найден — выбери из списка ещё раз.'] unless user

          [user.id.to_s, nil]
        end

        def crm_line(status)
          case status
          when :ok then 'Дедлайн проброшен в Topnlab.'
          when :failed then '⚠️ Topnlab не принял дедлайн — задача сохранена в боте, в CRM срок не проставлен.'
          end
        end
      end
    end
  end
end
