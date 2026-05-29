# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'yaml'
require 'digest'

module Valuations
  # Sibling of WebsearchCompFinder — но input не Tavily search, а
  # static sitemap'ы конкретных Рязанских агентств (config/agency_sitemaps.yml).
  # Эти агентства не публикуют public YRL feeds, но их sitemap.xml содержит
  # прямые URL'ы listings (например, ЦАН: /catalog/N/, /house/N/).
  #
  # Pipeline (per agency):
  #   1. Fetch sitemap-index → extract sub-sitemap URLs matching pattern
  #   2. Fetch sub-sitemaps → extract listing URLs matching property-type pattern
  #   3. Top-N свежих URL → scrape_method:
  #      - 'json_ld' (preferred): HTTP GET → extract Schema.org JSON-LD →
  #        structured fields directly. Free, fast, accurate.
  #      - 'firecrawl_llm' (fallback): Firecrawl scrape → Sonnet parse
  #        markdown. Higher cost, used когда нет JSON-LD на странице.
  #   4. Persist as ExternalListing(source: 'agency_sitemap', source_id: "{agency_key}:{id}")
  #
  # Picked up automatically by PropertyEvaluation::ComparableFinder#external_scope
  # (no integration changes there).
  #
  # Cache: 6h TTL по same key как WebsearchCompFinder
  # (district + property_type + area-bracket).
  #
  # Cost per fresh subject (1 agency, 5 listings):
  #   - sitemap fetch ~0$ (XML, free)
  #   - Firecrawl ×5 = $0.02
  #   - Sonnet parse ×5 = ~$0.05
  #   = ~$0.07 (vs $0.18 для WebsearchCompFinder)
  #
  # Backward-compatible: если FIRECRAWL_API_KEY не задан или config пустой —
  # gracefully возвращает 0.
  class SitemapCompFinder
    CACHE_TTL = 6.hours
    CONFIG_PATH = Rails.root.join('config/agency_sitemaps.yml')
    SOURCE_KIND = 'agency_sitemap'

    # Match WebsearchCompFinder convention для совместимости с
    # ComparableFinder#external_scope's for_type filter.
    REALTY_TYPE_TO_SLUG = {
      'apartment' => 'flat', 'house' => 'house', 'land' => 'land',
      'commercial' => 'commerce', 'garage' => 'garage', 'room' => 'room'
    }.freeze

    def initialize(valuation)
      @v = valuation
    end

    # @return [Integer] total persisted ExternalListing rows across all agencies
    def call
      return 0 unless enabled?

      config = load_config
      return 0 if config.empty?

      total_persisted = 0
      config.each do |agency_key, cfg|
        next unless property_type_supported?(cfg)
        next if cached_count(agency_key) >= 5

        listings = discover_listings(cfg)
        next if listings.empty?

        parsed = case cfg['scrape_method'].to_s
                 when 'json_ld' then scrape_json_ld(listings, agency_key)
                 else scrape_and_parse(listings, agency_key)
                 end
        persisted = persist(parsed, agency_key)
        total_persisted += persisted

        Rails.logger.info(
          "[SitemapCompFinder] agency=#{agency_key} subject=#{@v.id} " \
          "district=#{@v.district} listings=#{listings.size} parsed=#{parsed.size} persisted=#{persisted}"
        )
      rescue StandardError => e
        Rails.logger.warn("[SitemapCompFinder] #{agency_key} failed: #{e.class} #{e.message.to_s.truncate(160)}")
      end
      total_persisted
    end

    private

    # Always enabled — json_ld method не требует API keys; только
    # firecrawl_llm fallback гейтится FIRECRAWL_API_KEY (если используется
    # на конкретном агентстве).
    def enabled?
      true
    end

    def load_config
      return {} unless File.exist?(CONFIG_PATH)

      YAML.safe_load_file(CONFIG_PATH) || {}
    rescue Psych::SyntaxError => e
      Rails.logger.error("[SitemapCompFinder] config parse error: #{e.message}")
      {}
    end

    def property_type_supported?(cfg)
      cfg.dig('listing_path_patterns', @v.property_type.to_s).present?
    end

    # Cache по same key как WebsearchCompFinder, но scoped к agency_key
    # через source_id prefix.
    def cached_count(agency_key)
      ExternalListing
        .where(source: SOURCE_KIND)
        .where('source_id LIKE ?', "#{agency_key}:%")
        .where(property_type: REALTY_TYPE_TO_SLUG[@v.property_type.to_s] || @v.property_type)
        .where(deal_type: @v.deal_type)
        .where(area: area_bracket_min..area_bracket_max)
        .where('fetched_at > ?', CACHE_TTL.ago)
        .where(closed_at: nil)
        .count
    end

    def area_bracket_min
      (@v.total_area.to_f * 0.75).round(1)
    end

    def area_bracket_max
      (@v.total_area.to_f * 1.25).round(1)
    end

    # Sitemap → sub-sitemaps → listing URLs
    def discover_listings(cfg)
      pattern_str = cfg.dig('listing_path_patterns', @v.property_type.to_s)
      return [] if pattern_str.blank?

      listing_pattern = Regexp.new(pattern_str)
      sub_pattern = Regexp.new(cfg['sub_sitemap_pattern'] || 'sitemap.*\.xml')

      index_xml = fetch_xml(cfg['sitemap_index_url'])
      return [] if index_xml.blank?

      sub_urls = extract_locs(index_xml).select { |u| u.match?(sub_pattern) }
      return [] if sub_urls.empty?

      max = cfg['max_listings_per_run'] || 10
      sub_urls.flat_map { |sub_url|
        sub_xml = fetch_xml(sub_url)
        next [] if sub_xml.blank?

        extract_locs(sub_xml).select { |u| u.match?(listing_pattern) }
      }.uniq.first(max)
    end

    def fetch_xml(url)
      uri = URI(url)
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                                          open_timeout: 5, read_timeout: 15) do |http|
        req = Net::HTTP::Get.new(uri.request_uri,
                                 'User-Agent' => 'victory62-comp-bot/1.0')
        res = http.request(req)
        return res.code == '200' ? res.body.to_s : ''
      end
    rescue StandardError => e
      Rails.logger.warn("[SitemapCompFinder] fetch_xml #{url} failed: #{e.class} #{e.message}")
      ''
    end

    def extract_locs(xml)
      xml.scan(%r{<loc>([^<]+)</loc>}).flatten
    end

    def scrape_and_parse(urls, agency_key)
      firecrawl = Firecrawl::Client.new
      urls.filter_map do |url|
        next nil if already_persisted?(url, agency_key)

        markdown = firecrawl.scrape(url)
        next nil if markdown.blank?

        parsed = llm_parse(url, markdown)
        next nil if parsed.nil? || parsed[:price].to_i.zero?

        parsed.merge(source_url: url)
      end
    end

    # JSON-LD path: fetch raw HTML + extract <script type="application/ld+json">.
    # Schema.org даёт structured Apartment/House/Product+Offer — все нужные поля
    # (price, area, address, rooms, floor) без LLM-парсинга. Если на странице
    # нет JSON-LD или structure broken — skip (не падаем).
    def scrape_json_ld(urls, agency_key)
      urls.filter_map do |url|
        next nil if already_persisted?(url, agency_key)

        html = fetch_html(url)
        next nil if html.blank?

        attrs = extract_json_ld_attrs(html, url)
        next nil if attrs.nil? || attrs[:price].to_i.zero?

        attrs.merge(source_url: url)
      end
    end

    def fetch_html(url)
      uri = URI(url)
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https',
                                          open_timeout: 5, read_timeout: 15) do |http|
        req = Net::HTTP::Get.new(uri.request_uri,
                                 'User-Agent' => 'victory62-comp-bot/1.0',
                                 'Accept'     => 'text/html,application/xhtml+xml')
        res = http.request(req)
        return res.code == '200' ? res.body.to_s.force_encoding('UTF-8') : ''
      end
    rescue StandardError => e
      Rails.logger.warn("[SitemapCompFinder] fetch_html #{url} failed: #{e.class} #{e.message}")
      ''
    end

    # Извлечь поля из Schema.org JSON-LD. Возвращает hash совместимый с
    # `persist` (price/area/rooms/floor/address/district/title). Nil если
    # structure отсутствует или unparseable.
    def extract_json_ld_attrs(html, url)
      scripts = html.scan(%r{<script[^>]*type=["']application/ld\+json["'][^>]*>(.+?)</script>}m).flatten
      return nil if scripts.empty?

      blocks = scripts.flat_map { |s| safe_parse_json(s) }.compact
      graph_nodes = blocks.flat_map { |b| b.is_a?(Hash) ? (b['@graph'] || [b]) : Array(b) }

      property_node = graph_nodes.find { |n| n.is_a?(Hash) && %w[Apartment House Residence Place].include?(n['@type']) }
      offer_root    = graph_nodes.find { |n| n.is_a?(Hash) && n['@type'] == 'Product' && n['offers'].is_a?(Hash) }
      offer         = offer_root&.dig('offers')

      return nil if property_node.nil? && offer.nil?

      price = offer&.dig('price').to_i
      area  = property_node&.dig('floorSize', 'value').to_f
      rooms = property_node&.dig('numberOfRooms').to_i
      floor = property_node&.dig('floorLevel').to_i
      addr  = property_node&.dig('address') || {}
      title = property_node&.dig('name').to_s.presence ||
              offer_root&.dig('description').to_s.presence

      {
        title:        title.to_s.first(255),
        price:        price,
        area:         area,
        rooms:        rooms,
        floor:        floor,
        total_floors: 0,
        building_year: 0,
        condition:    '',
        district:     extract_district(addr),
        address:      addr['streetAddress'].to_s
      }
    rescue StandardError => e
      Rails.logger.warn("[SitemapCompFinder] json_ld parse #{url} failed: #{e.class} #{e.message.to_s.truncate(140)}")
      nil
    end

    def safe_parse_json(text)
      JSON.parse(text.to_s.strip)
    rescue JSON::ParserError
      nil
    end

    # Schema.org addressLocality иногда содержит район («Солотча»),
    # иногда только город. Heuristics: если subject.district present
    # и addressLocality матчит — используем; иначе пустая строка.
    def extract_district(addr)
      locality = addr['addressLocality'].to_s
      sub      = addr['addressRegion'].to_s
      return locality if locality.present? && locality != 'Рязань' && locality != 'Москва'
      return sub if sub.present?

      ''
    end

    def already_persisted?(url, agency_key)
      ExternalListing
        .where(source: SOURCE_KIND, url: url)
        .where('source_id LIKE ?', "#{agency_key}:%")
        .where('fetched_at > ?', CACHE_TTL.ago)
        .exists?
    end

    # Reuse exact same prompt as WebsearchCompFinder. Извлечён в локальную
    # константу — DRY ratio < 3, не стоит ради этого выделять в shared module.
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
      Rails.logger.warn("[SitemapCompFinder] LLM parse #{url} failed: #{e.message.to_s.truncate(160)}")
      nil
    end

    def persist(parsed_list, agency_key)
      count = 0
      parsed_list.each do |p|
        next unless sane?(p)

        # source_id = "{agency_key}:{listing_id_from_url_or_sha1}"
        listing_id = p[:source_url].to_s[/\/(\d{4,12})\/?$/, 1] ||
                     Digest::SHA1.hexdigest(p[:source_url].to_s)[0, 16]
        source_id = "#{agency_key}:#{listing_id}"

        el = ExternalListing.find_or_initialize_by(source: SOURCE_KIND, source_id: source_id)
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
          Rails.logger.warn("[SitemapCompFinder] persist failed for #{p[:source_url]}: #{el.errors.full_messages.join(', ')}")
        end
      end
      count
    end

    # Same sanity bounds как WebsearchCompFinder.
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
