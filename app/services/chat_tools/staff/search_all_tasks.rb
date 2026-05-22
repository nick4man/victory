# frozen_string_literal: true

module ChatTools
  module Staff
    # Phase 15 — cross-staff поиск задач для control panel.
    # Расширение `list_my_open_tasks` + `lookup_task` — но с filtering по
    # assignee/creator/status/priority/kind/period и optional text query.
    #
    # Security: manager+ может смотреть любого. Agent — silent self-only
    # (assignee filter принудительно = caller).
    module SearchAllTasks
      MAX_RESULTS = 30
      ALLOWED_STATUSES = %w[open done canceled].freeze
      ALLOWED_PRIORITIES = %w[low normal high urgent].freeze
      ALLOWED_KINDS = %w[call show document admin other].freeze
      ALLOWED_PERIOD_FIELDS = %w[created_at due_at].freeze

      def self.schema
        {
          type: 'function',
          function: {
            name: 'search_all_tasks',
            description: 'Поиск задач cross-staff с фильтрами (assignee, status, priority, kind, period). ' \
                         'Используй для запросов: «какие задачи overdue у всех», «задачи Ирины на неделю», ' \
                         '«сколько high-priority задач открыто», «дай мне задачи кампанийки за вчера». ' \
                         'Agent видит только свои.',
            parameters: {
              type: 'object',
              properties: {
                query: { type: 'string', description: 'Optional ILIKE-search по task.title (pg_trgm).' },
                assignee_username: { type: 'string', description: '@username assignee (без @).' },
                created_by_username: { type: 'string', description: '@username кто создал.' },
                status: { type: 'string', enum: ALLOWED_STATUSES },
                priority: { type: 'string', enum: ALLOWED_PRIORITIES },
                kind: { type: 'string', enum: ALLOWED_KINDS },
                period: {
                  type: 'string',
                  enum: %w[today yesterday this_week last_week this_month custom],
                  description: 'Optional. Период по полю period_field (default created_at).'
                },
                period_field: {
                  type: 'string',
                  enum: ALLOWED_PERIOD_FIELDS,
                  description: 'created_at или due_at для period-фильтра. Default created_at.'
                },
                from_date: { type: 'string', description: 'для period=custom, dd.MM.yy' },
                to_date:   { type: 'string', description: 'для period=custom, dd.MM.yy' },
                only_overdue: { type: 'boolean', description: 'true — только status=open AND due_at < now' }
              }
            }
          }
        }
      end

      def self.call(args = {}, asked_by: nil)
        caller = resolve_caller(args[:caller_tg_user_id], asked_by)
        return { error: 'caller_unknown' } if caller.nil?

        scope = ::Task.all

        # Agent — silent self-only (drop любых cross-staff фильтров)
        unless caller.manager_or_director?
          scope = scope.where(assignee_id: caller.id)
        else
          scope = apply_assignee_filter(scope, args[:assignee_username])
          scope = apply_creator_filter(scope, args[:created_by_username])
        end

        scope = scope.where(status: args[:status]) if ALLOWED_STATUSES.include?(args[:status].to_s)
        scope = scope.where(priority: args[:priority]) if ALLOWED_PRIORITIES.include?(args[:priority].to_s)
        scope = scope.where(kind: args[:kind]) if ALLOWED_KINDS.include?(args[:kind].to_s)
        scope = scope.where('title ILIKE ?', "%#{::ActiveRecord::Base.sanitize_sql_like(args[:query].to_s)}%") if args[:query].present?

        if (range = resolve_range(args))
          field = ALLOWED_PERIOD_FIELDS.include?(args[:period_field].to_s) ? args[:period_field].to_s : 'created_at'
          scope = scope.where(field => range)
        end

        if args[:only_overdue]
          scope = scope.where(status: 'open').where('due_at < ?', Time.current)
        end

        tasks = scope.order(due_at: :asc, created_at: :desc).limit(MAX_RESULTS).includes(:assignee, :created_by).to_a

        {
          count: scope.count,
          shown: tasks.size,
          period_label: period_label(args),
          items: tasks.map { |t| serialize(t) }
        }
      end

      def self.resolve_caller(caller_id, asked_by)
        return asked_by if asked_by.is_a?(::TelegramUser)
        return ::TelegramUser.find_by(id: caller_id) if caller_id.present?

        nil
      end

      def self.apply_assignee_filter(scope, username)
        return scope if username.blank?

        if (u = ::TelegramUser.find_by('LOWER(tg_username) = ?', username.to_s.sub(/\A@/, '').downcase))
          scope.where(assignee_id: u.id)
        else
          scope.none
        end
      end

      def self.apply_creator_filter(scope, username)
        return scope if username.blank?

        if (u = ::TelegramUser.find_by('LOWER(tg_username) = ?', username.to_s.sub(/\A@/, '').downcase))
          scope.where(created_by_id: u.id)
        else
          scope.none
        end
      end

      def self.resolve_range(args)
        case args[:period].to_s
        when 'today'      then Time.current.beginning_of_day..Time.current.end_of_day
        when 'yesterday'  then 1.day.ago.beginning_of_day..1.day.ago.end_of_day
        when 'this_week'  then Time.current.beginning_of_week..Time.current.end_of_week
        when 'last_week'  then 1.week.ago.beginning_of_week..1.week.ago.end_of_week
        when 'this_month' then Time.current.beginning_of_month..Time.current.end_of_month
        when 'custom'
          parse_custom_range(args[:from_date], args[:to_date])
        end
      end

      def self.parse_custom_range(from_raw, to_raw)
        from = Date.strptime(from_raw.to_s, '%d.%m.%y').beginning_of_day
        to   = Date.strptime(to_raw.to_s,   '%d.%m.%y').end_of_day
        return nil if from > to

        from..to
      rescue ArgumentError, TypeError
        nil
      end

      def self.period_label(args)
        case args[:period].to_s
        when 'today' then 'сегодня'
        when 'yesterday' then 'вчера'
        when 'this_week' then 'на этой неделе'
        when 'last_week' then 'на прошлой неделе'
        when 'this_month' then 'в этом месяце'
        when 'custom' then "#{args[:from_date]}–#{args[:to_date]}"
        else 'за всё время'
        end
      end

      def self.serialize(task)
        {
          id: task.id,
          title: task.title.to_s.truncate(120),
          status: task.status,
          priority: task.priority,
          kind: task.kind,
          assignee: task.assignee&.mention,
          created_by: task.created_by&.mention,
          due_str: task.due_at&.strftime('%d.%m.%y %H:%M'),
          created_str: task.created_at.strftime('%d.%m.%y %H:%M'),
          overdue: task.due_at && task.due_at < Time.current && task.status == 'open'
        }
      end
    end
  end
end
