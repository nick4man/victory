# frozen_string_literal: true

module Valuations
  # Orchestrates external-data pipeline для valuation comp finder:
  #
  #   Tavily.search → Firecrawl.scrape (×N) → Sonnet parse → ExternalListing.persist
  #
  # Primary side-effect: populates `ExternalListing` rows для текущего
  # subject's района + property_type + area-bracket. Existing
  # `PropertyEvaluation::ComparableFinder#external_scope` picks them up
  # automatically на следующей tier iteration (no integration changes
  # there).
  #
  # Backward-compatible: если TAVILY_API_KEY или FIRECRAWL_API_KEY не
  # заданы — сервис gracefully скипается, оценка продолжается с
  # DB-only sample.
  #
  # Cost (per fresh subject, no cache):
  #   - Tavily ~8 searches × $0.008 = $0.06
  #   - Firecrawl ~5 scrapes × $0.004 = $0.02
  #   - Sonnet parse ~5 × 2k tokens = $0.10
  #   = ~$0.18 (~18 ₽) per «new» valuation
  #
  # Cache hit (same district/type/area-bracket в последние 6ч): $0.
  class WebsearchCompFinder
    CACHE_TTL = 6.hours
    MAX_SEARCH_RESULTS = 8
    MAX_SCRAPES = 5

    # PropertyValuation.property_type → ExternalListing.property_type slug.
    # Mirror'имо из PropertyEvaluation::ComparableFinder::REALTY_TYPE_TO_SLUG —
    # external_scope filter by `for_type(slug)` ожидает slug-форму.
    REALTY_TYPE_TO_SLUG = {
      'apartment' => 'flat', 'house' => 'house', 'land' => 'land',
      'commercial' => 'commerce', 'garage' => 'garage', 'room' => 'room'
    }.freeze

    def initialize(valuation)
      @v = valuation
    end

    # Main entry — populates ExternalListing + returns count of new
    # records persisted. Caller (PropertyEvaluationService) ignores
    # return value, but log line gives observability.
    def call
      return 0 unless enabled?

      cached = cached_count
      if cached >= 5
        Rails.logger.info("[Websearch] cache hit: #{cached} ExternalListing rows for #{cache_key}")
        return cached
      end

      results = tavily_search
      return 0 if results.empty?

      parsed = scrape_and_parse(results.first(MAX_SCRAPES))
      persisted = persist(parsed)

      Rails.logger.info(
        "[Websearch] subject=#{@v.id} district=#{@v.district} area=#{@v.total_area} " \
        "tavily=#{results.size} parsed=#{parsed.size} persisted=#{persisted}"
      )
      persisted
    rescue Tavily::Client::Error => e
      Rails.logger.warn("[Websearch] Tavily failed for valuation #{@v.id}: #{e.message}")
      0
    rescue StandardError => e
      Rails.logger.warn("[Websearch] unexpected error for valuation #{@v.id}: #{e.class} #{e.message}")
      0
    end

    private

    def enabled?
      ENV['TAVILY_API_KEY'].to_s.match?(/\A\S+\z/) &&
        ENV['FIRECRAWL_API_KEY'].to_s.match?(/\A\S+\z/)
    end

    def cache_key
      "#{@v.district}/#{@v.property_type}/#{area_bracket_min}-#{area_bracket_max}"
    end

    def area_bracket_min
      (@v.total_area.to_f * 0.75).round(1)
    end

    def area_bracket_max
      (@v.total_area.to_f * 1.25).round(1)
    end

    def cached_count
      ExternalListing
        .where(property_type: @v.property_type, deal_type: @v.deal_type)
        .where(district: @v.district.presence || nil)
        .where(area: area_bracket_min..area_bracket_max)
        .where('fetched_at > ?', CACHE_TTL.ago)
        .where(closed_at: nil)
        .count
    end

    def tavily_search
      query = build_query
      Tavily::Client.new.search(query, max_results: MAX_SEARCH_RESULTS, depth: 'basic')
    end

    def build_query
      type_ru = {
        'apartment' => 'квартира', 'house' => 'дом',
        'land' => 'участок', 'commercial' => 'коммерция'
      }
      city = @v.city.presence || guess_city || 'Рязань'
      district = @v.district.presence
      area_part = @v.total_area.to_f.positive? ? "#{@v.total_area.to_i} м²" : nil
      rooms_part = @v.rooms.to_i.positive? ? "#{@v.rooms}-комн" : nil

      [
        'продажа',
        rooms_part,
        type_ru[@v.property_type] || @v.property_type,
        area_part,
        district,
        city
      ].compact.join(' ')
    end

    def guess_city
      addr = @v.address.to_s
      return 'Москва' if addr.match?(/Москв/i)
      return 'Санкт-Петербург' if addr.match?(/Санкт-Петербург|СПб/i)
      'Рязань'
    end

    def scrape_and_parse(tavily_results)
      firecrawl = Firecrawl::Client.new
      tavily_results.filter_map do |tr|
        url = tr[:url].to_s
        next nil if url.blank? || already_persisted?(url)

        markdown = firecrawl.scrape(url)
        next nil if markdown.blank?

        parsed = llm_parse(url, markdown)
        next nil if parsed.nil? || parsed[:price].to_i.zero?

        parsed.merge(source_url: url, scraped_markdown_size: markdown.size)
      end
    end

    def already_persisted?(url)
      ExternalListing.where(source: 'tavily', url: url).where('fetched_at > ?', CACHE_TTL.ago).exists?
    end

    PARSE_SYSTEM_PROMPT = <<~PROMPT.freeze
      Извлеки данные из объявления о продаже недвижимости (markdown ниже).
      Верни СТРОГО валидный JSON БЕЗ markdown-блоков и комментариев.

      Структура:
      {
        "title":          "1 строка краткое описание (без URL)",
        "price":          int (₽, общая цена объекта; 0 если не указана или объявление закрыто),
        "area":           float (общая площадь, м²; для участков — соток),
        "rooms":          int (для нежилых и студий — 0; для студий — 1),
        "floor":          int (для домов/участков — 0),
        "total_floors":   int (этажность дома; для участков — 0),
        "building_year":  int (если есть; иначе 0),
        "condition":      "needs_repair" | "average" | "good" | "excellent" | "designer" | "",
        "district":       "название района если упоминается, иначе пустая строка",
        "address":        "уличный адрес если есть"
      }

      Если объявление не о продаже / закрыто / архив — верни {"price": 0}.
      Если цена «по запросу» — верни {"price": 0}.
    PROMPT

    def llm_parse(url, markdown)
      response = Llm::OmniClient.new.complete(
        [
          { role: 'system', content: PARSE_SYSTEM_PROMPT },
          { role: 'user',   content: "URL: #{url}\n\n#{markdown.first(8000)}" }
        ],
        chain: :analysis,
        max_tokens: 400,
        temperature: 0.1,
        response_format: { type: 'json_object' }
      )
      content = response[:content].to_s.strip
      return nil if content.empty?

      JSON.parse(content, symbolize_names: true)
    rescue JSON::ParserError, Llm::OmniClient::Error => e
      Rails.logger.warn("[Websearch] LLM parse #{url} failed: #{e.message.to_s.truncate(160)}")
      nil
    end

    def persist(parsed_list)
      count = 0
      parsed_list.each do |p|
        next unless sane?(p)

        # ExternalListing::KINDS = %w[yandex_yrl avito cian topnlab_mls].
        # Map domain → kind. Если домен не в whitelist (например, какой-то
        # blog/aggregator оказался в Tavily output) → используем 'avito'
        # как catch-all (модель требует один из KINDS, реальный URL виден
        # в `url`).
        source_kind = case p[:source_url].to_s
                      when /avito\.ru/      then 'avito'
                      when /cian\.ru/       then 'cian'
                      when /(realty\.yandex|realty\.ya\.ru)/ then 'yandex_yrl'
                      when /domclick\.ru/   then 'cian'   # domclick → maps to cian (нет своего kind'а)
                      else                       'avito'  # fallback
                      end
        # source_id — required + unique per source. Извлекаем из URL по
        # числовому ID listing'а, fallback на SHA1(url) для query-style URLs.
        source_id = p[:source_url].to_s[/\b\d{6,12}\b/] ||
                    Digest::SHA1.hexdigest(p[:source_url].to_s)[0, 16]

        el = ExternalListing.find_or_initialize_by(source: source_kind, source_id: source_id)
        el.assign_attributes(
          url:           p[:source_url],
          title:         p[:title].to_s.first(255),
          price:         p[:price].to_i,
          area:          p[:area].to_f,
          rooms:         p[:rooms].to_i,
          floor:         p[:floor].to_i,
          total_floors:  p[:total_floors].to_i,
          building_year: p[:building_year].to_i.positive? ? p[:building_year].to_i : nil,
          condition:     p[:condition].to_s.presence,
          district:      (p[:district].to_s.presence || @v.district.to_s.presence),
          address:       p[:address].to_s.presence,
          property_type: REALTY_TYPE_TO_SLUG[@v.property_type.to_s] || @v.property_type.to_s,
          deal_type:     @v.deal_type,
          raw_payload:   p,
          fetched_at:    Time.current
        )
        if el.save
          count += 1
        else
          Rails.logger.warn("[Websearch] persist failed for #{p[:source_url]}: #{el.errors.full_messages.join(', ')}")
        end
      end
      count
    end

    # Sanity-bounds: avoid garbage из LLM parsing — price 100k–1B ₽,
    # area 5–10000 м² (соток), title не пустой.
    def sane?(p)
      price = p[:price].to_i
      area  = p[:area].to_f
      return false if price < 100_000 || price > 1_000_000_000
      return false if area < 5 || area > 10_000
      return false if p[:title].to_s.strip.empty?

      true
    end
  end
end
