# frozen_string_literal: true

module Telegram
  module WorkBot
    # Issue #277 — рендер карточки сотрудника (callback dashboard:staff:<id>).
    #
    # Режимы:
    #   :view           — метрики (DashboardStaffMetrics), открытые лиды
    #                     кнопками dashboard:lead:<id> (обработчик — соседняя
    #                     подзадача #277), открытые задачи текстом (своей
    #                     карточки у задач нет — task:<id> это action-callback).
    #   :edit           — admin-меню: роль / assignable / status.
    #   :role           — выбор роли (setrole применяет сразу).
    #   :status_confirm — подтверждение деактивации/активации.
    #
    # «Назад» — на страницу списка сотрудников, с которой пришли (from_page
    # из callback_data), через DashboardPagination — не в начало списка.
    # Edit-кнопки рисуются только admin-роли бота (role=admin); гейт на
    # само действие — в Callbacks::DashboardStaffCallback.
    #
    # Все пользовательские строки (имя, mention, email, заголовки задач)
    # экранируются — карточка рендерится с parse_mode HTML (ревью #280).
    class DashboardStaffCard
      Result = Struct.new(:text, :keyboard, keyword_init: true)

      ROLE_LABELS = { 'agent' => 'агент', 'manager' => 'руководитель',
                      'director' => 'директор', 'admin' => 'admin' }.freeze

      def initialize(staff:, admin_viewer:, from_page: 1, mode: :view)
        @staff = staff
        @admin_viewer = admin_viewer
        @from_page = DashboardPagination.normalize_page(from_page)
        @mode = mode.to_sym
        @metrics = DashboardStaffMetrics.new(staff)
      end

      def self.call(**)
        new(**).call
      end

      def call
        text, keyboard = send(:"render_#{@mode}")
        Result.new(text: text, keyboard: { inline_keyboard: keyboard })
      end

      private

      attr_reader :staff, :metrics, :from_page

      def cb(*segments)
        "dashboard:staff:#{staff.id}:#{from_page}#{segments.map { |s| ":#{s}" }.join}"
      end

      # === :view ===

      def render_view
        lines = [header, role_line, '']
        lines << "📧 #{escape(staff.email)}" if staff.email.present?
        lines << metrics_line
        lines << leads_line
        lines << sla_line
        lines.concat(task_lines)
        [lines.join("\n"), view_keyboard]
      end

      def header
        "👤 <b>#{escape(staff.display_name)} (#{escape(staff.mention)})</b>"
      end

      def role_line
        "Роль: <b>#{escape(ROLE_LABELS.fetch(staff.role, staff.role))}</b> · Статус: <b>#{escape(staff.status)}</b> · " \
          "В подборе: <b>#{staff.assignable ? 'да' : 'нет'}</b>"
      end

      def metrics_line
        "📋 <b>Задачи:</b> #{metrics.tasks_open} в работе · #{metrics.tasks_overdue} ⚠️ просрочено · " \
          "#{metrics.tasks_done_today} закрыто сегодня"
      end

      def leads_line
        line = "🎯 <b>Лиды:</b> #{metrics.leads_open} открытых · ждут 1-го контакта: #{metrics.leads_awaiting_fc}"
        overdue = metrics.leads_fc_overdue
        line += " (>30мин: #{overdue} ⚠️)" if overdue.positive?
        line
      end

      def sla_line
        total, in_sla = metrics.fc_week
        return '⏱ <b>SLA 1-го контакта (7д):</b> назначений не было' if total.zero?

        pct = (in_sla * 100.0 / total).round
        "⏱ <b>SLA 1-го контакта (7д):</b> #{in_sla}/#{total} ≤30мин (#{pct}%)"
      end

      def task_lines
        tasks = metrics.open_tasks
        return ['', '✅ <b>Открытые задачи:</b> нет'] if tasks.empty?

        lines = ['', "✅ <b>Открытые задачи (#{tasks.size}):</b>"]
        tasks.each { |t| lines << "  • ##{t.id} #{escape(t.title.to_s.truncate(45))} — #{due_label(t)}" }
        lines
      end

      def due_label(task)
        return 'без срока' if task.due_at.nil?

        days = ((Time.current - task.due_at) / 1.day).round
        return "⚠️ просрочена #{days} дн." if task.due_at < Time.current

        "срок #{task.due_at.strftime('%d.%m.%y')}"
      end

      def view_keyboard
        rows = metrics.open_leads.map { |le| [lead_button(le)] }
        rows << [{ text: '✏️ Редактировать', callback_data: cb('edit') }] if @admin_viewer
        rows << [
          { text: '⬅️ Назад', callback_data: DashboardPagination.staff_page_callback(from_page) },
          { text: '🔄 Обновить', callback_data: cb }
        ]
        rows
      end

      # Кнопка лида несёт origin (s<staff_id>:<page>) — «Назад» из карточки
      # лида вернёт в эту карточку сотрудника на ту же страницу списка,
      # а не в общий список лидов (ревью #280).
      def lead_button(lead)
        name = (lead.metadata || {})['name'].presence || "Лид ##{lead.id}"
        flag = lead.first_contact_at.nil? && lead.assigned_at.present? && lead.assigned_at < 30.minutes.ago ? ' ⚠️' : ''
        { text: "#{name} (##{lead.id}) — #{lead.current_stage}#{flag}".truncate(60),
          callback_data: "dashboard:lead:#{lead.id}:s#{staff.id}:#{from_page}" }
      end

      # === :edit ===

      def render_edit
        lines = [
          "✏️ <b>Редактирование: #{escape(staff.display_name)} (#{escape(staff.mention)})</b>",
          '',
          role_line,
          '',
          'Изменения применяются сразу кнопками ниже.'
        ]
        keyboard = [
          [{ text: "🔁 Роль: #{ROLE_LABELS.fetch(staff.role, staff.role)}", callback_data: cb('role') }],
          [{ text: toggle_label, callback_data: cb('assignable') }],
          [{ text: status_label, callback_data: cb('status') }],
          [{ text: '⬅️ К карточке', callback_data: cb }]
        ]
        [lines.join("\n"), keyboard]
      end

      def toggle_label
        staff.assignable ? '🚫 Убрать из подбора (assignable)' : '✅ Вернуть в подбор (assignable)'
      end

      def status_label
        staff.status == 'active' ? '⏸ Деактивировать' : '▶️ Активировать'
      end

      # === :role ===

      def render_role
        text = "🔁 <b>Роль сотрудника #{escape(staff.mention)}</b>\n\n" \
               "Текущая: <b>#{escape(ROLE_LABELS.fetch(staff.role, staff.role))}</b>. Выбор применяется сразу."
        rows = TelegramUser.roles.keys.each_slice(2).map do |pair|
          pair.map { |role| role_button(role) }
        end
        rows << [{ text: '⬅️ К редактированию', callback_data: cb('edit') }]
        [text, rows]
      end

      def role_button(role)
        mark = staff.role == role ? '• ' : ''
        { text: "#{mark}#{ROLE_LABELS.fetch(role, role)}", callback_data: cb('setrole', role) }
      end

      # === :status_confirm ===

      def render_status_confirm
        target = staff.status == 'active' ? 'inactive' : 'active'
        if staff.status == 'active'
          text = "⚠️ <b>Деактивировать #{escape(staff.mention)}?</b>\n\n" \
                 "Статус active → inactive, «в подборе» → нет. Открытые задачи/лиды останутся " \
                 "на нём — переназначение через /reassign."
        else
          text = "▶️ <b>Активировать #{escape(staff.mention)}?</b>\n\nСтатус #{escape(staff.status)} → active."
        end
        keyboard = [
          # Целевой статус зашит в callback: повторный тап по подтверждению
          # не переключит состояние обратно (ревью #280).
          [{ text: '⚠️ Подтверждаю', callback_data: cb('status_confirm', target) }],
          [{ text: '⬅️ Отмена', callback_data: cb('edit') }]
        ]
        [text, keyboard]
      end

      # Экранирование под parse_mode HTML — тот же приём, что в LeadAnnouncer
      # и DashboardLeadCard.
      def escape(text)
        text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
      end
    end
  end
end
