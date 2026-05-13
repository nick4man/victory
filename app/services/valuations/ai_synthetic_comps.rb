# frozen_string_literal: true

module Valuations
  # Generates "shadow comparables" via LLM when the real-comp pool is too
  # thin to support a confident hedonic estimate. The model is anchored
  # by the city median (`CityMedianPrice`) and the subject's known
  # characteristics; it returns plausible variations (different floors,
  # year, condition) with explicit `adjustment_pct` so the consumer
  # can fold them into the same weighted-median as real comps.
  #
  # Honesty: every returned comp carries `source: 'ai_synthesized'` so
  # the UI can clearly mark them as «расчётный аналог» rather than a
  # real listing.
  #
  # Cost: one LLM call (chain: :analysis, free-first), ~600 tokens. Cached
  # in Redis 24h by subject hash.
  class AiSyntheticComps
    SOURCE_TAG  = 'ai_synthesized'
    TARGET_N    = 7
    MAX_TOKENS  = 1200
    TEMPERATURE = 0.4
    CACHE_TTL   = 24 * 60 * 60

    def self.call(valuation, city_anchor_pps: nil)
      new(valuation, city_anchor_pps: city_anchor_pps).call
    end

    def initialize(valuation, city_anchor_pps: nil)
      @v = valuation
      @city_anchor_pps = city_anchor_pps ||
                        (CityMedianPrice.lookup(@v.city, @v.property_type) rescue nil)
    end

    def call
      return [] if @city_anchor_pps.nil? || @city_anchor_pps.to_i.zero?
      return [] if @v.total_area.to_f.zero?

      cached = read_cache
      return parse_comps(cached) if cached

      raw = run_llm
      return [] if raw.blank?

      write_cache(raw)
      parse_comps(raw)
    rescue StandardError => e
      Rails.logger.warn("[AiSyntheticComps] #{e.class}: #{e.message.truncate(180)}")
      []
    end

    private

    def run_llm
      client = Llm::OmniClient.new
      response = client.complete(
        [
          { role: 'system', content: SYSTEM_PROMPT },
          { role: 'user',   content: build_user_prompt }
        ],
        chain: :analysis,
        max_tokens: MAX_TOKENS,
        temperature: TEMPERATURE,
        response_format: { type: 'json_object' }
      )
      response&.dig(:content)
    end

    SYSTEM_PROMPT = <<~PROMPT.freeze
      Ты — эксперт-оценщик недвижимости. Твоя задача — сгенерировать
      набор из 5-8 правдоподобных аналогов для указанного объекта,
      используя медианную цену по городу как анкор и характеристики
      subject как вариативную базу.

      Возвращай СТРОГО JSON-объект формата:
      {
        "comps": [
          {
            "title": "1-2 строки описания (без указания адреса)",
            "price_per_sqm": int (₽/м²),
            "area": float (м²),
            "rooms": int (для нежилых — 0),
            "floor": int|null,
            "total_floors": int|null,
            "year": int|null,
            "condition": "needs_repair|average|good|excellent|designer",
            "adjustment_pct": int -15..+15 (поправка к цене аналога относительно subject),
            "rationale": "1 предложение почему такая цена"
          },
          ...
        ]
      }

      Каждый comp должен отличаться от subject хотя бы одним параметром
      (этаж/площадь/состояние/год). Цены реалистичны: разброс ±25% от
      city_anchor. Без markdown-блоков, только JSON.
    PROMPT

    def build_user_prompt
      <<~PROMPT
        SUBJECT:
        - тип: #{type_label}
        - площадь: #{@v.total_area} м²
        - комнат: #{@v.rooms.presence || 'н/д'}
        - этаж: #{@v.floor.presence || 'н/д'}/#{@v.total_floors.presence || 'н/д'}
        - год постройки: #{@v.building_year.presence || 'н/д'}
        - состояние: #{@v.property_condition.presence || 'н/д'}
        - район: #{@v.district.presence || 'н/д'}
        - город: #{@v.city.presence || 'Рязань'}

        Медиана города (анкор): #{@city_anchor_pps} ₽/м²

        Сгенерируй 5-8 синтетических аналогов в JSON.
      PROMPT
    end

    def type_label
      {
        'apartment'  => 'Квартира',
        'room'       => 'Комната',
        'house'      => 'Дом',
        'land'       => 'Земельный участок',
        'commercial' => 'Коммерческая недвижимость',
        'garage'     => 'Гараж'
      }[@v.property_type.to_s] || @v.property_type.to_s
    end

    def parse_comps(raw_json)
      parsed = JSON.parse(raw_json.to_s)
      comps = parsed['comps'] || parsed[:comps] || []
      return [] unless comps.is_a?(Array)

      comps.first(TARGET_N).filter_map { |c| build_comp(c) }
    rescue JSON::ParserError => e
      Rails.logger.warn("[AiSyntheticComps] json parse: #{e.message.truncate(120)}")
      []
    end

    def build_comp(raw)
      h = raw.is_a?(Hash) ? raw.with_indifferent_access : nil
      return nil unless h

      pps = h[:price_per_sqm].to_i
      area = h[:area].to_f.positive? ? h[:area].to_f : @v.total_area.to_f
      return nil if pps.zero? || area.zero?

      price = (pps * area).round
      adj = h[:adjustment_pct].to_i.clamp(-15, 15)

      {
        title:         h[:title].to_s.truncate(80),
        price:         price,
        price_per_sqm: pps,
        area:          area,
        rooms:         h[:rooms].to_i,
        floor:         h[:floor].to_i,
        total_floors:  h[:total_floors].to_i,
        building_year: h[:year].to_i,
        condition:     h[:condition].to_s,
        district:      @v.district,
        city:          @v.city,
        source:        SOURCE_TAG,
        ai_adjustment: adj,
        ai_rationale:  h[:rationale].to_s,
        weight:        0.3,  # see plan: AI shadow comps get weight 0.3
        synthetic:     true
      }
    end

    def cache_key
      @cache_key ||= "ai_synth_comps:#{Digest::MD5.hexdigest(subject_signature)}:v1"
    end

    def subject_signature
      [
        @v.property_type, @v.city, @v.district, @v.total_area.to_i,
        @v.rooms, @v.floor, @v.total_floors, @v.building_year,
        @v.property_condition, @city_anchor_pps
      ].join('|')
    end

    def read_cache
      Rails.cache.read(cache_key)
    end

    def write_cache(raw)
      Rails.cache.write(cache_key, raw, expires_in: CACHE_TTL)
    end
  end
end
