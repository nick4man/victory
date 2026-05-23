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
                only_open: { type: 'boolean', description: 'true — не показывать closed_won/closed_lost' },
                include_staff_test: {
                  type: 'boolean',
                  description: 'По умолчанию false — Phase 16 staff/test submissions ' \
                               '(«Тест Клиент», Надеждины оценки) скрываются. true — показать ' \
                               'весь dataset для debugging / audit.'
                },
                mode: {
                  type: 'string',
                  enum: %w[keyword semantic],
                  description: 'keyword (default) — точный поиск по metadata через tsvector. ' \
                               'semantic — векторный поиск по смыслу (Phase 16.6). ' \
                               'Применяй semantic для concept queries: «лиды с проблемами по подписи», ' \
                               '«недовольные клиенты», «лиды похожие на наш самый ценный».'
                }
              }
            }
          }
        }
      end

      def self.call(args = {}, asked_by: nil)
        # Phase 16.6 — reset semantic state per-call (thread-safety).
        @semantic_distances = nil

        caller = resolve_caller(args[:caller_tg_user_id], asked_by)
        return { error: 'caller_unknown' } if caller.nil?

        # Phase 16 — exclude staff_test=true по умолчанию.
        scope = args[:include_staff_test] ? ::LeadEvent.all : ::LeadEvent.where(staff_test: false)

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
          if args[:mode].to_s == 'semantic'
            # semantic_scope создаёт fresh scope (where(id: ids).order) — нам надо
            # сохранить уже применённые фильтры (staff_test, assignee, и т.д.).
            # Merge через scope.merge() сохраняет conditions + applies new order.
            sem = semantic_scope(q)
            scope = sem ? scope.merge(sem) : tsvector_scope(scope, q)
          else
            scope = tsvector_scope(scope, q)
          end
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

      # Phase 16.6 — tsvector scope (FTS) на lead_events.search_tsv. Был inline'нут,
      # extract'нул в helper чтобы semantic_scope мог fallback'ить.
      def self.tsvector_scope(scope, query)
        scope.where(
          'search_tsv @@ plainto_tsquery(?, ?)',
          'russian', query
        ).order(
          Arel.sql("ts_rank_cd(search_tsv, plainto_tsquery('russian', #{::ActiveRecord::Base.connection.quote(query)})) DESC")
        )
      end

      # Phase 16.6 — semantic search через LeadEventEmbedding (gemini cosine).
      # Hybrid robustness — на embed_fail caller возвращается к tsvector_scope.
      SIMILARITY_THRESHOLD = 0.50
      SEMANTIC_INITIAL_LIMIT = 40

      def self.semantic_scope(query)
        vec = ::Embedding::GoogleClient.new.embed(query)
        return nil if vec.blank?

        ranked = LeadEventEmbedding
                 .nearest_neighbors(:embedding, vec, distance: :cosine)
                 .limit(SEMANTIC_INITIAL_LIMIT)
                 .to_a
                 .select { |r| r.neighbor_distance < SIMILARITY_THRESHOLD }

        return nil if ranked.empty?

        @semantic_distances = ranked.to_h { |r| [r.lead_event_id, r.neighbor_distance] }
        ids = ranked.map(&:lead_event_id)
        order_sql = Arel.sql("array_position(ARRAY[#{ids.join(',')}]::bigint[], id)")
        ::LeadEvent.where(id: ids).order(order_sql)
      rescue ::Embedding::GoogleClient::Error, StandardError => e
        Rails.logger.warn("[SearchAllLeads#semantic_scope] #{e.class} #{e.message}")
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
        out = {
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
        if @semantic_distances && (dist = @semantic_distances[le.id])
          out[:similarity] = (1.0 - dist).round(3)
        end
        out
      end
    end
  end
end
