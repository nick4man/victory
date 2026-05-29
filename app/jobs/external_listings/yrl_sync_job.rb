# frozen_string_literal: true

# Periodic refresh of all YRL feeds configured via ENV['YRL_FEED_URLS'].
# Scheduled via sidekiq-cron (every 4h). Lock-protected so a slow feed
# can't overlap with the next scheduled run.
module ExternalListings
  class YrlSyncJob < ApplicationJob
    queue_as :scheduled

    LOCK_KEY = 'external_listings:yrl_sync_lock'
    LOCK_TTL = 2 * 60 * 60 # 2 hours

    def perform
      locked = Sidekiq.redis { |r| r.set(LOCK_KEY, 1, ex: LOCK_TTL, nx: true) }
      return Rails.logger.info('[YrlSyncJob] lock held; skipping') unless locked

      urls = ENV.fetch('YRL_FEED_URLS', '').split(',').map(&:strip).reject(&:empty?)
      return Rails.logger.info('[YrlSyncJob] no YRL_FEED_URLS configured') if urls.empty?

      totals = { fetched: 0, upserted: 0, errors: 0 }
      urls.each do |url|
        result = ExternalListings::YrlParser.new(url).call
        Rails.logger.info("[YrlSyncJob] #{url} → fetched=#{result[:fetched]} upserted=#{result[:upserted]}")
        totals[:fetched]  += result[:fetched]
        totals[:upserted] += result[:upserted]
        totals[:errors]   += result[:errors].size
      rescue StandardError => e
        Rails.logger.warn("[YrlSyncJob] feed=#{url}: #{e.class} #{e.message.truncate(160)}")
        totals[:errors] += 1
      end

      Rails.logger.info("[YrlSyncJob] totals: #{totals.inspect}")
    ensure
      begin
        Sidekiq.redis { |r| r.del(LOCK_KEY) }
      rescue StandardError
        nil
      end
    end
  end
end
