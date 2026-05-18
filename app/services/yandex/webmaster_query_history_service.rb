# frozen_string_literal: true

module Yandex
  # Single-query timeline — track impressions/clicks/position over time
  # for конкретный поисковый запрос. Used after optimisation (title rewrite,
  # added snippet, internal links) to verify impact.
  #
  # Usage:
  #   data = Yandex::WebmasterQueryHistoryService.call(
  #     query_id: '...',
  #     date_from: 30.days.ago.to_date,
  #     date_to: Date.current
  #   )
  #
  # API endpoint: /search-queries/<query-id>/history/ — returns
  # daily points {date, shows, clicks, position}.
  class WebmasterQueryHistoryService
    BASE_URL = 'https://api.webmaster.yandex.net/v4/'
    DEFAULT_HOST = 'https:victory62.org:443'

    class ConfigError < StandardError; end

    def self.call(**opts)
      new(**opts).call
    end

    def initialize(query_id:, host_id: nil, date_from: nil, date_to: nil)
      @token = ENV['YANDEX_WEBMASTER_TOKEN'].to_s
      @user_id = ENV['YANDEX_WEBMASTER_USER_ID'].to_s
      raise ConfigError, 'YANDEX_WEBMASTER_TOKEN env var missing' if @token.empty?
      raise ConfigError, 'YANDEX_WEBMASTER_USER_ID env var missing' if @user_id.empty?

      @host_id = host_id || DEFAULT_HOST
      @query_id = query_id
      @date_from = (date_from || 30.days.ago.to_date).to_s
      @date_to = (date_to || Date.current).to_s
    end

    def call
      response = http.get(
        "user/#{@user_id}/hosts/#{@host_id}/search-queries/#{@query_id}/history/",
        date_from: @date_from,
        date_to: @date_to,
        query_indicator: %w[TOTAL_SHOWS TOTAL_CLICKS AVG_SHOW_POSITION]
      )
      return nil unless response.success?

      JSON.parse(response.body)
    rescue Faraday::Error, JSON::ParserError => e
      Rails.logger.warn("[WebmasterQueryHistory] fetch failed: #{e.class}: #{e.message}")
      nil
    end

    private

    def http
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
