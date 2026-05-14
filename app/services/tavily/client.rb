# frozen_string_literal: true

# Tavily Search API wrapper — AI-optimized web search для valuation
# comp finder. Returns top N URLs + content snippets от российских
# real-estate сайтов (Avito, Cian, Domclick, Yandex.Realty).
#
# Docs: https://docs.tavily.com/docs/rest-api/api-reference
# Pricing: free tier 1000 searches/мес; basic $0.008/search,
#          advanced $0.04/search.
#
# Used by Valuations::WebsearchCompFinder to enrich thin local samples
# (Рязань премиум-сегмент: 5-8 comps в DB vs 50-200 на open-web).
module Tavily
  class Client
    BASE_URL = 'https://api.tavily.com'

    class Error < StandardError; end

    # Default domain whitelist для real-estate searches. Включает 4
    # ключевых российских listing-сайта. ENV TAVILY_DOMAINS_WHITELIST
    # позволяет override (CSV).
    DEFAULT_DOMAINS = %w[avito.ru cian.ru domclick.ru realty.yandex.ru].freeze

    def initialize(api_key: ENV.fetch('TAVILY_API_KEY', nil))
      raise Error, 'TAVILY_API_KEY env var missing' if api_key.blank?

      @api_key = api_key
    end

    # @param query        [String] поисковый запрос (русский OK)
    # @param domains      [Array<String>] whitelist domains. Default — top 4 РФ-сайтов.
    # @param max_results  [Integer] 5-20 typical
    # @param depth        ['basic' | 'advanced'] — basic дешевле в 5×, обычно достаточно
    # @return [Array<Hash>] [{title:, url:, content:, score:}, ...]
    def search(query, domains: nil, max_results: 8, depth: 'basic')
      domains = resolve_domains(domains)
      payload = {
        api_key:             @api_key,
        query:               query,
        search_depth:        depth,
        max_results:         max_results,
        include_raw_content: false,
        include_domains:     domains,
        country:             'russia'
      }.compact

      response = http.post('/search', payload)
      raise Error, "HTTP #{response.status}: #{response.body.to_s.truncate(200)}" unless response.success?

      body = parse_json(response.body)
      Array(body[:results])
    rescue Faraday::Error => e
      Rails.logger.warn("[Tavily] #{e.class}: #{e.message}")
      raise Error, "Tavily request failed: #{e.message}"
    end

    private

    def resolve_domains(arg)
      return arg if arg.is_a?(Array) && arg.any?

      env_value = ENV['TAVILY_DOMAINS_WHITELIST'].to_s
      return env_value.split(',').map(&:strip).reject(&:empty?) if env_value.present?

      DEFAULT_DOMAINS
    end

    def http
      @http ||= Faraday.new(BASE_URL) do |f|
        f.request :json
        f.options.timeout = 30
        f.options.open_timeout = 5
        f.request :retry, max: 2, interval: 0.5, backoff_factor: 2,
                          exceptions: [Faraday::TimeoutError, Faraday::ConnectionFailed]
      end
    end

    def parse_json(body)
      JSON.parse(body.to_s, symbolize_names: true)
    rescue JSON::ParserError => e
      raise Error, "JSON parse failed: #{e.message}"
    end
  end
end
