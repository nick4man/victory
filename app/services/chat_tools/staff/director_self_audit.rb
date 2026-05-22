# frozen_string_literal: true

module ChatTools
  module Staff
    # Iter 59 — self-audit для manager+ ролей. Используется когда сотрудник
    # спрашивает в DM/QnA «какие лиды я сегодня направил», «какие задания я
    # давал на этой неделе», «сколько сделок я провёл».
    #
    # Tool параметры:
    #   • period     — today/yesterday/this_week/last_week/custom
    #   • category   — leads_routed / leads_assigned / tasks_created / all
    #   • from_date  — для period=custom (dd.MM.yy)
    #   • to_date    — для period=custom (dd.MM.yy)
    #   • staff_username — manager может смотреть аудит подчинённого
    #                      (без префикса @). Пустой = caller.
    #
    # Security boundary: agent роль ВСЕГДА смотрит только себя (даже если LLM
    # передал чужой staff_username — игнорим). manager/director может other.
    #
    # Возвращает структурированный hash, который StaffChatResponder скормит
    # LLM для финального markdown-рендера. Поля: leads_routed/leads_assigned/
    # tasks_created (массивы) + counts + period_label (dd.MM.yy человеко-читаемо).
    module DirectorSelfAudit
      ALLOWED_PERIODS = %w[today yesterday this_week last_week this_month custom].freeze
      ALLOWED_CATEGORIES = %w[leads_routed leads_assigned tasks_created all].freeze
      MAX_RESULTS_PER_LIST = 25 # cap чтобы не раздувать tool response

      def self.schema
        {
          type: 'function',
          function: {
            name: 'director_self_audit',
            description: 'Аудит активности сотрудника manager/director ранга — какие лиды он назначил/направил в рабочий чат, ' \
                         'какие задания дал, за выбранный период. Используй для вопросов «какие задания я давала ' \
                         'сегодня», «покажи лиды я направила за эту неделю», «что Оксана раздала вчера» (только для manager+ ' \
                         'просящего о другом manager+). Agent видит только себя.',
            parameters: {
              type: 'object',
              required: ['period'],
              properties: {
                period: {
                  type: 'string',
                  enum: ALLOWED_PERIODS,
                  description: 'today | yesterday | this_week | last_week | this_month | custom (требует from_date/to_date)'
                },
                category: {
                  type: 'string',
                  enum: ALLOWED_CATEGORIES,
                  description: 'leads_routed (направленные через /route) | leads_assigned (через /assign) | ' \
                               'tasks_created (через /task или voice batch) | all (default)'
                },
                from_date: {
                  type: 'string',
                  description: 'для period=custom, формат dd.MM.yy (например 15.05.26)'
                },
                to_date: {
                  type: 'string',
                  description: 'для period=custom, формат dd.MM.yy'
                },
                staff_username: {
                  type: 'string',
                  description: 'TG @username сотрудника (без @). Пустой = caller. Игнорируется если caller=agent.'
                }
              }
            }
          }
        }
      end

      def self.call(args = {}, asked_by: nil)
        # asked_by опционален — Registry-вход не пробрасывает caller-context.
        # Если nil — это значит вызов из теста или LLM без role-context;
        # в production StaffChatResponder обязан передавать asked_by, но
        # схема Registry.call(name, args) не поддерживает третий аргумент,
        # поэтому caller_tg_user приходит через args[:caller_tg_user_id].
        caller = resolve_caller(args[:caller_tg_user_id], asked_by)
        return { error: 'caller_unknown', message: 'не могу определить кто спрашивает' } if caller.nil?

        target = resolve_target(args, caller)
        return { error: 'forbidden', message: 'agent видит аудит только по себе' } if target.nil?

        range = resolve_range(args)
        return { error: 'bad_period', message: 'неизвестный период или некорректные даты' } if range.nil?

        category = args[:category].to_s.presence || 'all'
        category = 'all' unless ALLOWED_CATEGORIES.include?(category)

        build_response(target: target, range: range, category: category, args: args)
      end

      def self.resolve_caller(caller_id, asked_by)
        return asked_by if asked_by.is_a?(::TelegramUser)
        return ::TelegramUser.find_by(id: caller_id) if caller_id.present?

        nil
      end

      # target resolution:
      #   • staff_username blank → caller (self-audit)
      #   • caller=agent → silently ignore foreign username, return caller
      #     (agent role видит ТОЛЬКО себя; не возвращаем error чтобы LLM не
      #     раскрывал что staff_username было передано и проигнорировано)
      #   • caller=manager+ → resolve по @username, fallback caller если not found
      def self.resolve_target(args, caller)
        username = args[:staff_username].to_s.strip.sub(/\A@/, '').downcase
        return caller if username.blank?

        # agent — silent self-only fallback (НЕ error: spec contract).
        return caller unless caller.manager_or_director?

        ::TelegramUser.find_by('LOWER(tg_username) = ?', username) || caller
      end

      def self.resolve_range(args)
        case args[:period].to_s
        when 'today'      then Time.current.beginning_of_day..Time.current.end_of_day
        when 'yesterday'  then 1.day.ago.beginning_of_day..1.day.ago.end_of_day
        when 'this_week'  then Time.current.beginning_of_week..Time.current.end_of_week
        when 'last_week'  then 1.week.ago.beginning_of_week..1.week.ago.end_of_week
        when 'this_month' then Time.current.beginning_of_month..Time.current.end_of_month
        when 'custom'     then parse_custom_range(args[:from_date], args[:to_date])
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

      def self.build_response(target:, range:, category:, args:)
        response = {
          target_mention: target.mention,
          period_label: period_label(range, args),
          category: category
        }

        if %w[tasks_created all].include?(category)
          response[:tasks_created] = serialize_tasks(target, range)
        end

        if %w[leads_routed all].include?(category)
          response[:leads_routed] = serialize_leads_routed(target, range)
        end

        if %w[leads_assigned all].include?(category)
          response[:leads_assigned] = serialize_leads_assigned(target, range)
        end

        response
      end

      def self.period_label(range, args)
        case args[:period].to_s
        when 'today'      then 'сегодня'
        when 'yesterday'  then 'вчера'
        when 'this_week'  then 'на этой неделе'
        when 'last_week'  then 'на прошлой неделе'
        when 'this_month' then 'в этом месяце'
        when 'custom'
          "#{range.begin.strftime('%d.%m.%y')}–#{range.end.strftime('%d.%m.%y')}"
        else
          "#{range.begin.strftime('%d.%m.%y')}–#{range.end.strftime('%d.%m.%y')}"
        end
      end

      def self.serialize_tasks(target, range)
        tasks = ::Task.created_by_tg(target).created_in(range)
                      .order(created_at: :desc).limit(MAX_RESULTS_PER_LIST).includes(:assignee).to_a
        {
          count: ::Task.created_by_tg(target).created_in(range).count,
          items: tasks.map { |t| serialize_task(t) }
        }
      end

      def self.serialize_task(task)
        {
          id: task.id,
          title: task.title.to_s.truncate(120),
          assignee: task.assignee&.mention,
          priority: task.priority,
          kind: task.kind,
          status: task.status,
          due_str: task.due_at&.strftime('%d.%m.%y %H:%M'),
          created_str: task.created_at.strftime('%d.%m.%y %H:%M')
        }
      end

      def self.serialize_leads_routed(target, range)
        leads = LeadEvent.routed_by_tg(target).updated_in(range)
                         .order(updated_at: :desc).limit(MAX_RESULTS_PER_LIST).to_a
        {
          count: LeadEvent.routed_by_tg(target).updated_in(range).count,
          items: leads.map { |le| serialize_lead(le, with_assignee: false) }
        }
      end

      def self.serialize_leads_assigned(target, range)
        leads = LeadEvent.assigned_by_tg(target).updated_in(range)
                         .order(updated_at: :desc).limit(MAX_RESULTS_PER_LIST)
                         .includes(:assigned_to).to_a
        {
          count: LeadEvent.assigned_by_tg(target).updated_in(range).count,
          items: leads.map { |le| serialize_lead(le, with_assignee: true) }
        }
      end

      def self.serialize_lead(le, with_assignee:)
        h = {
          id: le.id,
          topic: le.anchor_topic_key,
          stage: le.current_stage,
          updated_str: le.updated_at.strftime('%d.%m.%y %H:%M'),
          anchor_url: le.anchor_url
        }
        h[:assignee] = le.assigned_to&.mention if with_assignee
        h
      end
    end
  end
end
