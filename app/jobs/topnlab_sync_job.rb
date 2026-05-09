# frozen_string_literal: true

# Periodic full sweep of Topnlab → Property. Scheduled via sidekiq-cron.
# Concurrency lock via Redis ensures only one run at a time.
class TopnlabSyncJob < ApplicationJob
  queue_as :scheduled

  LOCK_KEY = 'topnlab:sync_lock'
  LOCK_TTL = 1800  # 30 min

  def perform
    locked = Sidekiq.redis { |r| r.set(LOCK_KEY, Time.current.to_i, ex: LOCK_TTL, nx: true) }
    unless locked
      Rails.logger.info('TopnlabSyncJob: another run is in progress, skipping')
      return
    end

    result = Topnlab::Importer.new.call
    Rails.logger.info("TopnlabSyncJob result: #{result.inspect}")
  ensure
    Sidekiq.redis { |r| r.del(LOCK_KEY) } rescue nil
  end
end
