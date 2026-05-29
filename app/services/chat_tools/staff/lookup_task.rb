# frozen_string_literal: true

module ChatTools
  module Staff
    # Phase 7.5 — Поиск задачи по id или substring в title.
    module LookupTask
      def self.schema
        {
          type: 'function',
          function: {
            name: 'lookup_task',
            description: 'Найти задачу по id или фрагменту названия. Используй когда ' \
                         'сотрудник спрашивает «что по задаче 42» или «найди задачу про показ».',
            parameters: {
              type: 'object',
              required: ['query'],
              properties: {
                query: {
                  type: 'string',
                  description: 'Числовой id (например "42") или фрагмент title ("показ Малиновая").'
                }
              }
            }
          }
        }
      end

      def self.call(args = {})
        query = args[:query].to_s.strip
        return { error: 'empty_query' } if query.empty?

        tasks = if query.match?(/\A\d+\z/)
                  ::Task.where(id: query.to_i).to_a
                else
                  ::Task.where('title ILIKE ?', "%#{query}%").order(created_at: :desc).limit(5).to_a
                end

        return { error: 'not_found', query: query } if tasks.empty?

        { count: tasks.size, tasks: tasks.map { |t| serialize(t) } }
      end

      def self.serialize(task)
        {
          id: task.id,
          title: task.title,
          status: task.status,
          priority: task.priority,
          kind: task.kind,
          assignee: task.assignee&.mention,
          due_at: task.due_at&.strftime('%d.%m.%y %H:%M'),
          completed_at: task.completed_at&.strftime('%d.%m.%y %H:%M'),
          suspicious: task.suspicious_flag?
        }
      end
    end
  end
end
