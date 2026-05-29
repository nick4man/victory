# frozen_string_literal: true

class TopnlabOrdersSyncJob < ApplicationJob
  queue_as :scheduled

  LOCK_KEY = 'topnlab:orders_sync_lock'
  LOCK_TTL = 30 * 60

  def perform
    locked = Sidekiq.redis { |r| r.set(LOCK_KEY, 1, ex: LOCK_TTL, nx: true) }
    return Rails.logger.info('[TopnlabOrdersSyncJob] another run holds the lock; skipping') unless locked

    result = Topnlab::OrdersImporter.new.call
    Rails.logger.info("[TopnlabOrdersSyncJob] #{result.inspect}")
  ensure
    begin
      Sidekiq.redis { |r| r.del(LOCK_KEY) }
    rescue StandardError
      nil
    end
  end
end
