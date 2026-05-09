# frozen_string_literal: true

# Periodic Topnlab MLS sync. Locked via Redis to prevent overlap if Sidekiq cron
# misfires or a manual rake task collides with the schedule.
class MlsSyncJob < ApplicationJob
  queue_as :scheduled

  LOCK_KEY = 'mls:sync_lock'
  LOCK_TTL = 3 * 60 * 60 # 3 hours

  def perform
    locked = Sidekiq.redis { |r| r.set(LOCK_KEY, 1, ex: LOCK_TTL, nx: true) }
    return Rails.logger.info('[MlsSyncJob] another run holds the lock; skipping') unless locked

    result = MlsSync::TopnlabSyncService.new.call
    Rails.logger.info("[MlsSyncJob] #{result.inspect}")
  ensure
    begin
      Sidekiq.redis { |r| r.del(LOCK_KEY) }
    rescue StandardError
      nil
    end
  end
end
