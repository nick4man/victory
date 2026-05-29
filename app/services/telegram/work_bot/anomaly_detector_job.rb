# frozen_string_literal: true

module Telegram
  module WorkBot
    # Phase 16.7 — Sidekiq-cron job. Запускает AnomalyDetector, throttle'ит
    # findings per-staff-per-metric-per-day, дispatches DM via AnomalyNotifier.
    #
    # Расписание: 10:00 MSK пн-пт. Quiet hours (21:00-09:00 MSK) — skip,
    # чтобы manual-run в нерабочее время не зашумлял director'а.
    #
    # Idempotency: AlertThrottle TTL 24 часа per (staff_id, metric, today's date).
    # Двойной запуск в течение дня → второй запуск 0 DMs.
    class AnomalyDetectorJob
      include Sidekiq::Job

      sidekiq_options queue: :scheduled, retry: 1

      QUIET_START_HOUR = 21
      QUIET_END_HOUR = 9

      def perform
        return :quiet_hours if quiet_hours?

        anomalies = AnomalyDetector.run
        detected = anomalies.size
        sent = 0
        throttled = 0

        anomalies.each do |a|
          key = throttle_key(a)
          if Telegram::AlertThrottle.allow?(key: key, ttl: 24.hours)
            sent += AnomalyNotifier.call(a)
          else
            throttled += 1
          end
        rescue StandardError => e
          Rails.logger.warn("[AnomalyDetectorJob] notify failed for staff##{a.staff.id} #{a.metric}: " \
                            "#{e.class} #{e.message}")
        end

        Rails.logger.info("[AnomalyDetectorJob] detected=#{detected} sent=#{sent} throttled=#{throttled}")
        :done
      end

      private

      def quiet_hours?
        hour = Time.current.in_time_zone('Europe/Moscow').hour
        hour >= QUIET_START_HOUR || hour < QUIET_END_HOUR
      end

      def throttle_key(anomaly)
        "anomaly:#{anomaly.staff.id}:#{anomaly.metric}:#{Date.current}"
      end
    end
  end
end
