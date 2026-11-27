# frozen_string_literal: true

module Telegram
  module WorkBot
    # Issue #277 — постраничный рендер drill-down списков дашборда
    # («Лиды — детально», «Сотрудники — детально»).
    #
    # Заменяет жёсткие limit(5/10) в DashboardDrillCallback: список листается
    # кнопками ◀️ ▶️, номер страницы закодирован в callback_data
    # (DashboardPagination). Строки списка — inline-кнопки: тап по лиду или
    # сотруднику открывает карточку (dashboard:lead:<id> / dashboard:staff:<id>,
    # обработчики — соседние подзадачи #277).
    #
    # Сортировка детерминирована (updated_at desc + id tiebreaker у лидов,
    # first_name + id у сотрудников): повторный тап по странице рендерит
    # идентичный список, выборка не «плывёт».
    class DashboardListPage
      Result = Struct.new(:text, :keyboard, keyword_init: true)

      def initialize(section:, page: 1)
        @section = section.to_sym
        @page = DashboardPagination.normalize_page(page)
      end

      def self.call(**)
        new(**).call
      end

      def call
        total_count = count
        total = [(total_count / DashboardPagination::PAGE_SIZE.to_f).ceil, 1].max
        page = @page.clamp(1, total)

        @section == :leads ? leads_result(page, total, total_count) : staff_result(page, total, total_count)
      end

      private

      def count
        @section == :leads ? leads_scope.count : staff_scope.count
      end

      # === Лиды ===

      # .real — без staff_test/probe-записей (issue #214). id — tiebreaker
      # для детерминированной пагинации при одинаковом updated_at.
      def leads_scope
        LeadEvent.open.real.order(updated_at: :desc, id: :desc)
      end

      def leads_result(page, total, total_count)
        leads = leads_scope.offset((page - 1) * DashboardPagination::PAGE_SIZE)
                           .limit(DashboardPagination::PAGE_SIZE)
                           .includes(:assigned_to)
        Result.new(
          text: leads_text(page, total, total_count),
          keyboard: { inline_keyboard: lead_rows(leads) + footer(:leads, page, total) }
        )
      end

      def leads_text(page, total, total_count)
        lines = [
          '🎯 <b>Лиды — детально</b>',
          '',
          "Открытых лидов: <b>#{total_count}</b> · страница #{page}/#{total}",
          'Тап по лиду ниже — карточка с действиями.'
        ]
        lines.concat(overdue_lines)
        lines.join("\n")
      end

      # Alert-блок без пагинации: как в прежней сводке — не более 5.
      def overdue_lines
        overdue = LeadEvent.real.awaiting_first_contact
                           .where('assigned_at < ?', 30.minutes.ago)
                           .order(:assigned_at, :id)
                           .limit(5)
        return [] if overdue.empty?

        lines = ['', '<b>⚠️ Ждут первого контакта (более 30 мин):</b>']
        overdue.each do |le|
          lines << "  • Лид ##{le.id} — #{le.assigned_to&.mention} (#{time_ago(le.assigned_at)})"
        end
        lines
      end

      def lead_rows(leads)
        leads.map do |le|
          name = (le.metadata || {})['name'].presence || "Лид ##{le.id}"
          assignee = le.assigned_to&.mention || 'не назначен'
          label = "#{name} (##{le.id}) — #{le.current_stage} → #{assignee}"
          [{ text: label.truncate(60), callback_data: "dashboard:lead:#{le.id}" }]
        end
      end

      # === Сотрудники ===

      def staff_scope
        TelegramUser.assignable.where.not(role: %w[admin]).order(:first_name, :id)
      end

      def staff_result(page, total, total_count)
        staff = staff_scope.offset((page - 1) * DashboardPagination::PAGE_SIZE)
                           .limit(DashboardPagination::PAGE_SIZE)
        metrics = staff_metrics(staff.map(&:id))
        Result.new(
          text: staff_text(page, total, total_count),
          keyboard: { inline_keyboard: staff_rows(staff, metrics) + footer(:staff, page, total) }
        )
      end

      def staff_text(page, total, total_count)
        [
          '👥 <b>Сотрудники — детально</b>',
          '',
          "Активных сотрудников: <b>#{total_count}</b> · страница #{page}/#{total}",
          'Тап по сотруднику ниже — карточка с метриками.'
        ].join("\n")
      end

      # Групповые count'ы одним запросом на метрику — без N+1 по странице.
      def staff_metrics(ids)
        {
          open: ::Task.where(assignee_id: ids, status: 'open').group(:assignee_id).count,
          done: ::Task.where(assignee_id: ids, status: 'done', updated_at: Time.current.all_day).group(:assignee_id).count,
          overdue: ::Task.where(assignee_id: ids, status: 'open').where('due_at < ?', Time.current).group(:assignee_id).count,
          leads: LeadEvent.real.open.where(assigned_to_id: ids).group(:assigned_to_id).count
        }
      end

      def staff_rows(staff, metrics)
        staff.map do |s|
          label = "#{s.mention} · #{metrics[:open][s.id] || 0} в работе / " \
                  "#{metrics[:done][s.id] || 0} сегодня / #{metrics[:overdue][s.id] || 0} ⚠️ · " \
                  "лидов #{metrics[:leads][s.id] || 0}"
          [{ text: label.truncate(60), callback_data: "dashboard:staff:#{s.id}" }]
        end
      end

      # === Общее ===

      def footer(section, page, total)
        [DashboardPagination.nav_row(section, page, total), back_row(section, page)]
      end

      def back_row(section, page)
        [
          { text: '⬅️ Назад', callback_data: 'dashboard:back' },
          { text: '🔄 Обновить', callback_data: DashboardPagination.page_callback(section, page) }
        ]
      end

      def time_ago(time)
        return 'unknown' if time.nil?

        diff_sec = (Time.current - time).to_i
        return "#{diff_sec / 60}мин" if diff_sec < 3600
        return "#{diff_sec / 3600}ч" if diff_sec < 86_400

        "#{diff_sec / 86_400}д"
      end
    end
  end
end
