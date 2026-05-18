# frozen_string_literal: true

module Kpi
  # Phase 6 — Weekly agency-level report. DM'ed to managers + directors каждый
  # понедельник 10:00 MSK. Aggregates StaffMetric за прошлую неделю
  # (Mon-Sun), показывает per-staff ranking + agency trends.
  #
  # Format optimised для mobile/preview:
  #   📅 Header (период)
  #   📊 Agency totals (tasks, leads, conversion)
  #   🏆 Top 3 (по completed) + Bottom 3 (просрочки)
  #   📈 Trend (vs previous week)
  #
  # @example
  #   Kpi::WeeklyReport.new(week_end: Date.current).build_text
  class WeeklyReport
    def initialize(week_end: Date.current.prev_day, now: Time.current)
      # week_end по умолчанию = вчера (рассылается утром в понедельник, охватывает Mon-Sun прошлой недели)
      @week_end = week_end
      @week_start = week_end - 6.days
      @prev_week_end = @week_start - 1.day
      @prev_week_start = @prev_week_end - 6.days
      @now = now
    end

    def build_text
      week_metrics = ::StaffMetric.for_period(@week_start..@week_end).to_a
      prev_metrics = ::StaffMetric.for_period(@prev_week_start..@prev_week_end).to_a

      [
        header,
        '',
        agency_totals(week_metrics, prev_metrics),
        '',
        per_staff_ranking(week_metrics),
        '',
        bottom_block(week_metrics),
        '',
        trend_summary(week_metrics, prev_metrics)
      ].join("\n")
    end

    private

    def header
      "📅 <b>Недельный отчёт АН «Виктори»</b>\n" \
        "Период: #{@week_start.strftime('%d.%m')} — #{@week_end.strftime('%d.%m.%y')}"
    end

    def agency_totals(week, prev_week)
      cur = sum_metrics(week)
      prev = sum_metrics(prev_week)

      lines = ['📊 <b>Агентство в цифрах:</b>']
      lines << "  Задач: <b>#{cur[:done]}/#{cur[:assigned]}</b> #{delta_pct(cur[:done], prev[:done])}"
      lines << "  On-time: <b>#{rate(cur[:on_time], cur[:done])}%</b>"
      lines << "  Лидов: <b>#{cur[:leads]}</b> назначено, " \
               "first-contact-30min: <b>#{rate(cur[:fc30], cur[:leads])}%</b>"
      lines << "  Выиграно: <b>#{cur[:won]}</b> (conversion <b>#{rate(cur[:won], cur[:leads])}%</b>)"
      lines.join("\n")
    end

    def per_staff_ranking(week)
      # Group by staff_id, sum within week
      by_staff = week.group_by(&:staff_id).map do |staff_id, mets|
        staff = TelegramUser.find_by(id: staff_id)
        next nil if staff.nil?

        agg = sum_metrics(mets)
        next nil if agg[:assigned].zero? && agg[:leads].zero?

        { staff: staff, completed: agg[:done], on_time_rate: rate(agg[:on_time], agg[:done]),
          assigned: agg[:assigned], leads: agg[:leads] }
      end.compact.sort_by { |r| -r[:completed] }

      return '<i>📊 Нет данных за неделю.</i>' if by_staff.empty?

      top = by_staff.first(3)
      lines = ['🏆 <b>Топ сотрудников:</b>']
      top.each_with_index do |row, i|
        medal = %w[🥇 🥈 🥉][i] || '•'
        lines << "  #{medal} #{row[:staff].mention} — выполнено <b>#{row[:completed]}</b>/" \
                 "#{row[:assigned]} (on-time #{row[:on_time_rate]}%)"
      end
      lines.join("\n")
    end

    def bottom_block(week)
      # Найти сотрудников с наибольшим количеством overdue/suspicious
      sus = week.group_by(&:staff_id).map do |staff_id, mets|
        staff = TelegramUser.find_by(id: staff_id)
        next nil if staff.nil?

        agg = sum_metrics(mets)
        next nil if agg[:overdue].zero? && agg[:suspicious].zero?

        { staff: staff, overdue: agg[:overdue], suspicious: agg[:suspicious] }
      end.compact.sort_by { |r| -(r[:overdue] + r[:suspicious]) }.first(3)

      return '' if sus.empty?

      lines = ['⚠️ <b>Внимание:</b>']
      sus.each do |row|
        bits = []
        bits << "overdue=#{row[:overdue]}" if row[:overdue].positive?
        bits << "suspicious=#{row[:suspicious]}" if row[:suspicious].positive?
        lines << "  • #{row[:staff].mention} — #{bits.join(', ')}"
      end
      lines.join("\n")
    end

    def trend_summary(week, prev_week)
      cur = sum_metrics(week)
      prev = sum_metrics(prev_week)
      direction = cur[:done] >= prev[:done] ? '📈' : '📉'
      cur_conv = rate(cur[:won], cur[:leads])
      prev_conv = rate(prev[:won], prev[:leads])

      "#{direction} <i>Trend: задач #{cur[:done]} vs #{prev[:done]} (#{delta_pct(cur[:done], prev[:done])}); " \
        "conversion #{cur_conv}% vs #{prev_conv}%</i>"
    end

    # === Aggregation helpers ===

    def sum_metrics(metrics)
      {
        assigned: metrics.sum(&:tasks_assigned),
        done: metrics.sum(&:tasks_completed),
        on_time: metrics.sum(&:tasks_on_time),
        overdue: metrics.sum(&:tasks_overdue),
        leads: metrics.sum(&:leads_assigned),
        fc30: metrics.sum(&:leads_first_contact_in_30m),
        won: metrics.sum(&:leads_converted),
        suspicious: metrics.sum(&:suspicious_completions)
      }
    end

    def rate(part, total)
      return 0 if total.zero?

      (part * 100.0 / total).round
    end

    def delta_pct(cur, prev)
      return '' if prev.zero?

      pct = ((cur - prev) * 100.0 / prev).round
      sign = pct.positive? ? '+' : ''
      "(#{sign}#{pct}%)"
    end
  end
end
