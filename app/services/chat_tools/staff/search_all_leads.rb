# frozen_string_literal: true

module ChatTools
  module Staff
    # Phase 15 — cross-staff поиск лидов с FTS по metadata.
    # Расширение `lookup_lead` — но с filtering по assignee/stage/topic/period
    # и optional text query через search_tsv generated column.
    #
    # FTS поиск по metadata.summary + metadata.name + metadata.notes (объединено
    # в search_tsv generated column через миграцию add_search_tsv_to_lead_events).
    #
    # Security: manager+ всё. Agent — silent self-only (assignee = caller).
    module SearchAllLeads
      MAX_RESULTS = 30
      ALLOWED_STAGES = ::LeadEvent::STAGES
      ALLOWED_TOPICS = ::LeadEvent::TOPIC_KEYS

      def self.schema
        {
          type: 'function',
          function: {
            name: 'search_all_leads',
            description: 'Поиск лидов cross-staff с FTS + фильтрами (assignee, stage, topic, period). ' \
                         'Используй для: «найди лиды по Канищево», «открытые лиды Ирины», ' \
                         '«какие лиды на стадии показа», «лиды направленные в #КВАРТИРЫ за неделю». ' \
                         'FTS учитывает русскую морфологию. Agent видит только свои.',
            parameters: {
              type: 'object',
              properties: {
                query: { type: 'string', description: 'Optional FTS-search по summary/name/notes' },
                assigned_username: { type: 'string', description: '@username assignee (без @)' },
                assigned_by_username: { type: 'string', description: '@username кто назначил (Iter 59 FK)' },
                routed_by_username: { type: 'string', description: '@username кто маршрутизировал' },
                current_stage: { type: 'string', enum: ALLOWED_STAGES },
                topic: { type: 'string', description: 'Топик (КВАРТИРЫ / apartments / etc) или ключ' },
                period: {
                  type: 'string',
                  enum: %w[today yesterday this_week last_week this_month custom],
                  description: 'Фильтр по updated_at в указанном диапазоне'
                },
                from_date: { type: 'string', description: 'для period=custom, dd.MM.yy' },
                to_date:   { type: 'string', description: 'для period=custom, dd.MM.yy' },
                only_open: { type: 'boolean', description: 'true — не показывать closed_won/closed_lost' }
              }
            }
          }
        }
      end

      def self.call(args = {}, asked_by: nil)
        caller = resolve_caller(args[:caller_tg_user_id], asked_by)
        return { error: 'caller_unknown' } if caller.nil?

        scope = ::LeadEvent.all

        # Agent — silent self-only по assigned_to
        unless caller.manager_or_director?
          scope = scope.where(assigned_to_id: caller.id)
        else
          scope = apply_user_filter(scope, args[:assigned_username], :assigned_to_id)
          scope = apply_user_filter(scope, args[:assigned_by_username], :assigned_by_id)
          scope = apply_user_filter(scope, args[:routed_by_username], :routed_by_id)
        end

        if args[:query].present?
          q = args[:query].to_s
          scope = scope.where(
            'search_tsv @@ plainto_tsquery(?, ?)',
            'russian', q
          ).order(
            Arel.sql("ts_rank_cd(search_tsv, plainto_tsquery('russian', #{::ActiveRecord::Base.connection.quote(q)})) DESC")
          )
        end

        scope = scope.where(current_stage: args[:current_stage]) if ALLOWED_STAGES.include?(args[:current_stage].to_s)

        if args[:topic].present?
          key = ::Telegram::TopicRegistry.valid_key?(args[:topic].to_s) ? args[:topic].to_s : ::Telegram::TopicRegistry.key_by_title(args[:topic].to_s)
          scope = scope.where(anchor_topic_key: key) if key.present?
        end

        if (range = resolve_range(args))
          scope = scope.updated_in(range)
        end

        scope = scope.open if args[:only_open]

        # Default order — updated_at desc если нет FTS-ranking
        if args[:query].blank?
          scope = scope.order(updated_at: :desc)
        end

        leads = scope.limit(MAX_RESULTS).includes(:assigned_to, :assigned_by, :routed_by).to_a

        {
          count: scope.except(:order).count,
          shown: leads.size,
          period_label: period_label(args),
          items: leads.map { |le| serialize(le) }
        }
      end

      def self.resolve_caller(caller_id, asked_by)
        return asked_by if asked_by.is_a?(::TelegramUser)
        return ::TelegramUser.find_by(id: caller_id) if caller_id.present?

        nil
      end

      def self.apply_user_filter(scope, username, fk_field)
        return scope if username.blank?

        if (u = ::TelegramUser.find_by('LOWER(tg_username) = ?', username.to_s.sub(/\A@/, '').downcase))
          scope.where(fk_field => u.id)
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

      def self.serialize(le)
        meta = le.metadata || {}
        {
          id: le.id,
          stage: le.current_stage,
          topic: le.anchor_topic_key,
          assignee: le.assigned_to&.mention,
          assigned_by: le.assigned_by&.mention,
          routed_by: le.routed_by&.mention,
          name: meta['name'],
          summary: meta['summary'].to_s.truncate(150),
          source: le.source,
          updated_str: le.updated_at.strftime('%d.%m.%y %H:%M'),
          tg_link: le.anchor_url
        }
      end
    end
  end
end
