# frozen_string_literal: true

module Yandex
  # SEO opportunity detection — pulls all-queries snapshot, filters by
  # thresholds, returns optimisation targets ranked by impression volume.
  #
  # Thresholds (defaults — calibrated for Yandex SERP behaviour):
  #   - impressions >= 50          (real demand signal — single-digit
  #                                 impressions usually noise/long-tail)
  #   - avg_position in 4..15      (already ranks → fixable; pos > 20 obscure;
  #                                 pos < 4 already TOP and CTR-game over)
  #   - ctr < 3%                   (TOP-10 average CTR ~5-15% — below 3%
  #                                 signals weak title/snippet, not bad
  #                                 ranking position)
  #
  # Output:
  #   [
  #     {
  #       query: 'купить премиум квартиру рязань',
  #       impressions: 412, clicks: 4,
  #       ctr: 0.0097, avg_position: 8.3,
  #       missed_clicks_estimate: ~21    # impressions × (target_ctr - current_ctr)
  #     }, ...
  #   ]
  class WebmasterOpportunitiesService
    BASE_URL = 'https://api.webmaster.yandex.net/v4/'
    DEFAULT_HOST = 'https:victory62.org:443'

    # Reference CTR by position (rough Yandex aggregates from public studies):
    # pos 1 ~24%, pos 2 ~16%, pos 3 ~11%, 4-5 ~6-8%, 6-10 ~3-5%, 11-20 ~1-2%
    # Target CTR — what we'd reach by lifting snippet quality at given position.
    TARGET_CTR_BY_POSITION = {
      1..3 => 0.10,   # already excellent — opportunity here is rare
      4..5 => 0.07,
      6..10 => 0.05,
      11..15 => 0.025,
      16..30 => 0.015 # page 2 — show-pollination, all opportunity is to climb
    }.freeze

    # Defaults откалиброваны под Phase-A reality (22.05.26 audit): 47 уникальных
    # запросов / 64 показа / 4 клика в API window — НИ ОДИН query не имел >=5
    # показов. Дефолт min_impressions=50 → 0 opportunities никогда. После SQI
    # >50 и среднего >10 показов на запрос — поднять обратно к 50/4..15.
    DEFAULT_MIN_IMPRESSIONS = 3
    DEFAULT_MAX_CTR = 0.05
    DEFAULT_POSITION_RANGE = (3..30).freeze

    class ConfigError < StandardError; end

    def self.call(**opts)
      new(**opts).call
    end

    def initialize(host_id: nil, min_impressions: DEFAULT_MIN_IMPRESSIONS,
                   max_ctr: DEFAULT_MAX_CTR, position_range: DEFAULT_POSITION_RANGE,
                   limit: 500)
      @token = ENV['YANDEX_WEBMASTER_TOKEN'].to_s
      @user_id = ENV['YANDEX_WEBMASTER_USER_ID'].to_s
      raise ConfigError, 'YANDEX_WEBMASTER_TOKEN env var missing' if @token.empty?
      raise ConfigError, 'YANDEX_WEBMASTER_USER_ID env var missing' if @user_id.empty?

      @host_id = host_id || DEFAULT_HOST
      @min_impressions = min_impressions
      @max_ctr = max_ctr
      @position_range = position_range
      @limit = limit
    end

    def call
      raw = fetch_all_queries
      return [] if raw.blank?

      opportunities = raw.filter_map do |q|
        ind = q['indicators'] || {}
        impressions = ind['TOTAL_SHOWS'].to_i
        clicks = ind['TOTAL_CLICKS'].to_i
        avg_position = ind['AVG_SHOW_POSITION']&.to_f
        next nil unless avg_position
        next nil unless impressions >= @min_impressions
        next nil unless @position_range.include?(avg_position)

        ctr = impressions.positive? ? clicks.fdiv(impressions) : 0.0
        next nil unless ctr < @max_ctr

        target_ctr = lookup_target_ctr(avg_position)
        {
          query: q['query_text'],
          impressions: impressions,
          clicks: clicks,
          ctr: ctr.round(4),
          avg_position: avg_position.round(1),
          target_ctr: target_ctr,
          missed_clicks_estimate: ((target_ctr - ctr) * impressions).round
        }
      end

      opportunities.sort_by { |o| -o[:missed_clicks_estimate] }
    end

    private

    def lookup_target_ctr(position)
      TARGET_CTR_BY_POSITION.each do |range, target|
        return target if range.cover?(position)
      end
      0.03 # default fallback
    end

    # Pulls broad query set; popular endpoint capped ~100 in API но
    # query_indicator + limit + offset позволяет dig deeper.
    def fetch_all_queries
      response = http.get(
        "user/#{@user_id}/hosts/#{@host_id}/search-queries/popular/",
        order_by: 'TOTAL_SHOWS',
        query_indicator: %w[TOTAL_SHOWS TOTAL_CLICKS AVG_SHOW_POSITION],
        limit: @limit
      )
      return [] unless response.success?

      JSON.parse(response.body)['queries']
    rescue Faraday::Error, JSON::ParserError => e
      Rails.logger.warn("[WebmasterOpportunities] fetch failed: #{e.class}: #{e.message}")
      []
    end

    def http
      @http ||= Faraday.new(
        BASE_URL,
        request: { params_encoder: Faraday::FlatParamsEncoder, timeout: 20, open_timeout: 5 }
      ) do |f|
        f.headers['Authorization'] = "OAuth #{@token}"
        f.request :retry, max: 2, interval: 0.5, backoff_factor: 2,
                          exceptions: [Faraday::TimeoutError, Faraday::ConnectionFailed]
      end
    end
  end
end
