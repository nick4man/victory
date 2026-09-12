# frozen_string_literal: true

module Telegram
  module WorkBot
    module Sla
      # Сканер просрочек first_contact — каждые 5 мин, см. `sla_watchdog`
      # в config/sidekiq_cron.yml.
      # Триггер пинга:
      #   - `current_stage == 'new'`
      #   - `assigned_to_id IS NOT NULL`
      #   - `assigned_at` в окне [24 часа назад .. 30 минут назад]
      #   - `first_contact_at IS NULL`
      #   - не закрыт (closed_at IS NULL)
      #
      # Дедуп per-lead делает `PingService` через `metadata.last_sla_ping_at`,
      # но это нижняя граница частоты (не чаще раза в 30 мин), а не потолок
      # числа напоминаний: лид, по которому никто не проставил first_contact,
      # пингуется заново бесконечно. Поэтому у окна есть и вторая граница —
      # `BACKLOG_HORIZON`.
      #
      # Лид, провисевший дольше горизонта, это уже не «просрочка SLA», а
      # брошенный лид: напоминать по нему каждые полчаса бессмысленно, а вред
      # реальный — агент мьютит бота и вместе со спамом теряет живые анонсы
      # (тот же провал, что описан у `owner_request`). Такие лиды из выборки
      # выпадают, но не молча: их число уходит в лог отдельным счётчиком.
      class WatchdogJob < ApplicationJob
        queue_as :scheduled

        FIRST_CONTACT_SLA_MINUTES = 30
        BACKLOG_HORIZON = 24.hours

        def perform
          window  = FIRST_CONTACT_SLA_MINUTES.minutes.ago
          horizon = BACKLOG_HORIZON.ago

          scope = awaiting_first_contact.where(assigned_at: horizon..window)
          abandoned = awaiting_first_contact.where(assigned_at: ...horizon).count

          total = scope.count
          enqueued = 0

          scope.find_each do |lead|
            PingJob.perform_later(lead.id, :first_contact_overdue)
            enqueued += 1
          end

          Rails.logger.info("[Sla::WatchdogJob] candidates=#{total} enqueued=#{enqueued} " \
                            "abandoned=#{abandoned} (старше #{BACKLOG_HORIZON.inspect}, не пингуем)")
          { candidates: total, enqueued: enqueued, abandoned: abandoned }
        end

        private

        # Лиды, назначенные и так и не взятые в работу, безотносительно возраста.
        def awaiting_first_contact
          LeadEvent
            .where(current_stage: 'new')
            .where(first_contact_at: nil)
            .where(closed_at: nil)
            .where.not(assigned_to_id: nil)
        end
      end
    end
  end
end
