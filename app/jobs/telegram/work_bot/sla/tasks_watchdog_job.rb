# frozen_string_literal: true

module Telegram
  module WorkBot
    module Sla
      # Сканер просроченных задач (Task.status_open + due_at < now) — каждые 5 мин.
      # Для каждой просрочки шлёт DM assignee «📌 Просрочена задача …».
      # Дедуп через `Task.last_pinged_at` — не чаще раз в 6 часов (агент не должен
      # получать спам по одной и той же висящей задаче каждые 5 мин).
      #
      # Quiet hours обрабатываются обёрткой `TaskPingJob`.
      class TasksWatchdogJob < ApplicationJob
        queue_as :scheduled

        DEDUP_WINDOW = 6.hours

        def perform
          window_threshold = DEDUP_WINDOW.ago
          scope = ::Task.status_open
                        .where(due_at: ..Time.current)
                        .where.not(assignee_id: nil)
                        .where('last_pinged_at IS NULL OR last_pinged_at < ?', window_threshold)

          total = scope.count
          enqueued = 0

          scope.find_each do |task|
            TaskPingJob.perform_later(task.id)
            enqueued += 1
          end

          Rails.logger.info("[Sla::TasksWatchdogJob] candidates=#{total} enqueued=#{enqueued}")
          { candidates: total, enqueued: enqueued }
        end
      end
    end
  end
end
