# frozen_string_literal: true

module ChatTools
  module Staff
    # Phase 15 — FTS поиск по сохранённым сообщениям рабочего чата.
    # Используется директором/менеджером из DM для аудита: «кто что писал
    # про Канищево», «какие сообщения от Ирины за неделю», «найди обсуждение
    # сделки в #КВАРТИРЫ».
    #
    # Backed by `telegram_group_messages` table (generated tsvector + russian
    # dict). Параллельно с file-save в InboxSaver идёт DB-upsert.
    #
    # Security: manager+ только. Agent role — silent empty result
    # (consistency с director_self_audit pattern).
    module SearchGroupMessages
      MAX_LIMIT = 50
      DEFAULT_LIMIT = 20
      BODY_EXCERPT_CHARS = 200

      def self.schema
        {
          type: 'function',
          function: {
            name: 'search_group_messages',
            description: 'Полнотекстовый поиск по сообщениям рабочего чата. ' \
                         'Используй для запросов: «найди сообщения про Канищево», ' \
                         '«что Ирина писала на этой неделе», «обсуждение в #КВАРТИРЫ за вчера». ' \
                         'Russian-морфология учтена (клиенту = клиент). Manager+ only.',
            parameters: {
              type: 'object',
              required: ['query'],
              properties: {
                query: {
                  type: 'string',
                  description: 'Поисковая фраза (русский / английский ОК). Морфология учтена.'
                },
                sender_username: {
                  type: 'string',
                  description: 'TG @username отправителя (без @). Optional фильтр.'
                },
                topic: {
                  type: 'string',
                  description: 'Название топика (КВАРТИРЫ / ДОМА / ДИСПЕТЧЕРСКОЙ / СДЕЛКА / etc) ' \
                               'или ключ (apartments/houses/etc). Optional.'
                },
                period: {
                  type: 'string',
                  enum: %w[today yesterday this_week last_week this_month custom],
                  description: 'Optional. Если custom — также from_date/to_date.'
                },
                from_date: { type: 'string', description: 'для period=custom, dd.MM.yy' },
                to_date:   { type: 'string', description: 'для period=custom, dd.MM.yy' },
                limit: {
                  type: 'integer',
                  description: "1-#{MAX_LIMIT}, default #{DEFAULT_LIMIT}"
                }
              }
            }
          }
        }
      end

      def self.call(args = {}, asked_by: nil)
        caller = resolve_caller(args[:caller_tg_user_id], asked_by)
        return { error: 'caller_unknown' } if caller.nil?

        # Agent — silent empty (как в director_self_audit)
        return { count: 0, items: [], denied: 'manager+ only' } unless caller.manager_or_director?

        query = args[:query].to_s.strip
        return { error: 'empty_query' } if query.empty?

        scope = TelegramGroupMessage.fts(query)

        if args[:sender_username].present?
          uname = args[:sender_username].to_s.strip.sub(/\A@/, '').downcase
          scope = scope.where('LOWER(sender_username) = ?', uname)
        end

        if args[:topic].present?
          if (thread_id = resolve_topic_to_thread_id(args[:topic]))
            scope = scope.where(tg_thread_id: thread_id)
          end
        end

        if (range = resolve_range(args))
          scope = scope.in_period(range)
        end

        limit = [args[:limit].to_i, MAX_LIMIT].min
        limit = DEFAULT_LIMIT if limit <= 0
        items = scope.limit(limit).to_a

        {
          query: query,
          count: scope.except(:order).count,
          shown: items.size,
          period_label: period_label(args),
          items: items.map { |m| serialize(m) }
        }
      end

      def self.resolve_caller(caller_id, asked_by)
        return asked_by if asked_by.is_a?(::TelegramUser)
        return ::TelegramUser.find_by(id: caller_id) if caller_id.present?

        nil
      end

      # Принимает русское название («КВАРТИРЫ») или ключ («apartments»).
      def self.resolve_topic_to_thread_id(topic)
        topic = topic.to_s.strip
        key = ::Telegram::TopicRegistry.valid_key?(topic) ? topic : ::Telegram::TopicRegistry.key_by_title(topic)
        return nil if key.blank?

        ::Telegram::TopicRegistry.thread_id(key)
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
        when 'today'      then 'сегодня'
        when 'yesterday'  then 'вчера'
        when 'this_week'  then 'на этой неделе'
        when 'last_week'  then 'на прошлой неделе'
        when 'this_month' then 'в этом месяце'
        when 'custom'     then "#{args[:from_date]}–#{args[:to_date]}"
        else 'за всё время'
        end
      end

      def self.serialize(msg)
        {
          sender: msg.sender_label,
          body_excerpt: msg.body_excerpt(max_chars: BODY_EXCERPT_CHARS),
          payload_kind: msg.payload_kind,
          has_attachment: msg.has_attachment,
          sent_str: msg.sent_at.strftime('%d.%m.%y %H:%M'),
          tg_link: msg.tg_link
        }
      end
    end
  end
end
