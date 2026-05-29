# frozen_string_literal: true

module Telegram
  module WorkBot
    module Sla
      # Job-обёртка над `Sla::PingService` с self-defer логикой для quiet hours.
      #
      # Если сейчас тихие часы (21:00-07:00 Moscow) — job re-schedule сам себя
      # на `QuietHours.next_window_start` через Sidekiq scheduled set.
      # В рабочее время — сразу вызывает PingService.
      #
      # Вызывается из WatchdogJob через `PingJob.perform_later(lead.id, kind)`.
      class PingJob < ApplicationJob
        queue_as :scheduled

        def perform(lead_event_id, kind = :first_contact_overdue)
          defer = QuietHours.defer_until
          if defer
            Rails.logger.info("[Sla::PingJob] quiet hours — defer to #{defer.iso8601} lead=#{lead_event_id}")
            self.class.set(wait_until: defer).perform_later(lead_event_id, kind)
            return :deferred
          end

          lead = LeadEvent.find_by(id: lead_event_id)
          return :missing unless lead

          PingService.new(lead, kind: kind).call ? :delivered : :skipped
        end
      end
    end
  end
end
