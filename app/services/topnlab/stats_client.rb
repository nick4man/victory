# frozen_string_literal: true

module Topnlab
  # Counts-only client. Returns aggregate counts per deal_state for realty
  # and order types via Topnlab API, without pulling full entities.
  #
  # Used by AgencyMetricsService for the "обработано клиентских запросов" tile
  # on the landing page. Cached in Redis for 1 hour because Topnlab throttles
  # get_ids to 1 request per 6 seconds — a full sweep is ~80 reqs ≈ 8 minutes
  # of wall-clock and must NEVER run inline on a controller request.
  #
  # Refresh strategy:
  # - Background: RefreshTopnlabStatsJob every hour via whenever cron.
  # - Manual:     bin/rake topnlab:refresh_stats.
  # - Graceful:   if API errors (auth missing, timeout), return zeros + stale: true
  #               so /landing keeps rendering.
  class StatsClient
    CACHE_KEY = 'topnlab:stats:v1'
    CACHE_TTL = 1.hour

    REALTY_TYPES = %w[flat room house land commerce garage].freeze
    ACTIONS      = %w[sale rent].freeze
    ALL_STATES   = %w[lead active ad prepayment denied deal deferred archive].freeze

    # Never compute inline — sweep takes ~8 minutes due to API throttle.
    # On cache miss: enqueue a background refresh and return stale zeros so
    # /landing keeps rendering. The job warms the cache for the next request.
    def self.call
      cached = Rails.cache.read(CACHE_KEY)
      return cached if cached

      schedule_refresh
      new.send(:stale_zeros)
    end

    # Force a synchronous compute. Use only from background jobs / rake tasks,
    # NEVER from a controller request (would block 8+ minutes).
    def self.compute_now!
      stats = new.compute
      Rails.cache.write(CACHE_KEY, stats, expires_in: CACHE_TTL)
      stats
    end

    def self.bust!
      Rails.cache.delete(CACHE_KEY)
    end

    def self.schedule_refresh
      return if Rails.cache.read("#{CACHE_KEY}:refresh_pending")

      Rails.cache.write("#{CACHE_KEY}:refresh_pending", true, expires_in: 15.minutes)
      RefreshTopnlabStatsJob.perform_later if defined?(RefreshTopnlabStatsJob)
    rescue StandardError => e
      Rails.logger.warn("[Topnlab::StatsClient] schedule_refresh failed: #{e.message}")
    end

    def compute(client: Topnlab::Client.new)
      realty_counts = count_per_state(client, type: 'realty')
      order_counts  = count_per_state(client, type: 'order')

      realty_total = realty_counts.values.sum
      order_total  = order_counts.values.sum

      {
        realty_total:     realty_total,
        realty_per_state: realty_counts,
        order_total:      order_total,
        order_per_state:  order_counts,
        # "Обработано клиентских запросов" — sum of all realty (продавцы) and
        # all orders (покупатели/арендаторы), regardless of state. service
        # type is left out — it covers custom service requests, a different beast.
        processed_total:  realty_total + order_total,
        # Real closed deals — both seller side (realty.deal) and client side
        # (order.deal) reached the sale stage.
        closed_deals:     (realty_counts['deal'] || 0) + (order_counts['deal'] || 0),
        computed_at:      Time.current,
        stale:            false
      }
    rescue StandardError => e
      Rails.logger.warn("[Topnlab::StatsClient] failed: #{e.class} #{e.message}")
      stale_zeros
    end

    private

    def count_per_state(client, type:)
      counts = Hash.new(0)
      ALL_STATES.each do |state|
        ACTIONS.each do |action|
          if type == 'realty'
            REALTY_TYPES.each do |rt|
              counts[state] += safe_count(client, type: type, action: action, realty_type: rt, deal_state: [state])
            end
          else
            counts[state] += safe_count(client, type: type, action: action, deal_state: [state])
          end
        end
      end
      counts
    end

    def safe_count(client, **params)
      ids = client.get_ids(**params)
      ids.is_a?(Array) ? ids.size : 0
    rescue StandardError => e
      Rails.logger.warn("[Topnlab::StatsClient] slice failed #{params.inspect}: #{e.message.truncate(120)}")
      0
    end

    def stale_zeros
      {
        realty_total:     0,
        realty_per_state: {},
        order_total:      0,
        order_per_state:  {},
        processed_total:  0,
        closed_deals:     0,
        computed_at:      nil,
        stale:            true
      }
    end
  end
end
