# frozen_string_literal: true

module ChatTools
  module Staff
    # Phase 7.6 — kpi_for(period:, staff_username?:) — экспонирует StaffMetric
    # агрегаты для StaffChatResponder.
    module KpiFor
      PERIODS = {
        'today' => 0..0,
        'yesterday' => 1..1,
        'week' => 0..7,
        'month' => 0..30,
        'quarter' => 0..90
      }.freeze

      def self.schema
        {
          type: 'function',
          function: {
            name: 'kpi_for',
            description: 'KPI агрегаты сотрудника или всего АН за период. Используй для ' \
                         'вопросов «как у Ирины дела за неделю», «сколько задач закрыли в этом месяце», ' \
                         '«show top performer».',
            parameters: {
              type: 'object',
              required: ['period'],
              properties: {
                period: {
                  type: 'string',
                  enum: PERIODS.keys,
                  description: 'Период агрегации.'
                },
                staff_username: {
                  type: 'string',
                  description: '@username конкретного сотрудника (без @). Пустой — agency-wide.'
                }
              }
            }
          }
        }
      end

      def self.call(args = {})
        period_key = args[:period].to_s
        range_back = PERIODS[period_key] || PERIODS['today']
        date_range = (Date.current - range_back.end.days)..(Date.current - range_back.begin.days)

        if args[:staff_username].present?
          per_staff(args[:staff_username], date_range, period_key)
        else
          agency_wide(date_range, period_key)
        end
      end

      def self.per_staff(username, range, period_key)
        username = username.to_s.strip.sub(/\A@/, '').downcase
        user = TelegramUser.find_by('LOWER(tg_username) = ?', username)
        return { error: 'user_not_found', username: username } if user.nil?

        metrics = StaffMetric.for_staff(user).for_period(range).to_a
        return { mention: user.mention, period: period_key, no_data: true } if metrics.empty?

        aggregated = aggregate(metrics)
        aggregated.merge(mention: user.mention, period: period_key)
      end

      def self.agency_wide(range, period_key)
        metrics = StaffMetric.for_period(range).to_a
        return { period: period_key, no_data: true } if metrics.empty?

        aggregated = aggregate(metrics)
        top = metrics.group_by(&:staff_id).max_by { |_, ms| ms.sum(&:tasks_completed) }
        top_staff = top ? TelegramUser.find_by(id: top.first) : nil
        aggregated.merge(period: period_key, staff_count: metrics.map(&:staff_id).uniq.size,
                         top_performer: if top_staff
                                          { mention: top_staff.mention,
                                            tasks_completed: top.last.sum(&:tasks_completed) }
                                        end)
      end

      def self.aggregate(metrics)
        tasks_assigned  = metrics.sum(&:tasks_assigned)
        tasks_completed = metrics.sum(&:tasks_completed)
        tasks_on_time   = metrics.sum(&:tasks_on_time)
        leads_assigned  = metrics.sum(&:leads_assigned)
        leads_converted = metrics.sum(&:leads_converted)

        {
          tasks_assigned: tasks_assigned,
          tasks_completed: tasks_completed,
          tasks_on_time: tasks_on_time,
          completion_rate: tasks_assigned.positive? ? (tasks_completed.to_f * 100 / tasks_assigned).round : 0,
          on_time_rate: tasks_completed.positive? ? (tasks_on_time.to_f * 100 / tasks_completed).round : 0,
          tasks_overdue: metrics.sum(&:tasks_overdue),
          questions_asked: metrics.sum(&:questions_asked),
          question_dependency: tasks_completed.positive? ? (metrics.sum(&:questions_asked).to_f / tasks_completed).round(2) : 0,
          leads_assigned: leads_assigned,
          leads_first_contact_in_30m: metrics.sum(&:leads_first_contact_in_30m),
          leads_converted: leads_converted,
          conversion_rate: leads_assigned.positive? ? (leads_converted.to_f * 100 / leads_assigned).round : 0,
          suspicious_completions: metrics.sum(&:suspicious_completions),
          documents_uploaded: metrics.sum(&:documents_uploaded)
        }
      end
    end
  end
end
