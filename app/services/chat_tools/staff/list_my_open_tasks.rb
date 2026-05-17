# frozen_string_literal: true

module ChatTools
  module Staff
    # Phase 7.5 — chat_tool для staff_chat_responder. Возвращает open задачи
    # текущего сотрудника (caller). assignee_username опционально — для
    # manager-override (другой человек просит за подчинённого).
    module ListMyOpenTasks
      def self.schema
        {
          type: 'function',
          function: {
            name: 'list_my_open_tasks',
            description: 'Список открытых задач сотрудника (упорядочен по due_at + priority). ' \
                         'Используй когда сотрудник спрашивает «какие у меня задачи», «что на завтра», ' \
                         '«какие задачи у Васи» (manager).',
            parameters: {
              type: 'object',
              required: ['assignee_username'],
              properties: {
                assignee_username: {
                  type: 'string',
                  description: 'TG @username сотрудника (без @). Для self-query — username caller-а.'
                },
                only_today: {
                  type: 'boolean',
                  description: 'Если true — только задачи с due_at сегодня. Default false (все open).'
                }
              }
            }
          }
        }
      end

      def self.call(args = {})
        username = args[:assignee_username].to_s.strip.sub(/\A@/, '').downcase
        user = TelegramUser.find_by('LOWER(tg_username) = ?', username)
        return { error: 'user_not_found', username: username } if user.nil?

        scope = ::Task.where(assignee_id: user.id, status: 'open').order(:priority, :due_at)
        scope = scope.where(due_at: Time.current.all_day) if args[:only_today]
        tasks = scope.limit(20).to_a

        {
          assignee_username: user.tg_username,
          count: tasks.size,
          tasks: tasks.map { |t| serialize(t) }
        }
      end

      def self.serialize(task)
        {
          id: task.id,
          title: task.title,
          priority: task.priority,
          kind: task.kind,
          due_at: task.due_at&.iso8601,
          due_str: task.due_at&.strftime('%d.%m.%y %H:%M'),
          overdue: task.due_at && task.due_at < Time.current,
          suspicious: task.suspicious_flag?
        }
      end
    end
  end
end
