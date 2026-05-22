# frozen_string_literal: true

module Telegram
  module WorkBot
    # Phase 15 — недельная сводка для директоров (пн 10:00 MSK).
    # Дополняет существующий Kpi::WeeklyReportJob (managers+directors, agency
    # totals): этот — director-only, акцент на trends + anomalies + LLM cost.
    #
    # Содержание:
    #   • Цифры за неделю vs предыдущую: leads, tasks, conversion, SLA
    #   • Top-3 performers
    #   • Bottom-1 performer (если есть статистически значимый отрыв)
    #   • Overdue anomalies (>2σ — расширение KpiFor)
    #   • LLM cost report (если Redis.omni_cost доступен)
    class WeeklySummaryJob
      include Sidekiq::Job

      sidekiq_options queue: :scheduled, retry: 1

      def perform
        sent = 0
        TelegramUser.directors.where(status: 'active').find_each do |director|
          next if director.dm_chat_id.blank?

          summary = build_summary
          send_summary(director, summary)
          sent += 1
        rescue StandardError => e
          Rails.logger.warn("[WeeklySummaryJob] failed for director ##{director.id}: #{e.class} #{e.message}")
        end

        Rails.logger.info("[WeeklySummaryJob] sent=#{sent}")
        :done
      end

      private

      def build_summary
        now_range = 7.days.ago.beginning_of_day..Time.current
        prev_range = 14.days.ago.beginning_of_day..7.days.ago.end_of_day

        now_kpi = compute(now_range)
        prev_kpi = compute(prev_range)

        lines = ["📊 <b>Недельный отчёт · #{7.days.ago.strftime('%d.%m')}–#{Time.current.strftime('%d.%m.%y')}</b>"]
        lines << ''
        lines << "🎯 Лиды: <b>#{now_kpi[:leads_total]}</b> (#{trend(now_kpi[:leads_total], prev_kpi[:leads_total])} #{prev_kpi[:leads_total]})"
        lines << "  • won: <b>#{now_kpi[:leads_won]}</b> | lost: <b>#{now_kpi[:leads_lost]}</b>"
        lines << "  • Conversion: <b>#{now_kpi[:conversion]}%</b> (vs #{prev_kpi[:conversion]}% #{trend(now_kpi[:conversion], prev_kpi[:conversion])})"
        lines << ''
        lines << "✅ Задачи: <b>#{now_kpi[:tasks_done]}</b> done (vs #{prev_kpi[:tasks_done]} #{trend(now_kpi[:tasks_done], prev_kpi[:tasks_done])})"
        lines << "  • SLA on-time: <b>#{now_kpi[:on_time]}%</b> (vs #{prev_kpi[:on_time]}% #{trend(now_kpi[:on_time], prev_kpi[:on_time])})"

        if (top3 = top_performers(now_range)).any?
          lines << ''
          lines << '🏆 <b>Top-3 за неделю:</b>'
          top3.each_with_index do |(user, count), i|
            lines << "  #{i + 1}. #{user.mention} — <b>#{count}</b> задач"
          end
        end

        if (anomalies = overdue_anomalies(now_range)).any?
          lines << ''
          lines << '⚠️ <b>Аномалии overdue (>2σ):</b>'
          anomalies.each do |a|
            lines << "  • #{a[:mention]} — <b>#{a[:overdue]}</b> overdue (#{a[:deviation]}σ)"
          end
        end

        if (cost = llm_cost_report).present?
          lines << ''
          lines << "💸 LLM cost: #{cost}"
        end

        lines.join("\n")
      end

      def compute(range)
        leads = LeadEvent.where(updated_at: range)
        leads_won = leads.where(current_stage: 'closed_won').count
        leads_lost = leads.where(current_stage: 'closed_lost').count
        leads_total = leads.count
        closed_total = leads_won + leads_lost
        conversion = closed_total.positive? ? (leads_won * 100.0 / closed_total).round : 0

        tasks_done = ::Task.status_done.where(updated_at: range)
        tasks_on_time = tasks_done.where('due_at IS NULL OR updated_at <= due_at').count
        on_time = tasks_done.count.positive? ? (tasks_on_time * 100.0 / tasks_done.count).round : 0

        {
          leads_total: leads_total,
          leads_won: leads_won,
          leads_lost: leads_lost,
          conversion: conversion,
          tasks_done: tasks_done.count,
          on_time: on_time
        }
      end

      def trend(now, prev)
        return '→' if now == prev
        return '↑' if now > prev

        '↓'
      end

      def top_performers(range)
        counts = ::Task.status_done.where(updated_at: range).group(:assignee_id).count
        counts.sort_by { |_, n| -n }.first(3).map do |aid, n|
          [TelegramUser.find_by(id: aid), n]
        end.compact
      end

      def overdue_anomalies(range)
        per_staff = ::Task.status_open.overdue.group(:assignee_id).count
        return [] if per_staff.size < 3

        values = per_staff.values
        mean = values.sum.to_f / values.size
        variance = values.sum { |v| (v - mean)**2 } / values.size
        stddev = Math.sqrt(variance)
        return [] if stddev <= 0

        threshold = mean + (2 * stddev)
        per_staff.select { |_aid, v| v > threshold && v.positive? }.map do |aid, v|
          u = TelegramUser.find_by(id: aid)
          { mention: u&.mention || "id:#{aid}", overdue: v, deviation: ((v - mean) / stddev).round(1) }
        end
      end

      # LLM cost из Redis counters omni:cost:* (Llm::OmniClient записывает).
      def llm_cost_report
        return nil unless defined?(Redis)

        redis = Redis.new(url: ENV['REDIS_URL'].presence || 'redis://localhost:6379/0')
        chat_cost = redis.get('omni:cost:chat').to_i
        analysis_cost = redis.get('omni:cost:analysis').to_i
        staff_cost = redis.get('omni:cost:staff_analysis').to_i
        total = chat_cost + analysis_cost + staff_cost
        return nil if total.zero?

        "weighted=#{total} (chat=#{chat_cost}, analysis=#{analysis_cost}, staff=#{staff_cost}). " \
          "Веса: free=0, cheap=1, paid=5, premium=50."
      rescue StandardError
        nil
      end

      def send_summary(director, markdown)
        Telegram::Client.new.send_message(
          markdown,
          chat_id: director.dm_chat_id,
          parse_mode: 'HTML',
          reply_markup: {
            inline_keyboard: [[
              { text: '📊 Текущий dashboard', callback_data: 'dashboard:refresh' }
            ]]
          }
        )
      end
    end
  end
end
