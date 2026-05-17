# frozen_string_literal: true

module Kpi
  # Phase 7.6 — Evening DM Оксане с agency-wide summary за сегодня.
  # Использует latest StaffMetric snapshots + live agency-aggregated данные.
  #
  # @example
  #   Kpi::AgencyDigest.new(date: Date.current).build_text
  class AgencyDigest
    def initialize(date: Date.current)
      @date = date
      @range = date.all_day
    end

    def build_text
      metrics = StaffMetric.for_date(@date).to_a
      lines = []
      lines << "📊 <b>Сводка АН — #{@date.strftime('%d.%m.%y')}</b>"
      lines << ''
      lines << agency_totals(metrics)
      lines << ''
      lines << per_staff_table(metrics)
      lines << ''
      lines << pipeline_block
      lines << ''
      lines << highlights(metrics)
      lines.join("\n")
    end

    private

    def agency_totals(metrics)
      assigned  = metrics.sum(&:tasks_assigned)
      completed = metrics.sum(&:tasks_completed)
      on_time   = metrics.sum(&:tasks_on_time)
      overdue   = metrics.sum(&:tasks_overdue)
      questions = metrics.sum(&:questions_asked)
      leads_in  = metrics.sum(&:leads_assigned)
      conv_30m  = metrics.sum(&:leads_first_contact_in_30m)
      suspicious = metrics.sum(&:suspicious_completions)

      pct_30m = leads_in.positive? ? (conv_30m.to_f * 100 / leads_in).round : 0
      on_time_pct = completed.positive? ? (on_time.to_f * 100 / completed).round : 0

      parts = []
      parts << "🎯 Задачи: <b>#{completed}/#{assigned}</b> закрыто (on-time #{on_time_pct}%)"
      parts << "⚠️ Просрочки: <b>#{overdue}</b>" if overdue.positive?
      parts << "🆕 Новых лидов: <b>#{leads_in}</b> (first-contact ≤30 мин: <b>#{pct_30m}%</b>)" if leads_in.positive?
      parts << "❓ Вопросов в #ВОПРОС/ОТВЕТ: <b>#{questions}</b>"
      parts << "🤔 Suspicious closes: <b>#{suspicious}</b> — нужна выборка" if suspicious.positive?
      parts.join("\n")
    end

    def per_staff_table(metrics)
      return '<i>Сегодня без активности.</i>' if metrics.empty?

      ordered = metrics.sort_by { |m| -(m.tasks_completed + m.leads_assigned) }
      lines = ['<b>👥 По сотрудникам:</b>']
      ordered.each do |m|
        next if m.tasks_assigned.zero? && m.leads_assigned.zero? && m.questions_asked.zero?

        lines << format_staff_line(m)
      end
      lines.size == 1 ? '<i>Сотрудники без активности.</i>' : lines.join("\n")
    end

    def format_staff_line(metric)
      mention = metric.staff.mention
      done_str = "#{metric.tasks_completed}/#{metric.tasks_assigned}" if metric.tasks_assigned.positive?
      leads_str = "📞 #{metric.leads_assigned} лид(ов)" if metric.leads_assigned.positive?
      questions_str = "❓ #{metric.questions_asked} вопрос(ов)" if metric.questions_asked.positive?
      suspicious_str = "🤔 #{metric.suspicious_completions}" if metric.suspicious_completions.positive?

      parts = ["  · #{mention}"]
      parts << done_str if done_str
      parts << leads_str if leads_str
      parts << questions_str if questions_str
      parts << suspicious_str if suspicious_str
      parts.join(' · ')
    end

    def pipeline_block
      open_total = LeadEvent.where.not(current_stage: ['closed_won', 'closed_lost']).count
      won_today  = LeadEvent.where(closed_at: @range, current_stage: 'closed_won').count
      lost_today = LeadEvent.where(closed_at: @range, current_stage: 'closed_lost').count

      parts = ['<b>📈 Pipeline:</b>']
      parts << "  · В работе: <b>#{open_total}</b>"
      parts << "  · Закрыто сегодня: <b>#{won_today}</b> ✅ / <b>#{lost_today}</b> ❌"
      parts.join("\n")
    end

    def highlights(metrics)
      return '' if metrics.empty?

      top = metrics.max_by(&:tasks_completed)
      return '' if top.nil? || top.tasks_completed.zero?

      "🏆 <b>Top performer:</b> #{top.staff.mention} (#{top.tasks_completed} задач)"
    end
  end
end
