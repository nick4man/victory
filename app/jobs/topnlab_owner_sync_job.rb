# frozen_string_literal: true

# Enriches Property#owner_user_id by pulling seller-client data from Topnlab.
#
# Runs as a low-priority background sweep. Safe to re-enqueue repeatedly —
# OwnerSyncService only processes properties with owner_user_id = nil.
#
# Scheduling recommendation: run once daily (e.g. 03:00), or trigger manually
# after a bulk import. Does NOT need to run every 30 min — owner linkage
# rarely changes after a property enters the system.
#
# Rate: ~1 API call/sec (Topnlab fast throttle). 73 active properties ≈ 75s.
class TopnlabOwnerSyncJob < ApplicationJob
  queue_as :scheduled

  LOCK_KEY = 'topnlab:owner_sync_lock'
  LOCK_TTL = 20 * 60 # 20 min should cover even 200 properties

  def perform(limit: Topnlab::OwnerSyncService::BATCH_LIMIT)
    locked = Sidekiq.redis { |r| r.set(LOCK_KEY, 1, ex: LOCK_TTL, nx: true) }
    return Rails.logger.info('[TopnlabOwnerSyncJob] lock held by another run; skipping') unless locked

    result = Topnlab::OwnerSyncService.new.call(limit: limit)
    Rails.logger.info("[TopnlabOwnerSyncJob] #{result.inspect}")
  ensure
    begin
      Sidekiq.redis { |r| r.del(LOCK_KEY) }
    rescue StandardError
      nil
    end
  end
end
