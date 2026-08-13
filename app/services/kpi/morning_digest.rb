# frozen_string_literal: true

module Kpi
  # Phase 6 — Per-staff morning digest, DM'ed daily 08:00 MSK.
  # Personal "что у меня сегодня": tasks due today, overdue, open leads,
  # vчерашний progress (completed count), SLA warnings (lead assignments
  # > 30 min без first_contact).
  #
  # Принципы:
  #   • Per-staff personalized (StaffMetric для yesterday + live queries для today)
  #   • Concise: ≤ 12 lines (mobile-friendly)
  #   • Actionable: каждый block ends с command hint (где применимо)
  #
  # @example
  #   text = Kpi::MorningDigest.new(staff: tg_user).build_text
  class MorningDigest
    def initialize(staff:, now: Time.current)
      @staff = staff
      @now = now
      @today_range = now.beginning_of_day..now.end_of_day
      @yesterday = (now - 1.day).to_date
    end

    def build_text
      lines = []
      lines << greeting
      lines << ''
      lines << overdue_block if overdue_tasks.any?
      lines << due_today_block
      lines << open_leads_block
      lines << sla_warnings_block if sla_warnings.any?
      lines << ''
      lines << yesterday_recap
      lines.compact.join("\n")
    end

    # === Block builders ===

    def greeting
      name = @staff.first_name.presence || @staff.tg_username.presence || 'коллега'
      "🌅 <b>С добрым утром, #{escape(name)}!</b>"
    end

    def overdue_block
      lines = ["⚠️ <b>Просрочки (#{overdue_tasks.size})</b>:"]
      overdue_tasks.first(5).each do |t|
        due = t.due_at.strftime('%d.%m')
        lines << "  • <code>##{t.id}</code> #{escape(t.title.to_s.truncate(60))} (до #{due})"
      end
      lines << "  …+#{overdue_tasks.size - 5}" if overdue_tasks.size > 5
      lines << '<i>Закрыть: <code>/done &lt;id&gt;</code></i>'
      lines.join("\n")
    end

    def due_today_block
      lines = []
      if due_today_tasks.any?
        lines << "📅 <b>Сегодня (#{due_today_tasks.size}):</b>"
        due_today_tasks.first(8).each do |t|
          time = t.due_at.strftime('%H:%M')
          kind_icon = kind_emoji(t.kind)
          lines << "  • #{kind_icon} <code>##{t.id}</code> #{escape(t.title.to_s.truncate(60))} (#{time})"
        end
        lines << "  …+#{due_today_tasks.size - 8}" if due_today_tasks.size > 8
      else
        lines << '📅 <i>На сегодня задач нет.</i>'
      end
      lines.join("\n")
    end

    def open_leads_block
      cnt = open_leads.size
      return '🎯 <i>Активных лидов нет.</i>' if cnt.zero?

      lines = ["🎯 <b>Активных лидов: #{cnt}</b>"]
      stages = open_leads.group_by(&:current_stage).transform_values(&:count)
      stages_str = stages.map { |s, c| "#{stage_emoji(s)} #{c}" }.join(' / ')
      lines << "  Стадии: #{stages_str}"
      lines.join("\n")
    end

    def sla_warnings_block
      lines = ["⏰ <b>SLA-warnings: #{sla_warnings.size}</b>"]
      sla_warnings.first(3).each do |lead|
        name = (lead.metadata || {})['name'] || 'клиент'
        # @now, а не Time.current: остальной дайджест считается от переданного
        # времени, и смешивать две точки отсчёта в одном тексте нельзя.
        mins = ((@now - lead.assigned_at) / 60).to_i
        lines << "  • <a href=\"#{lead.anchor_url}\">#{escape(name.to_s.truncate(30))}</a> — #{mins} мин без first_contact"
      end
      lines.join("\n")
    end

    def yesterday_recap
      sm = ::StaffMetric.for_date(@yesterday).for_staff(@staff).first
      return '<i>📊 Вчера: данных пока нет.</i>' if sm.nil?

      done = sm.tasks_completed
      assigned = sm.tasks_assigned
      ot = sm.tasks_on_time
      "📊 <i>Вчера: выполнено #{done}/#{assigned} задач" +
        (ot.positive? ? ", on-time #{((ot * 100.0 / done).round)}%" : '') + '</i>'
    end

    # === Data accessors ===

    def overdue_tasks
      @overdue_tasks ||= ::Task.status_open
                               .where(assignee_id: @staff.id)
                               .where('due_at < ?', @now)
                               .order(:due_at)
                               .to_a
    end

    def due_today_tasks
      @due_today_tasks ||= ::Task.status_open
                                 .where(assignee_id: @staff.id)
                                 .where(due_at: @today_range)
                                 .order(:due_at)
                                 .to_a
    end

    def open_leads
      @open_leads ||= ::LeadEvent.where(assigned_to_id: @staff.id)
                                 .where(closed_at: nil)
                                 .to_a
    end

    def sla_warnings
      @sla_warnings ||= open_leads.select do |le|
        le.assigned_at.present? && le.first_contact_at.nil? &&
          le.assigned_at < (@now - 30.minutes)
      end
    end

    # === Visual helpers ===

    def kind_emoji(kind)
      { 'call' => '📞', 'show' => '🏠', 'document' => '📄', 'admin' => '⚙️', 'other' => '📌' }[kind.to_s] || '📌'
    end

    def stage_emoji(stage)
      { 'new' => '🆕', 'first_contact' => '📞', 'show' => '🏠',
        'contract' => '📄', 'deal' => '🤝', 'closed_won' => '✅',
        'closed_lost' => '❌' }[stage.to_s] || '•'
    end

    def escape(text)
      text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
    end
  end
end
