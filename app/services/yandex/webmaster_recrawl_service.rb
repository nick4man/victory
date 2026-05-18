# frozen_string_literal: true

module Yandex
  # POST URL(s) to Yandex.Webmaster recrawl queue — agent asks Yandex
  # crawler to revisit a page. Used after publishing new SEO landing
  # OR fixing critical issue (broken metadata, soft-404).
  #
  # Daily quota — Yandex enforces ~5-10 recrawl/day per host (varies by
  # site authority). Service ALWAYS checks quota first; refuses POST if
  # remaining < min_remaining (default 1) or > burn_threshold percentage
  # of daily allocation already used.
  #
  # Naming: «recrawl» в Yandex API = повторный обход уже известных URLs.
  # Для совсем новых URL'ов нужна другая отдельная action (через sitemap
  # refresh). Этот service — только known URLs.
  class WebmasterRecrawlService
    BASE_URL = 'https://api.webmaster.yandex.net/v4/'
    DEFAULT_HOST = 'https:victory62.org:443'

    class ConfigError < StandardError; end
    class QuotaExceeded < StandardError; end

    Result = Struct.new(:ok?, :queued_url, :task_id, :remaining_quota, :error, keyword_init: true)

    # @param min_remaining [Integer] refuse POST if quota left < this number
    # @param burn_threshold [Float] refuse POST if used > this fraction of daily allocation
    def self.queue(url, min_remaining: 1, burn_threshold: 0.8)
      new.queue(url, min_remaining: min_remaining, burn_threshold: burn_threshold)
    end

    # Check remaining quota без POST'a — useful for KPI / dashboard.
    def self.quota
      new.quota
    end

    def initialize(host_id: nil)
      @token = ENV['YANDEX_WEBMASTER_TOKEN'].to_s
      @user_id = ENV['YANDEX_WEBMASTER_USER_ID'].to_s
      raise ConfigError, 'YANDEX_WEBMASTER_TOKEN env var missing' if @token.empty?
      raise ConfigError, 'YANDEX_WEBMASTER_USER_ID env var missing' if @user_id.empty?

      @host_id = host_id || DEFAULT_HOST
    end

    def quota
      response = http.get(quota_path)
      return nil unless response.success?

      data = JSON.parse(response.body)
      # Actual API response (verified 18.05.2026): {"daily_quota": 150, "quota_remainder": 149}
      # Эндпоинт `/recrawl/queue/quota/` использует `quota_remainder` ключ,
      # НЕ `quota_remaining_daily`. Раньше парсер всегда читал 0 → quota
      # казалась исчерпанной → service отказывался queue'ить URL'ы.
      daily = data['daily_quota'].to_i
      remaining = (data['quota_remainder'] || data['quota_remaining_daily']).to_i
      {
        daily: daily,
        remaining: remaining,
        used: daily - remaining,
        used_fraction: daily.positive? ? (1 - remaining.to_f / daily).round(3) : 0.0
      }
    rescue Faraday::Error, JSON::ParserError => e
      Rails.logger.warn("[WebmasterRecrawl] quota fetch failed: #{e.class}: #{e.message}")
      nil
    end

    def queue(url, min_remaining: 1, burn_threshold: 0.8)
      q = quota
      return Result.new(ok?: false, error: 'quota unavailable') unless q

      if q[:remaining] < min_remaining
        return Result.new(ok?: false, remaining_quota: q[:remaining],
                          error: "quota exhausted (#{q[:remaining]} remaining)")
      end
      if q[:used_fraction] >= burn_threshold
        return Result.new(ok?: false, remaining_quota: q[:remaining],
                          error: "burn-threshold (#{(q[:used_fraction] * 100).round}% used, threshold #{(burn_threshold * 100).round}%)")
      end

      response = http.post(queue_path) do |req|
        req.headers['Content-Type'] = 'application/json'
        req.body = JSON.generate(url: url)
      end

      if response.success?
        body = JSON.parse(response.body)
        Result.new(ok?: true, queued_url: url, task_id: body['task_id'],
                   remaining_quota: q[:remaining] - 1)
      else
        Result.new(ok?: false, queued_url: url, remaining_quota: q[:remaining],
                   error: "HTTP #{response.status}: #{response.body.to_s.truncate(200)}")
      end
    rescue Faraday::Error, JSON::ParserError => e
      Result.new(ok?: false, queued_url: url, error: "#{e.class}: #{e.message}")
    end

    private

    # Path verified 18.05.2026 via curl: `/recrawl/quota/` returns
    # {"daily_quota":150,"quota_remainder":149}. Раньше пробовал
    # `/recrawl/queue/quota/` → HTTP 400 (Yandex treated 'quota' как
    # task-id UUID). Тонкий API quirk — quota НЕ под queue/.
    def quota_path
      "user/#{@user_id}/hosts/#{@host_id}/recrawl/quota/"
    end

    def queue_path
      "user/#{@user_id}/hosts/#{@host_id}/recrawl/queue/"
    end

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
