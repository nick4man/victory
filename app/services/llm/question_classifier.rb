# frozen_string_literal: true

module Llm
  # Phase 7.5 — Single LLM call (chain :analysis) → классифицирует вопрос
  # сотрудника в одну из 3 категорий:
  #
  #   clarification — детали по конкретной задаче/лиду; bot can answer
  #                   через chat_tools/staff (list_my_open_tasks, lookup_lead, ...)
  #   information   — общее знание АН (тарифы, процедуры, шаблоны, программы);
  #                   bot отвечает из system prompt + general LLM knowledge
  #   escalation    — нужен живой manager: клиент требует нестандарт, конфликт,
  #                   юридический вопрос, моральная дилемма, претензия.
  #
  # @example
  #   r = Llm::QuestionClassifier.call('Какие у меня задачи на завтра?')
  #   r.kind        # => "clarification"
  #   r.confidence  # => 0.92
  #   r.reasoning   # => "Запрос о своих задачах — детали по работе"
  class QuestionClassifier
    Result = Struct.new(:kind, :confidence, :reasoning, :model, :error,
                        keyword_init: true) do
      def success? = error.nil?
    end

    KINDS = StaffQuestion::KINDS

    def self.call(...)
      new(...).call
    end

    def initialize(question_text:, client: Llm::OmniClient.new)
      @text   = question_text.to_s.strip
      @client = client
    end

    def call
      return empty('пустой текст') if @text.empty?

      res = @client.complete(
        [{ role: 'system', content: system_prompt },
         { role: 'user',   content: @text }],
        chain: :analysis,
        response_format: { type: 'json_object' },
        temperature: 0.1,
        max_tokens: 400
      )
      parsed = JSON.parse(res[:content].to_s)
      Result.new(
        kind: normalize_kind(parsed['kind']),
        confidence: parsed['confidence'].to_f.clamp(0.0, 1.0),
        reasoning: parsed['reasoning'].to_s.truncate(200),
        model: res[:model],
        error: nil
      )
    rescue StandardError => e
      Rails.logger.warn("[QuestionClassifier] #{e.class}: #{e.message}")
      empty(e.message)
    end

    private

    def empty(error)
      Result.new(kind: 'information', confidence: 0.0, reasoning: nil, model: nil, error: error)
    end

    def normalize_kind(raw)
      v = raw.to_s.downcase
      KINDS.include?(v) ? v : 'information'
    end

    def system_prompt
      <<~PROMPT.strip
        Классифицируй вопрос сотрудника АН «Виктори» (real-estate агентство, Рязань) в одну из 3 категорий:

        1. clarification — вопрос про КОНКРЕТНУЮ задачу/лида/сделку. Примеры:
           • "Какие у меня задачи на завтра?"
           • "Где документы по сделке 117338580?"
           • "Какой статус у лида Анна Петрова?"
           • "Кто назначен на квартиру на Сенной?"
           → бот может ответить через chat_tools (БД lookup)

        2. information — общее знание/процедура АН/юридический ликбез. Примеры:
           • "Какая у нас комиссия по агентскому?"
           • "Какие документы нужны для ипотеки СБЕР?"
           • "Где шаблон договора аренды?"
           • "Как оформить задаток?"
           → бот отвечает из system prompt + LLM general knowledge

        3. escalation — нужен живой manager/director. Примеры:
           • "Клиент требует скидку 20%, что делать?"
           • "Покупатель угрожает съехать с задатка"
           • "Спорная ситуация по комиссии с агентом"
           • "Клиент жалуется на сотрудника"
           → bot НЕ должен решать; нужен manager

        Верни СТРОГО JSON:
        {
          "kind": "clarification|information|escalation",
          "confidence": 0.0-1.0,
          "reasoning": "короткое объяснение"
        }
      PROMPT
    end
  end
end
