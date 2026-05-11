# frozen_string_literal: true

module Llm
  # Pre-LLM filter for incoming user messages. Three outcomes:
  #
  #   :allowed    — pass to LLM as usual
  #   :off_topic  — clearly outside our scope (crypto, weather, recipes, politics, …)
  #   :injection  — recognisable jailbreak / prompt-override attempt
  #
  # The LLM's system prompt has a strong preamble against both, but doing this
  # check pre-LLM saves tokens, blocks ~80% of crude attempts, and gives us a
  # log we can analyse for blocking visitors who attack repeatedly.
  module ScopeGuard
    INJECTION_PATTERNS = [
      /ignore (the )?(previous|all|prior) (instructions|rules|prompts)/i,
      /forget (everything|all|previous|your)/i,
      /system\s*[:\-]\s*you/i,
      /you (are|should be|will be) now/i,
      /\bact as (a|an)\b(?! (real estate|агент|консультант))/i,
      /<<<ESCALATE/i,                                  # don't let a visitor forge our internal escalation marker
      /\b(jailbreak|developer mode|do anything now)\b/i,
      /(?<![a-zа-я])DAN(?![a-zа-я])/,                  # standalone DAN (any context — "ты DAN", "act as DAN")
      /ты\s+(теперь|сейчас)\s+(?!консультант|агент)/i, # "ты теперь X" — role-override attempt
      /без\s+ограничений/i,
      /напиши\s+(мне\s+)?(код|программу|скрипт|на\s+python|на\s+javascript|на\s+ruby)/i,
      /реши\s+(за\s+меня|мне)\s+задачу/i,
      /переведи\s+(на|с)\s+\S+/i,                      # \S also matches Cyrillic; \w doesn't reliably
      /(дай|покажи|выведи)\s+(мне\s+)?(системный\s+промпт|свой\s+промпт|твой\s+промпт|инструкции)/i,
      /repeat\s+(your|the)\s+(system|initial)\s+prompt/i,
      /tell me your (system )?prompt/i
    ].freeze

    OFF_TOPIC_KEYWORDS = %w[
      bitcoin биткойн биткоин криптовалют crypto акции форекс forex биржа
      погода рецепт фильм игра сериал музыка
      политик выборы президент война
      анекдот стих
    ].freeze

    REAL_ESTATE_KEYWORDS = %w[
      квартир комнат дом дач участ земл коммерч гараж студи
      купи прода аренд снять оценк ипотек агент район
      метр сот гектар цен бюджет ремонт балкон лодж
      виктори victory агентств показ просмотр недвижимост
      этаж планир торг сделк юр документ
      отзыв feedback оценить рекоменд довол благодар жалоб претенз похвал
      спасибо признат поделит впечатлен опыт
    ].freeze

    module_function

    # @param text [String]
    # @return [Symbol]
    def classify(text)
      t = text.to_s.downcase

      return :injection if INJECTION_PATTERNS.any? { |re| re.match?(t) }

      has_re  = REAL_ESTATE_KEYWORDS.any?  { |k| t.include?(k) }
      has_off = OFF_TOPIC_KEYWORDS.any?    { |k| t.include?(k) }
      return :off_topic if has_off && !has_re

      :allowed
    end

    # Static replies for the two non-allowed verdicts.
    REPLIES = {
      injection:  'Я отвечаю только по теме недвижимости и услуг АН «Виктори». Чем могу помочь по этой теме?',
      off_topic:  'Я могу помочь только с недвижимостью и услугами нашего агентства. Хотите подобрать объект или задать вопрос про продажу/аренду?'
    }.freeze
  end
end
