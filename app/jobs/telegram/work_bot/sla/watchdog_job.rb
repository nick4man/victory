# frozen_string_literal: true

module Telegram
  module WorkBot
    module Sla
      # Сканер просрочек first_contact — каждые 5 мин из cron (config/schedule.rb).
      # Триггер пинга:
      #   - `current_stage == 'new'`
      #   - `assigned_to_id IS NOT NULL`
      #   - `assigned_at < 30.minutes.ago`
      #   - `first_contact_at IS NULL`
      #   - не закрыт (closed_at IS NULL)
      #
      # Дедуп per-lead делает `PingService` через `metadata.last_sla_ping_at`
      # (раз в 30 мин максимум).
      class WatchdogJob < ApplicationJob
        queue_as :scheduled

        FIRST_CONTACT_SLA_MINUTES = 30

        def perform
          window = FIRST_CONTACT_SLA_MINUTES.minutes.ago
          scope = LeadEvent
                  .where(current_stage: 'new')
                  .where(first_contact_at: nil)
                  .where(closed_at: nil)
                  .where.not(assigned_to_id: nil)
                  .where(assigned_at: ..window)

          total = scope.count
          enqueued = 0

          scope.find_each do |lead|
            PingJob.perform_later(lead.id, :first_contact_overdue)
            enqueued += 1
          end

          Rails.logger.info("[Sla::WatchdogJob] candidates=#{total} enqueued=#{enqueued}")
          { candidates: total, enqueued: enqueued }
        end
      end
    end
  end
end
