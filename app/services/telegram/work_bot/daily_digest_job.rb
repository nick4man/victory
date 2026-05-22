# frozen_string_literal: true

module Telegram
  module WorkBot
    # Phase 15 — ежедневный digest для директоров в DM (08:30 MSK).
    # Дополняет существующий Kpi::MorningDigestJob (per-staff, для каждого
    # отдельного сотрудника): этот — director-only, agency-wide consolidated
    # snapshot. По сути shorter version DirectorDashboard рендера.
    #
    # Поведение:
    #   • Получатель: TelegramUser.directors.active с dm_chat_id present
    #   • Время: 08:30 MSK (за 30 мин до morning_digest сотрудникам, чтобы
    #     директор успел просмотреть agency-state до per-staff раздачи)
    #   • Содержание: agency totals + top/bottom performers + alerts
    #   • Inline-кнопки: [📊 Полный dashboard] [🔍 Детали]
    #
    # Quiet hours: 21:00-08:00 MSK не шлём. Если cron триггерится в quiet —
    # skip (job отрабатывает без error). Реально cron в 08:30 — в quiet
    # никогда не попадёт, but safety check для manual runs.
    class DailyDigestJob
      include Sidekiq::Job

      sidekiq_options queue: :scheduled, retry: 1

      QUIET_START_HOUR = 21
      QUIET_END_HOUR = 8

      def perform
        return :quiet_hours if quiet_hours?

        sent = 0
        skipped = 0
        TelegramUser.directors.where(status: 'active').find_each do |director|
          if director.dm_chat_id.blank?
            skipped += 1
            next
          end

          digest = build_digest_for(director)
          send_digest(director, digest)
          sent += 1
        rescue StandardError => e
          Rails.logger.warn("[DailyDigestJob] failed for director ##{director.id}: #{e.class} #{e.message}")
        end

        Rails.logger.info("[DailyDigestJob] sent=#{sent} skipped=#{skipped}")
        :done
      end

      private

      def quiet_hours?
        hour = Time.current.in_time_zone('Europe/Moscow').hour
        hour >= QUIET_START_HOUR || hour < QUIET_END_HOUR
      end

      def build_digest_for(_director)
        yesterday = 1.day.ago.beginning_of_day..1.day.ago.end_of_day

        leads_yesterday = LeadEvent.where(created_at: yesterday)
        leads_won = LeadEvent.where(current_stage: 'closed_won', updated_at: yesterday)
        leads_lost = LeadEvent.where(current_stage: 'closed_lost', updated_at: yesterday)
        tasks_done = ::Task.status_done.where(updated_at: yesterday)
        tasks_overdue = ::Task.status_open.overdue.count

        # Top performer вчера
        top = ::Task.status_done.where(updated_at: yesterday).group(:assignee_id).count
                    .max_by { |_, n| n }
        top_user = top ? TelegramUser.find_by(id: top.first) : nil

        # SLA breach
        sla_breach = ::Task.status_open.where('due_at < ?', 3.days.ago).count

        date = 1.day.ago.strftime('%d.%m.%y')

        lines = ["🌅 <b>Доброе утро. Сводка за #{date}</b>"]
        lines << ''
        lines << "🎯 Лиды: <b>#{leads_yesterday.count}</b> новых, <b>#{leads_won.count}</b> won / <b>#{leads_lost.count}</b> lost"
        lines << "✅ Задачи: <b>#{tasks_done.count}</b> выполнено, <b>#{tasks_overdue}</b> overdue"
        if top_user && top.last.positive?
          lines << "🏆 Top performer: #{top_user.mention} (<b>#{top.last}</b> задач)"
        end
        if sla_breach.positive?
          lines << "⚠️ SLA breach (3+ дня overdue): <b>#{sla_breach}</b>"
        end
        lines << ''
        lines << '<i>Открой полный dashboard кнопкой ниже или /dashboard</i>'

        lines.join("\n")
      end

      def send_digest(director, digest_markdown)
        Telegram::Client.new.send_message(
          digest_markdown,
          chat_id: director.dm_chat_id,
          parse_mode: 'HTML',
          reply_markup: {
            inline_keyboard: [[
              { text: '📊 Полный dashboard', callback_data: 'dashboard:refresh' }
            ]]
          }
        )
      end
    end
  end
end
