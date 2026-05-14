# frozen_string_literal: true

require 'json'

module Valuations
  # AI pre-filter for comparable listings. Each candidate goes through a
  # short LLM judgement: "is this object truly a comparable to subject?"
  # Verdict is JSON: { suitable: bool, reason: "…", adjustment: -15..+15 }.
  #
  # Rejected comps drop out before the statistical estimator (hedonic +
  # bootstrap) sees them — cleaner sample = tighter confidence interval.
  # Surviving comps carry an `ai_adjustment` percentage that the estimator
  # uses to nudge price upward/downward (e.g. when subject has euro-repair
  # and the candidate doesn't).
  #
  # Costs: 1 short LLM call per candidate. With our chain (chain: :analysis),
  # first attempt is a free model — only escalates to paid Sonnet when every
  # free option fails. Typical run: 8-15 candidates → ~$0 to ~$0.01 total.
  class AiCompFilter
    # Was 4 — too aggressive. Когда Sonnet корректно отвергал 11/11 weak
    # comps (студии для 100м² subject), guardrail fallback'ил к raw set
    # и терялся весь смысл AI judgement. После интеграции
    # WebsearchCompFinder (Tavily+Firecrawl) sample обычно богаче
    # external листингами, и filter может быть строже без риска empty.
    MIN_KEPT = 2
    MAX_TOKENS = 220
    TEMPERATURE = 0.2
    CACHE_TTL = 7 * 24 * 60 * 60  # 7 days

    SYSTEM_PROMPT_TEMPLATE = <<~PROMPT.freeze
      Ты — опытный оценщик недвижимости в городе {{CITY}}. Решаешь, годен ли
      данный объект как АНАЛОГ для оценки subject-объекта.

      Возвращай СТРОГО валидный JSON, без markdown-блоков:
      {"suitable": true|false, "reason": "1-2 предложения по-русски", "adjustment": -15..+15}

      `adjustment` — поправка в % к цене АНАЛОГА, если у subject есть отличия,
      которые рынок ценит выше/ниже. Например, если subject с евроремонтом, а
      аналог без ремонта — adjustment = +8 (аналог должен «стоить дороже» при
      приведении к subject). Без отличий — 0.

      Не подходят как аналоги:
      - другой район (особенно если центр vs окраина);
      - другая эпоха застройки (хрущёвка vs новостройка);
      - принципиально иной сегмент (студия vs 3-комн).

      Подходят с поправкой:
      - тот же район, схожая площадь ±25%, разница в этаже / годе / ремонте.
    PROMPT

    def initialize(subject, candidates, chain: :analysis)
      @subject = subject
      @candidates = candidates  # array of hashes from ComparableFinder
      @chain = chain
    end

    # @return [Array<Hash>] filtered comps with extra :ai_adjustment, :ai_reason keys
    def call
      kept = @candidates.filter_map do |comp|
        verdict = judge(comp)
        next nil unless verdict[:suitable]

        comp.merge(ai_adjustment: verdict[:adjustment].to_f, ai_reason: verdict[:reason])
      end

      # Guardrail: never strip the sample below MIN_KEPT — statistical
      # estimator needs a base population. Fall back to raw with a flag.
      if kept.size < MIN_KEPT && @candidates.size >= MIN_KEPT
        Rails.logger.info("[AiCompFilter] kept=#{kept.size} below MIN_KEPT=#{MIN_KEPT}, falling back to raw set")
        return @candidates.map { |c| c.merge(ai_adjustment: 0.0, ai_reason: 'fallback_raw_set') }
      end

      kept
    end

    private

    def judge(comp)
      cached = cache_lookup(comp)
      return cached if cached

      response = client.complete(
        [
          { role: 'system', content: system_prompt },
          { role: 'user',   content: build_prompt(comp) }
        ],
        chain: @chain,
        max_tokens: MAX_TOKENS,
        temperature: TEMPERATURE,
        response_format: { type: 'json_object' }
      )
      verdict = parse_verdict(response[:content])
      cache_store(comp, verdict)
      verdict
    rescue StandardError => e
      Rails.logger.warn("[AiCompFilter] judge failed: #{e.class}: #{e.message.to_s.truncate(160)}")
      # Default to keeping the comp at adjustment=0 — error must not silently
      # shrink the population. Better to use a possibly-bad comp than nothing.
      { suitable: true, reason: 'AI недоступен — оставлен как есть', adjustment: 0 }
    end

    # Resolve the city for the SYSTEM prompt — prefer subject.city (set by
    # DaData autocomplete), fall back to Рязань (the agency's home market).
    def system_prompt
      city = @subject.try(:city).presence || 'Рязани'
      SYSTEM_PROMPT_TEMPLATE.gsub('{{CITY}}', city)
    end

    def build_prompt(comp)
      record = comp[:record] || comp['record']
      [
        "SUBJECT: #{describe(@subject)}",
        "CANDIDATE: #{describe(record)} | цена #{record_price(record)} ₽ | источник #{source_of(record)}",
        comp[:distance_km] ? "Расстояние до subject: #{comp[:distance_km].round(1)} км" : nil,
        '',
        'Реши: годен ли как аналог? Объясни 1-2 предложениями.'
      ].compact.join("\n")
    end

    def describe(obj)
      parts = []
      parts << "#{obj.try(:rooms)}-комн." if obj.try(:rooms)
      parts << "#{format_area(obj)} м²"
      parts << obj.try(:address).to_s.strip
      district = obj.try(:district).presence
      parts << "район #{district}" if district
      cond = obj.try(:condition) || obj.try(:property_condition)
      parts << "состояние: #{cond}" if cond.present?
      year = obj.try(:building_year) || obj.try(:year_built)
      parts << "год постройки #{year}" if year.to_i.positive?
      floor = obj.try(:floor)
      total = obj.try(:total_floors) || obj.try(:floors_count)
      parts << "этаж #{floor}#{total ? "/#{total}" : ''}" if floor.to_i.positive?
      parts.join(', ')
    end

    def format_area(obj)
      raw = obj.try(:total_area) || obj.try(:area)
      raw.to_f.round(1)
    end

    def record_price(obj)
      ActionController::Base.helpers.number_with_delimiter(obj.try(:price).to_i, delimiter: ' ')
    end

    def source_of(obj)
      case obj.class.name
      when 'MlsListing'      then 'Topnlab MLS'
      when 'ExternalListing' then obj.try(:source) || 'внешний'
      else                        'наша база'
      end
    end

    def parse_verdict(raw_content)
      return default_verdict if raw_content.blank?

      # Models sometimes wrap JSON in ```json ... ```; strip it.
      cleaned = raw_content.strip.sub(/\A```(?:json)?/, '').sub(/```\z/, '').strip
      parsed = JSON.parse(cleaned)
      {
        suitable:   parsed['suitable'] == true || parsed['suitable'].to_s.downcase == 'true',
        reason:     parsed['reason'].to_s,
        adjustment: parsed['adjustment'].to_f.clamp(-15, 15)
      }
    rescue JSON::ParserError => e
      Rails.logger.warn("[AiCompFilter] JSON parse: #{e.message} body=#{raw_content.to_s.truncate(160)}")
      default_verdict
    end

    def default_verdict
      { suitable: true, reason: 'AI вернул не-JSON — оставлен по умолчанию', adjustment: 0 }
    end

    def client
      @client ||= Llm::OmniClient.new
    end

    # --- Redis cache (key = subject_hash + candidate_class:id) ---

    def cache_key(comp)
      record = comp[:record] || comp['record']
      "ai_comp:#{subject_fingerprint}:#{record.class.name}:#{record.id}"
    end

    def subject_fingerprint
      Digest::MD5.hexdigest([
        @subject.try(:property_type),
        @subject.try(:total_area).to_i,
        @subject.try(:rooms),
        @subject.try(:district),
        @subject.try(:property_condition) || @subject.try(:condition),
        @subject.try(:building_year)
      ].join('|'))
    end

    def cache_lookup(comp)
      raw = redis&.get(cache_key(comp))
      raw ? JSON.parse(raw, symbolize_names: true) : nil
    rescue StandardError
      nil
    end

    def cache_store(comp, verdict)
      redis&.set(cache_key(comp), verdict.to_json, ex: CACHE_TTL)
    rescue StandardError
      nil
    end

    def redis
      @redis ||= begin
        require 'redis' unless defined?(Redis)
        Redis.new(url: ENV['REDIS_URL'].presence || 'redis://localhost:6379/0')
      rescue StandardError
        nil
      end
    end
  end
end
