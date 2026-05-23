# frozen_string_literal: true

module ChatTools
  module Staff
    # Phase 15.5 — LLM-summarization для обсуждений в рабочем чате.
    # Расширение Phase 15 READ pillar: SearchGroupMessages находит relevant
    # сообщения, этот tool их СУММИРУЕТ через analysis-chain LLM.
    #
    # Use cases (для director DM):
    #   • «суммируй вчерашние обсуждения в #КВАРТИРЫ»
    #   • «что Ирина писала по Канищево за неделю — кратко»
    #   • «дай сводку группового чата за сегодня»
    #
    # Algorithm:
    #   1. Фильтрация по sender/topic/period (тот же range builder что SearchGroupMessages)
    #   2. Optional query — FTS pre-filter перед summarization
    #   3. Сбор тОП-50 messages в текст для LLM context
    #   4. LLM analysis chain (free-first: gpt-oss → glm → qwen → groq)
    #   5. Structured markdown: ключевые темы / открытые вопросы / решения
    #
    # Cost: 50 messages × ~50 chars avg = ~2500 chars input. Free chain
    # хватает с запасом. Если на peak rate-limit — fallback на cheap chain.
    module SummarizeGroupMessages
      MAX_SOURCES = 50
      MIN_SOURCES = 3 # меньше — нет смысла summary
      MAX_BODY_CHARS_PER_MSG = 300

      SYSTEM_PROMPT = <<~PROMPT.strip
        Ты — аналитик корпоративных чатов агентства недвижимости «Виктори»
        (АН в Рязани). Тебе даны сообщения из рабочего Telegram-чата
        сотрудников. Сделай structured summary для руководителя.

        ЗАДАЧА: сжать N сообщений в 3 секции:
          📌 **Темы** — 2-5 главных тем обсуждения (по 1 строке)
          ❓ **Открытые вопросы** — что не закрыто, требует решения
          ✅ **Решения** — что договорились / сделали

        Формат:
          • Bullet points, каждый ≤ 100 chars
          • Без markdown headings (только bold через **)
          • Без эмодзи кроме section icons (📌 ❓ ✅)
          • Если нет открытых вопросов / решений — секцию ОПУСТИТЬ (не пиши «нет»)
          • Каждый bullet содержит @username если упомянут источник

        Контекст: сообщения от сотрудников АН (директор Оксана, manager Николай,
        агенты). Они обсуждают сделки, клиентов, документы, недвижимость.

        НЕ выдумывай — только то что реально написано. Сохраняй имена клиентов
        и адреса как есть.

        ОТВЕТ — Russian plaintext с **bold**, без markdown headings.
      PROMPT

      def self.schema
        {
          type: 'function',
          function: {
            name: 'summarize_group_messages',
            description: 'LLM-summary обсуждений в рабочем чате. Используй для запросов: ' \
                         '«суммируй вчерашние обсуждения», «сводка по #КВАРТИРЫ за неделю», ' \
                         '«что Ирина писала про Канищево — кратко». Подходит когда сообщений ' \
                         'много (>5) и нужен анализ а не список. Для точечного поиска — ' \
                         'используй search_group_messages вместо. Manager+ only.',
            parameters: {
              type: 'object',
              properties: {
                query: { type: 'string', description: 'Optional FTS-pre-filter перед summarization' },
                sender_username: { type: 'string', description: 'TG @username (без @) — sender filter' },
                topic: { type: 'string', description: 'Топик: КВАРТИРЫ / apartments / etc' },
                period: {
                  type: 'string',
                  enum: %w[today yesterday this_week last_week this_month custom],
                  description: 'Optional. Default today если ничего не задано.'
                },
                from_date: { type: 'string', description: 'для period=custom, dd.MM.yy' },
                to_date:   { type: 'string', description: 'для period=custom, dd.MM.yy' }
              }
            }
          }
        }
      end

      def self.call(args = {}, asked_by: nil)
        caller = resolve_caller(args[:caller_tg_user_id], asked_by)
        return { error: 'caller_unknown' } if caller.nil?
        return { count: 0, summary: nil, denied: 'manager+ only' } unless caller.manager_or_director?

        messages = fetch_messages(args)

        if messages.size < MIN_SOURCES
          return {
            count: messages.size,
            summary: nil,
            note: "Недостаточно сообщений для summary (нужно ≥#{MIN_SOURCES}, нашёл #{messages.size}). " \
                  'Попробуй расширить период или убрать фильтры.'
          }
        end

        llm_response = run_llm_summary(messages, args)

        {
          count: messages.size,
          period_label: period_label(args),
          summary: llm_response[:content],
          model: llm_response[:model],
          source_ids: messages.map(&:id)
        }
      rescue StandardError => e
        Rails.logger.warn("[SummarizeGroupMessages] #{e.class}: #{e.message}")
        { error: 'tool_failed', message: e.message.to_s.truncate(180) }
      end

      def self.resolve_caller(caller_id, asked_by)
        return asked_by if asked_by.is_a?(::TelegramUser)
        return ::TelegramUser.find_by(id: caller_id) if caller_id.present?

        nil
      end

      def self.fetch_messages(args)
        scope = if args[:query].present?
                  TelegramGroupMessage.fts(args[:query])
                else
                  # Default — последние по времени из периода (newest first для context)
                  TelegramGroupMessage.where.not(body: [nil, '']).order(sent_at: :asc)
                end

        if args[:sender_username].present?
          uname = args[:sender_username].to_s.strip.sub(/\A@/, '').downcase
          scope = scope.where('LOWER(sender_username) = ?', uname)
        end

        if args[:topic].present? && (thread_id = resolve_topic_to_thread_id(args[:topic]))
          scope = scope.where(tg_thread_id: thread_id)
        end

        # Ruby precedence gotcha: `a || b..c` парсится как `(a || b)..c`, не
        # `a || (b..c)`. Без paren resolve_range(args) попадает в start Range,
        # ArgumentError "bad value for range". 23.05.26 inflight bug fix.
        range = resolve_range(args) || (Time.current.beginning_of_day..Time.current.end_of_day)
        scope = scope.where(sent_at: range)

        scope.limit(MAX_SOURCES).to_a
      end

      def self.run_llm_summary(messages, args)
        context_lines = messages.map do |m|
          ts = m.sent_at.strftime('%d.%m %H:%M')
          sender = m.sender_label
          body = m.body.to_s.gsub(/\s+/, ' ').strip.truncate(MAX_BODY_CHARS_PER_MSG)
          "[#{ts} #{sender}] #{body}"
        end

        user_prompt = "Сообщения (#{messages.size}) из периода: #{period_label(args)}\n\n#{context_lines.join("\n")}"

        client = ::Llm::OmniClient.new
        res = client.complete(
          [{ role: 'system', content: SYSTEM_PROMPT },
           { role: 'user',   content: user_prompt }],
          chain: :analysis,
          temperature: 0.3,
          max_tokens: 600
        )
        { content: res[:content].to_s.strip, model: res[:model] }
      end

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
        else 'сегодня (default)'
        end
      end
    end
  end
end
