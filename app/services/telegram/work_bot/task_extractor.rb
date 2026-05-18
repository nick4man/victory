# frozen_string_literal: true

module Telegram
  module WorkBot
    # Phase 7.2 — LLM-extractor задач из транскрипта voice-сообщения Оксаны.
    #
    # Input: raw transcript (с PII; redactor применится позже на storage) +
    # список активных сотрудников (для матчинга «Васе» → @vasya_petrov).
    # Output: структурированный JSON массив задач + uncertainties.
    #
    # Цепочка LLM — :analysis (OmniClient chain — start gpt-oss-120b free →
    # qwen3 → glm-4.5 → Claude как last-resort). JSON-mode для надёжности
    # парсинга.
    #
    # @example
    #   ex = TaskExtractor.new(
    #     transcript: 'Васе позвонить клиенту Анна до 16:00, Маше показать ул. Ленина',
    #     staff: TelegramUser.active.to_a,
    #     now: Time.current
    #   )
    #   res = ex.call
    #   res.success?          # => true
    #   res.tasks             # => [{assignee_username:, title:, due_at:, priority:, kind:}, ...]
    #   res.uncertainties     # => ['кто такая Маша? - не найдена в staff']
    #   res.model             # => "groq/openai/gpt-oss-120b"
    class TaskExtractor
      class Error < StandardError; end

      PRIORITIES = ['low', 'normal', 'high', 'urgent'].freeze
      KINDS      = ['call', 'show', 'document', 'admin', 'other'].freeze

      Result = Struct.new(:tasks, :uncertainties, :model, :raw, :error, keyword_init: true) do
        def success? = error.nil?
      end

      def self.call(...)
        new(...).call
      end

      def initialize(transcript:, staff:, now: Time.current, client: Llm::OmniClient.new)
        @transcript = transcript.to_s
        @staff      = Array(staff)
        @now        = now
        @client     = client
      end

      def call
        return empty_result('пустой транскрипт') if @transcript.strip.empty?

        res = @client.complete(
          [{ role: 'system', content: system_prompt },
           { role: 'user',   content: user_prompt }],
          chain: :staff_analysis, # Phase 9 Iter 6 — cheap-first (free → Haiku → Sonnet)
          response_format: { type: 'json_object' },
          temperature: 0.2,
          max_tokens: 1500
        )
        parsed = parse_response(res[:content])
        Result.new(
          tasks: normalize_tasks(parsed['tasks']),
          uncertainties: Array(parsed['uncertainties']),
          model: res[:model],
          raw: res[:content],
          error: nil
        )
      rescue StandardError => e
        Rails.logger.error("[TaskExtractor] #{e.class}: #{e.message}")
        empty_result(e.message)
      end

      private

      def empty_result(error)
        Result.new(tasks: [], uncertainties: [], model: nil, raw: nil, error: error)
      end

      def system_prompt
        <<~PROMPT.strip
          Ты — ассистент директора агентства недвижимости «Виктори». Директор Оксана голосом
          диктует список задач для сотрудников АН. Твоя задача — извлечь структурированные
          задачи в JSON.

          Активные сотрудники (используй ТОЛЬКО их @username при назначении):
          #{staff_block}

          Текущее время: #{@now.strftime('%d.%m.%y %H:%M')} (Moscow time).

          Правила извлечения:
          1. Каждая отдельная задача — отдельный объект в `tasks` массиве.
          2. assignee_username — ОБЯЗАТЕЛЬНО match с одним из @username выше (case-insensitive,
             "Васе/Ваське/Василий" → @vasya_petrov). Если не уверен — пиши в uncertainties.
          3. due_at — ISO8601 datetime (YYYY-MM-DDTHH:MM:SS). Парси относительные «до 16:00»
             (сегодня 16:00), «завтра в 14:00», «к пятнице», «до конца недели» (пятница 18:00).
             Если дедлайн не указан — null.
          4. priority — one of: #{PRIORITIES.join('/')}. Default normal. «срочно» → urgent.
          5. kind — one of: #{KINDS.join('/')}. call=звонок, show=показ, document=договор/документы,
             admin=внутренние/координация, other=иное.
          6. related_property_address — если есть упоминание адреса/ЖК → строка адреса; иначе null.
          7. uncertainties — массив СТРОК с проблемами: неоднозначные имена, неясные дедлайны,
             непонятные адреса. Пиши на русском.

          Верни СТРОГО JSON:
          {
            "tasks": [
              {
                "assignee_username": "vasya_petrov",
                "title": "позвонить клиенту Анна",
                "due_at": "2026-05-17T16:00:00",
                "priority": "normal",
                "kind": "call",
                "related_property_address": null
              }
            ],
            "uncertainties": []
          }
        PROMPT
      end

      def user_prompt
        "Транскрипт голосового сообщения Оксаны:\n\n#{@transcript}"
      end

      def staff_block
        return '(нет активных сотрудников)' if @staff.empty?

        @staff.filter_map do |s|
          uname = s.tg_username
          next if uname.blank?

          full = [s.first_name, s.last_name].compact_blank.join(' ').presence || uname
          "  • @#{uname} — #{full}"
        end.join("\n")
      end

      def parse_response(content)
        return {} if content.blank?

        # OmniClient JSON-mode гарантирует валидный JSON в content
        JSON.parse(content)
      rescue JSON::ParserError => e
        Rails.logger.warn("[TaskExtractor] JSON parse failed: #{e.message}; content: #{content.to_s.truncate(200)}")
        {}
      end

      def normalize_tasks(raw_tasks)
        Array(raw_tasks).filter_map do |t|
          next unless t.is_a?(Hash)

          normalized = {
            assignee_username: normalize_username(t['assignee_username']),
            title: t['title'].to_s.strip,
            due_at: parse_due_at(t['due_at']),
            priority: normalize_enum(t['priority'], PRIORITIES, 'normal'),
            kind: normalize_enum(t['kind'], KINDS, 'other'),
            related_property_address: t['related_property_address'].presence
          }.compact

          # Phase 10 Iter 20 — Quality gate: skip garbled tasks
          # (no title OR no assignee). Free-chain LLM иногда возвращает
          # `{tasks: [{assignee_username: null, title: ""}]}` — раньше
          # persist'или мусор, теперь skip + record в uncertainties (внешний caller
          # должен escalate если >50% tasks filtered).
          next if normalized[:title].blank?

          normalized
        end
      end

      def normalize_username(raw)
        raw.to_s.strip.sub(/\A@/, '').downcase.presence
      end

      def normalize_enum(value, allowed, default)
        v = value.to_s.downcase
        allowed.include?(v) ? v : default
      end

      def parse_due_at(raw)
        return nil if raw.blank?

        Time.zone.parse(raw.to_s)
      rescue ArgumentError
        nil
      end
    end
  end
end
