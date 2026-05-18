# frozen_string_literal: true

module Yandex
  # Pulls Yandex.Webmaster API v4 snapshot for victory62.org — site SQI,
  # sitemap status, top search queries with avg position + CTR. Used by
  # `rake yandex:webmaster:summary` (weekly via cron) и admin dashboard.
  #
  # OAuth token + user_id живут в ENV (см. .claude/docs/yandex-webmaster-oauth-setup.md).
  # Token не expires automatically; revoke возможен на passport.yandex.ru/profile/access.
  #
  # Каждый call возвращает Hash с независимыми разделами — если один из
  # endpoints rate-limited/обвалился, остальные продолжают работать
  # (graceful degradation). Failure → разделу = nil + лог-warning.
  class WebmasterSummaryService
    BASE_URL = 'https://api.webmaster.yandex.net/v4/'
    DEFAULT_HOST = 'https:victory62.org:443'
    CACHE_KEY = 'yandex:webmaster:summary:v1'
    CACHE_TTL = 12.hours

    class ConfigError < StandardError; end

    def self.call(force_refresh: false, top_queries_limit: 20)
      Rails.cache.delete(CACHE_KEY) if force_refresh
      Rails.cache.fetch(CACHE_KEY, expires_in: CACHE_TTL) do
        new(top_queries_limit: top_queries_limit).fetch
      end
    end

    def self.bust!
      Rails.cache.delete(CACHE_KEY)
    end

    def initialize(host_id: nil, top_queries_limit: 20)
      @token = ENV['YANDEX_WEBMASTER_TOKEN'].to_s
      @user_id = ENV['YANDEX_WEBMASTER_USER_ID'].to_s
      raise ConfigError, 'YANDEX_WEBMASTER_TOKEN env var missing' if @token.empty?
      raise ConfigError, 'YANDEX_WEBMASTER_USER_ID env var missing' if @user_id.empty?

      @host_id = host_id || DEFAULT_HOST
      @top_queries_limit = top_queries_limit
    end

    def fetch
      {
        host_id: @host_id,
        fetched_at: Time.current,
        summary: safe_get('summary/'),
        sqi_history: safe_get('sqi-history/')&.dig('points'),
        sitemaps: safe_get('sitemaps/')&.dig('sitemaps'),
        top_queries: safe_get(
          'search-queries/popular/',
          order_by: 'TOTAL_SHOWS',
          query_indicator: %w[TOTAL_SHOWS TOTAL_CLICKS AVG_SHOW_POSITION AVG_CLICK_POSITION],
          limit: @top_queries_limit
        )&.dig('queries')
      }
    end

    private

    def safe_get(path, **params)
      response = http.get("user/#{@user_id}/hosts/#{@host_id}/#{path}", params)
      return JSON.parse(response.body) if response.success?

      Rails.logger.warn("[YandexWebmaster] HTTP #{response.status} on #{path}: #{response.body.to_s[0, 200]}")
      nil
    rescue Faraday::Error => e
      Rails.logger.warn("[YandexWebmaster] #{e.class} on #{path}: #{e.message}")
      nil
    rescue JSON::ParserError => e
      Rails.logger.warn("[YandexWebmaster] JSON parse error on #{path}: #{e.message}")
      nil
    end

    def http
      # FlatParamsEncoder — Я.API ожидает повторяющиеся ключи `query_indicator=A&query_indicator=B`
      # (не `query_indicator[]=A`). Faraday default — bracketed; через `request:`
      # options передаём правильный encoder.
      @http ||= Faraday.new(
        BASE_URL,
        request: { params_encoder: Faraday::FlatParamsEncoder, timeout: 15, open_timeout: 5 }
      ) do |f|
        f.headers['Authorization'] = "OAuth #{@token}"
        f.request :retry, max: 2, interval: 0.5, backoff_factor: 2,
                          exceptions: [Faraday::TimeoutError, Faraday::ConnectionFailed]
      end
    end
  end
end
