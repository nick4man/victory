# frozen_string_literal: true

module ChatTools
  module Staff
    # Phase 7.5 — Текущая нагрузка сотрудника: open tasks, assigned leads,
    # last_seen. Для manager-сценария «как у Васи дела сегодня».
    module AgentStatus
      def self.schema
        {
          type: 'function',
          function: {
            name: 'agent_status',
            description: 'Снимок текущей нагрузки сотрудника: open tasks, open leads, ' \
                         'last activity. Используй когда спрашивают «как у Васи дела», ' \
                         '«сколько у Ирины сейчас задач».',
            parameters: {
              type: 'object',
              required: ['username'],
              properties: {
                username: {
                  type: 'string',
                  description: 'TG @username (без @).'
                }
              }
            }
          }
        }
      end

      def self.call(args = {})
        username = args[:username].to_s.strip.sub(/\A@/, '').downcase
        user = TelegramUser.find_by('LOWER(tg_username) = ?', username)
        return { error: 'user_not_found', username: username } if user.nil?

        open_tasks    = ::Task.where(assignee_id: user.id, status: 'open').count
        overdue_tasks = ::Task.where(assignee_id: user.id, status: 'open')
                              .where(due_at: ...Time.current).count
        today_done    = ::Task.where(assignee_id: user.id, status: 'done')
                              .where(completed_at: Time.current.all_day).count
        open_leads    = LeadEvent.where(assigned_to_id: user.id)
                                 .where.not(current_stage: ['closed_won', 'closed_lost']).count

        {
          mention: user.mention,
          role: user.role,
          status: user.status,
          assignable: user.assignable,
          open_tasks: open_tasks,
          overdue_tasks: overdue_tasks,
          today_done: today_done,
          open_leads: open_leads,
          last_seen_at: user.last_seen_at&.strftime('%d.%m.%y %H:%M'),
          linked_to_crm: user.linked_to_crm?
        }
      end
    end
  end
end
