# frozen_string_literal: true

# Phase 7.2 — Помечает TaskBatch как expired если pending > 1 часа.
# Запускается cron каждые 10 минут (см. config/sidekiq_cron.yml).
class TaskBatchExpiryJob
  include Sidekiq::Job

  sidekiq_options queue: :scheduled, retry: 1

  EXPIRY_AGE = 1.hour

  def perform
    candidates = TaskBatch.expired_candidates(older_than: EXPIRY_AGE.ago)
    count = candidates.count
    return :no_pending if count.zero?

    candidates.find_each(&:expire!)
    Rails.logger.info("[TaskBatchExpiryJob] expired #{count} batches (pending > #{EXPIRY_AGE.inspect})")
    { expired: count }
  end
end
