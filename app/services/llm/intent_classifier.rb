# frozen_string_literal: true

module Llm
  # Phase 4D — Single-call LLM classifier для inbound client messages в TG-DM.
  # Routes между intake-pipeline и silent-drop.
  #
  # Intent categories (mutually exclusive):
  #   • inquiry       — genuine real-estate interest (buy/sell/rent/ask about listing)
  #   • question      — generic question that needs human response (e.g. «как работает агентство»)
  #   • appointment   — request to schedule viewing/meeting
  #   • complaint     — issue с прошлой сделкой / агентом
  #   • spam          — promotional / unrelated / obvious bot-spam
  #   • abuse         — harassment / hate / threats
  #   • test          — probing «hi» / «test» / single-word
  #   • unclear       — нельзя классифицировать (low confidence)
  #
  # Output: structured JSON через response_format. Free-first LLM chain
  # (Phase 9 Iter 6 :staff_analysis) — gpt-oss → qwen → glm → Claude haiku.
  # Spam/abuse → no token cost since first free model handles 99%.
  #
  # Privacy: input идёт LLM as-is (PII в text), но output не сохраняет input
  # text — только intent + confidence + reasoning_short. Caller responsible
  # для PII-redaction если persists input.
  class IntentClassifier
    INTENTS = %w[inquiry question appointment complaint spam abuse test unclear].freeze

    Result = Struct.new(:intent, :confidence, :reasoning, :model, :error, keyword_init: true) do
      def success?
        error.nil?
      end

      def actionable?
        # Intents которые требуют lead-intake processing
        %w[inquiry question appointment].include?(intent)
      end

      def droppable?
        %w[spam abuse].include?(intent)
      end
    end

    def self.call(...)
      new(...).call
    end

    def initialize(text:, sender_context: {}, client: ::Llm::OmniClient.new)
      @text = text.to_s
      @ctx = sender_context # {first_message_in_chat: bool, prior_inquiries_count: int}
      @client = client
    end

    def call
      return Result.new(intent: 'unclear', confidence: 0.0, error: 'empty input') if @text.strip.empty?

      res = @client.complete(
        [{ role: 'system', content: system_prompt },
         { role: 'user',   content: user_prompt }],
        chain: :staff_analysis,
        response_format: { type: 'json_object' },
        temperature: 0.1,
        max_tokens: 200
      )

      parsed = parse_response(res[:content])
      Result.new(
        intent: normalize_intent(parsed['intent']),
        confidence: parsed['confidence'].to_f.clamp(0.0, 1.0),
        reasoning: parsed['reasoning'].to_s[0, 200],
        model: res[:model],
        error: nil
      )
    rescue StandardError => e
      Rails.logger.warn("[Llm::IntentClassifier] #{e.class}: #{e.message}")
      Result.new(intent: 'unclear', confidence: 0.0, error: e.message)
    end

    private

    def system_prompt
      <<~PROMPT.strip
        Ты — classifier для inbound сообщений в Telegram-бота агентства недвижимости.
        Классифицируй intent сообщения в одну из категорий:
          • inquiry       — реальный интерес (купить/продать/арендовать недвижимость, спросить про объект)
          • question      — generic вопрос про услуги АН (как работаете, тарифы)
          • appointment   — запрос на показ/встречу
          • complaint     — жалоба на сделку/агента
          • spam          — реклама / нерелевант / промо-сообщения (биткоины, заработки)
          • abuse         — оскорбления, угрозы, harassment
          • test          — пробное «привет», «test», 1-2 слова без контекста
          • unclear       — нельзя точно классифицировать

        Контекст отправителя:
          first_message: #{@ctx[:first_message_in_chat] ? 'true (новый клиент)' : 'false (известный)'}
          prior_inquiries: #{@ctx[:prior_inquiries_count].to_i}

        Верни СТРОГО JSON:
        {
          "intent": "inquiry",
          "confidence": 0.85,
          "reasoning": "Клиент пишет 'хочу квартиру в центре, до 7млн' — явный buy intent"
        }
      PROMPT
    end

    def user_prompt
      "Сообщение клиента:\n\n#{@text}"
    end

    def parse_response(content)
      return {} if content.blank?

      JSON.parse(content)
    rescue JSON::ParserError => e
      Rails.logger.warn("[IntentClassifier] JSON parse failed: #{e.message}; content: #{content.to_s.truncate(200)}")
      {}
    end

    def normalize_intent(raw)
      v = raw.to_s.downcase.strip
      INTENTS.include?(v) ? v : 'unclear'
    end
  end
end
