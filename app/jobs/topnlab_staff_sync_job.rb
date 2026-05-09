# frozen_string_literal: true

class TopnlabStaffSyncJob < ApplicationJob
  queue_as :scheduled

  LOCK_KEY = 'topnlab:staff_sync_lock'
  LOCK_TTL = 30 * 60

  def perform
    locked = Sidekiq.redis { |r| r.set(LOCK_KEY, 1, ex: LOCK_TTL, nx: true) }
    return Rails.logger.info('[TopnlabStaffSyncJob] another run holds the lock; skipping') unless locked

    result = Topnlab::StaffSyncService.new.call
    Rails.logger.info("[TopnlabStaffSyncJob] #{result.inspect}")
  ensure
    begin
      Sidekiq.redis { |r| r.del(LOCK_KEY) }
    rescue StandardError
      nil
    end
  end
end
