# frozen_string_literal: true

class Property
  # Classifies a commercial property's commercial-type for YRL feed
  # (Я.Realty) via LLM analysis of title + description.
  #
  # Inputs: Property с deal description + title. Output: one of
  # YRL spec values (VALID_TYPES). Если LLM возвращает unknown value
  # или fails — fallback на 'свободного назначения' (safest catch-all,
  # Я.Realty accepts).
  #
  # Free-first chain (Llm::OmniClient :analysis) — gpt-oss-120b → glm-4.5-air
  # → qwen3 → groq llama → cerebras → cloudflare-llama → gemini → deepseek
  # → claude (paid only as last resort).
  class CommercialTypeClassifier
    # YRL spec — Я.Realty валидирует только эти значения для
    # <commercial-type>. Order matches Я.Realty docs frequency.
    VALID_TYPES = %w[
      офис
      торговое\ помещение
      свободного\ назначения
      склад
      производство
      общепит
      гостиница
      автосервис
      готовый\ бизнес
    ].freeze

    DEFAULT = 'свободного назначения'

    SYSTEM_PROMPT = <<~PROMPT
      Ты — классификатор коммерческой недвижимости для YRL фида Я.Realty.

      На входе title и description объекта. Определи ОДИН наиболее
      подходящий commercial-type из строго ограниченного списка:

        офис — кабинеты, бизнес-центр, опен-спейс, коворкинг
        торговое помещение — магазин, шоурум, бутик, ритейл, торговый зал
        свободного назначения — multi-use (можно под офис/склад/ритейл одновременно), универсальное
        склад — складские помещения, ангары
        производство — производственные цеха, индустриальные помещения
        общепит — ресторан, кафе, бар, столовая, фастфуд
        гостиница — отель, хостел, апарт-отель, гостевой дом
        автосервис — СТО, шиномонтаж, автомойка, авторемонт
        готовый бизнес — продаётся действующий бизнес со штатом и оборудованием (кафе, медцентр, салон красоты в работе)

      Если объект подходит под НЕСКОЛЬКО типов одновременно (например,
      "под офис ИЛИ склад ИЛИ ритейл") — выбирай "свободного назначения".

      Если объект — готовый медцентр / салон / кафе с указанием доходности
      и оборудования (а не голое помещение) — это "готовый бизнес".

      Если непонятно или description пустой — "свободного назначения".

      Отвечай ОДНИМ значением из списка, без объяснений и кавычек. Только
      ровно одна строка ровно из списка выше.
    PROMPT

    def self.call(property)
      new(property).call
    end

    def initialize(property)
      @property = property
    end

    def call
      return DEFAULT if input_text.blank?

      raw = ask_llm
      normalized = normalize(raw)
      return normalized if VALID_TYPES.include?(normalized)

      Rails.logger.info("[CommercialTypeClassifier] property=#{@property.id} llm_raw=#{raw.inspect[0, 60]} → falling back to default")
      DEFAULT
    rescue StandardError => e
      Rails.logger.warn("[CommercialTypeClassifier] property=#{@property.id} #{e.class}: #{e.message.truncate(160)}")
      DEFAULT
    end

    private

    def input_text
      parts = [@property.title.presence, @property.description.presence].compact
      return '' if parts.empty?

      parts.join("\n\n").to_s.strip
    end

    def ask_llm
      result = Llm::OmniClient.new.complete(
        [
          { role: 'system', content: SYSTEM_PROMPT },
          { role: 'user',   content: "Объект:\n#{input_text.truncate(2000)}" }
        ],
        chain: :analysis,
        max_tokens: 16,
        temperature: 0.0
      )
      result[:content].to_s
    end

    # LLM может вернуть с кавычками, точкой, capital case или leading hash —
    # нормализуем к bare strict lowercase trimmed string.
    def normalize(raw)
      raw.to_s.strip.downcase.delete('"\'.<>`').gsub(/\s+/, ' ').strip
    end
  end
end
