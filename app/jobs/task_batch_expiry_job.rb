# frozen_string_literal: true

# Phase 7.2 — Помечает TaskBatch как expired если pending > 1 часа.
# Запускается cron каждые 10 минут (см. config/sidekiq_cron.yml).
class TaskBatchExpiryJob
  include Sidekiq::Job

  sidekiq_options queue: :scheduled, retry: 1

  EXPIRY_AGE = 1.hour

  def perform
    batches = expire_batches
    reports = expire_show_reports
    return :no_pending if batches.zero? && reports.zero?

    { expired: batches, expired_show_reports: reports }
  end

  private

  def expire_batches
    candidates = TaskBatch.expired_candidates(older_than: EXPIRY_AGE.ago)
    count = candidates.count
    return 0 if count.zero?

    candidates.find_each(&:expire!)
    Rails.logger.info("[TaskBatchExpiryJob] expired #{count} batches (pending > #{EXPIRY_AGE.inspect})")
    count
  end

  # BOTTLENECK — см. ShowReport#expire!. Тот же час, тот же крон: отдельный джоб
  # и отдельная строка расписания для этого не нужны.
  def expire_show_reports
    candidates = ShowReport.expired_candidates(older_than: EXPIRY_AGE.ago)
    count = candidates.count
    return 0 if count.zero?

    candidates.find_each(&:expire!)
    Rails.logger.info("[TaskBatchExpiryJob] expired #{count} show_reports (pending > #{EXPIRY_AGE.inspect})")
    count
  end
end
