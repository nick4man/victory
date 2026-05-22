# frozen_string_literal: true

module Telegram
  module WorkBot
    # Phase 15 — генератор consolidated snapshot для /dashboard команды
    # в DM директора. Markdown + inline-keyboard для drilldown.
    #
    # Структура (4 секции + alerts + LLM cost):
    #   • Лиды (open/closed_won/closed_lost/overdue_first_contact)
    #   • Задачи (open/overdue/due_today/done_today)
    #   • Сотрудники (per-staff cards: open/done/overdue)
    #   • KPI неделя (conversion / sla / time-to-first-contact)
    #   • Алерты 24ч (SLA breach, manager_pinged)
    #   • LLM cost (optional)
    #
    # Inline-keyboard: [🎯 Лиды] [✅ Задачи] [👥 Сотрудники] [🔍 Поиск]
    # Каждая кнопка → DashboardDrillCallback → edit_message_text с details.
    class DirectorDashboard
      Result = Struct.new(:markdown, :keyboard, keyword_init: true)

      def initialize(tg_user:, period: :today)
        @tg_user = tg_user
        @period  = period.to_sym
      end

      def self.call(**)
        new(**).call
      end

      def call
        Result.new(markdown: build_markdown, keyboard: build_keyboard)
      end

      private

      def build_markdown
        sections = [
          header,
          leads_section,
          tasks_section,
          staff_section,
          weekly_kpi_section,
          alerts_section
        ]
        sections.compact.join("\n\n")
      end

      def header
        "📊 <b>Дашборд АН Виктори · #{Time.current.strftime('%d.%m.%y %H:%M')} MSK</b>"
      end

      def leads_section
        open_scope = LeadEvent.open
        new_count = LeadEvent.where(current_stage: 'new').count
        awaiting_fc = LeadEvent.awaiting_first_contact.count

        # Закрытые за 7 дней
        closed_recent = LeadEvent.closed.where(updated_at: 7.days.ago.beginning_of_day..Time.current)
        won = closed_recent.where(current_stage: 'closed_won').count
        lost = closed_recent.where(current_stage: 'closed_lost').count

        # Overdue first contact (assigned_at + 30 min < now, first_contact_at nil)
        overdue_fc = LeadEvent.awaiting_first_contact
                              .where('assigned_at < ?', 30.minutes.ago).count

        lines = ['🎯 <b>Лиды</b>']
        lines << "  • Открытых: <b>#{open_scope.count}</b> (новых: #{new_count}, ждут первого контакта: #{awaiting_fc})"
        lines << "  • Закрыто за 7 дней: <b>#{won + lost}</b> (выиграно #{won} / проиграно #{lost})"
        lines << "  • Без первого контакта дольше 30 мин: <b>#{overdue_fc}</b> ⚠️" if overdue_fc.positive?
        lines.join("\n")
      end

      def tasks_section
        open_scope = ::Task.status_open
        overdue = open_scope.overdue.count
        due_today = open_scope.due_today.count
        done_today = ::Task.status_done.where(updated_at: Time.current.all_day).count

        # SLA breach — open + due_at < 3 days ago
        sla_breach = open_scope.where('due_at < ?', 3.days.ago).count

        lines = ['✅ <b>Задачи</b>']
        lines << "  • Открытых: <b>#{open_scope.count}</b> (просрочено #{overdue}, со сроком сегодня #{due_today})"
        lines << "  • Завершено сегодня: <b>#{done_today}</b>"
        lines << "  • Просрочено больше 3 дней: <b>#{sla_breach}</b> ⚠️" if sla_breach.positive?
        lines.join("\n")
      end

      def staff_section
        active_staff = TelegramUser.assignable.where.not(role: %w[admin]).order(:first_name, :id)
        return nil if active_staff.empty?

        lines = ["👥 <b>Сотрудники (#{active_staff.size} active)</b>"]

        active_staff.find_each do |s|
          open = ::Task.where(assignee_id: s.id, status: 'open').count
          done_today = ::Task.where(assignee_id: s.id, status: 'done', updated_at: Time.current.all_day).count
          overdue = ::Task.where(assignee_id: s.id, status: 'open').where('due_at < ?', Time.current).count

          status_icon = overdue.zero? ? '✅' : '⚠️'
          lines << "  • #{s.mention}: #{open} в работе, #{done_today} закрыто сегодня, #{overdue} просрочено #{status_icon}"
        end

        lines.join("\n")
      end

      def weekly_kpi_section
        range_now = 7.days.ago.beginning_of_day..Time.current
        range_prev = 14.days.ago.beginning_of_day..7.days.ago.end_of_day

        now = compute_kpi(range_now)
        prev = compute_kpi(range_prev)

        return nil if now[:leads_total].zero? && now[:tasks_total].zero?

        lines = ['📈 <b>Показатели за неделю</b>']
        lines << "  • Конверсия (выигранных от закрытых): <b>#{now[:conversion]}%</b> (неделю назад #{prev[:conversion]}% #{trend(now[:conversion], prev[:conversion])})"
        lines << "  • Задач выполнено в срок: <b>#{now[:on_time]}%</b> (неделю назад #{prev[:on_time]}% #{trend(now[:on_time], prev[:on_time])})"
        lines.join("\n")
      end

      def compute_kpi(range)
        leads = LeadEvent.where(updated_at: range)
        leads_closed = leads.closed
        won = leads_closed.where(current_stage: 'closed_won').count
        total_closed = leads_closed.count
        conversion = total_closed.positive? ? (won * 100.0 / total_closed).round : 0

        tasks_done = ::Task.where(status: 'done', updated_at: range)
        tasks_on_time = tasks_done.where('due_at IS NULL OR updated_at <= due_at').count
        on_time = tasks_done.count.positive? ? (tasks_on_time * 100.0 / tasks_done.count).round : 0

        {
          leads_total: leads.count,
          tasks_total: tasks_done.count,
          conversion: conversion,
          on_time: on_time
        }
      end

      def trend(now, prev)
        diff = now - prev
        return '→' if diff.zero?
        return '↑' if diff.positive?

        '↓'
      end

      def alerts_section
        # Лиды с manager_pinged (escalation_count > 0) за 24ч
        alerts = LeadEvent.open
                          .where('metadata::text ILIKE ?', '%"manager_pinged"%')
                          .where(updated_at: 24.hours.ago..Time.current)
                          .limit(5)

        # Tasks SLA breach
        sla_tasks = ::Task.status_open.where('due_at < ?', 3.days.ago).limit(3)

        return nil if alerts.empty? && sla_tasks.empty?

        lines = ['🔔 <b>Уведомления за сутки</b>']
        alerts.each do |le|
          name = (le.metadata['name'].presence) || "Лид ##{le.id}"
          lines << "  • #{name} (##{le.id}) — руководитель уведомлён повторно"
        end
        sla_tasks.each do |t|
          days = ((Time.current - t.due_at) / 1.day).round
          lines << "  • Задача ##{t.id} (#{t.title.to_s.truncate(40)}) — просрочка #{days} дн."
        end
        lines.join("\n")
      end

      def build_keyboard
        {
          inline_keyboard: [
            [
              { text: '🎯 Лиды',       callback_data: 'dashboard:drill:leads' },
              { text: '✅ Задачи',      callback_data: 'dashboard:drill:tasks' }
            ],
            [
              { text: '👥 Сотрудники',  callback_data: 'dashboard:drill:staff' },
              { text: '🔍 Поиск',       callback_data: 'dashboard:drill:search' }
            ],
            [
              { text: '🔄 Обновить',    callback_data: 'dashboard:refresh' }
            ]
          ]
        }
      end
    end
  end
end
