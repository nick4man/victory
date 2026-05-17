# frozen_string_literal: true

module Kpi
  # Phase 7.6 — cron 23:55 daily. Создаёт StaffMetric snapshot за прошедший
  # день для каждого assignable TelegramUser. Idempotent через upsert.
  class StaffSnapshotJob
    include Sidekiq::Job

    sidekiq_options queue: :scheduled, retry: 2

    def perform(date_str = nil)
      date = date_str.present? ? Date.parse(date_str) : Date.current
      results = Kpi::StaffSnapshot.run!(date: date)
      Rails.logger.info("[Kpi::StaffSnapshotJob] computed #{results.size} StaffMetric records for #{date}")
      { date: date.iso8601, count: results.size }
    end
  end
end
