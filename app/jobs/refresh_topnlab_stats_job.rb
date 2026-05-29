# frozen_string_literal: true

# Refreshes the Topnlab counts cache out-of-band (Topnlab throttles get_ids
# to 1 req / 6s, so a full sweep is ~8 minutes — must not run inline).
# Scheduled hourly via whenever (config/schedule.rb) and on demand via
# `bin/rake topnlab:refresh_stats`.
class RefreshTopnlabStatsJob < ApplicationJob
  queue_as :low_priority

  def perform
    stats = Topnlab::StatsClient.compute_now!
    Rails.cache.delete("#{Topnlab::StatsClient::CACHE_KEY}:refresh_pending")
    AgencyMetricsService.bust!
    Rails.logger.info(
      "[RefreshTopnlabStatsJob] processed=#{stats[:processed_total]} " \
      "realty=#{stats[:realty_total]} orders=#{stats[:order_total]} " \
      "closed=#{stats[:closed_deals]} stale=#{stats[:stale]}"
    )
    stats
  end
end
