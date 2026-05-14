# frozen_string_literal: true

# Firecrawl Scrape API wrapper — extracts clean markdown from any URL,
# handles JS-rendered SPAs (важно для Avito/Cian которые сложно скрапить
# обычным curl'ом).
#
# Docs: https://docs.firecrawl.dev/api-reference/endpoint/scrape
# Pricing: Hobby $20/мес = 5000 credits ($0.004/scrape, normal pages);
#          Scale $89/мес = 25000 credits.
#
# Used by Valuations::WebsearchCompFinder для deep-scrape страниц
# listings, найденных через Tavily search.
module Firecrawl
  class Client
    BASE_URL = 'https://api.firecrawl.dev/v1'

    class Error < StandardError; end

    def initialize(api_key: ENV.fetch('FIRECRAWL_API_KEY', nil))
      raise Error, 'FIRECRAWL_API_KEY env var missing' if api_key.blank?

      @api_key = api_key
    end

    # @param url     [String]
    # @param formats [Array<String>] 'markdown' (default), 'html', 'links',
    #                                'screenshot' и т.д.
    # @param wait_ms [Integer] ожидание JS-render (Avito SPA нужно ~2-3s)
    # @return [String, nil] markdown content или nil if failed
    def scrape(url, formats: %w[markdown], wait_ms: 2000)
      return nil if url.blank?

      payload = {
        url:       url,
        formats:   formats,
        waitFor:   wait_ms,
        # onlyMainContent strips header/footer/nav — для listings это и нужно.
        onlyMainContent: true
      }

      response = http.post('/scrape', payload)
      unless response.success?
        Rails.logger.warn("[Firecrawl] HTTP #{response.status} for #{url}: #{response.body.to_s.truncate(200)}")
        return nil
      end

      body = parse_json(response.body)
      return nil unless body[:success]

      body.dig(:data, :markdown).to_s.presence
    rescue Faraday::Error => e
      Rails.logger.warn("[Firecrawl] #{e.class} for #{url}: #{e.message}")
      nil
    rescue Error => e
      Rails.logger.warn("[Firecrawl] #{e.message}")
      nil
    end

    private

    def http
      @http ||= Faraday.new(BASE_URL) do |f|
        f.request :json
        f.headers['Authorization'] = "Bearer #{@api_key}"
        # JS-rendered pages (Avito/Cian) могут занять 5-30 сек, timeout 90с
        f.options.timeout = 90
        f.options.open_timeout = 5
        f.request :retry, max: 1, interval: 1.0, backoff_factor: 2,
                          exceptions: [Faraday::TimeoutError]
      end
    end

    def parse_json(body)
      JSON.parse(body.to_s, symbolize_names: true)
    rescue JSON::ParserError => e
      raise Error, "JSON parse failed: #{e.message}"
    end
  end
end
