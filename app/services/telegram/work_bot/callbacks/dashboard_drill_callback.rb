# frozen_string_literal: true

module Telegram
  module WorkBot
    module Callbacks
      # Phase 15 — drill-down callback'и для /dashboard.
      #
      # callback_data префиксы:
      #   dashboard:drill:leads      — алиас: страница 1 списка лидов
      #   dashboard:drill:tasks      — детальный tasks
      #   dashboard:drill:staff      — алиас: страница 1 списка сотрудников
      #   dashboard:drill:search     — prompt: «что ищем»
      #   dashboard:leads:p:<page>   — страница списка лидов (issue #277)
      #   dashboard:staff:p:<page>   — страница списка сотрудников (issue #277)
      #   dashboard:staff:<id>[:<page>[:<action>]] — карточка сотрудника
      #     (issue #277, DashboardStaffCallback; <page> — страница списка
      #     для кнопки «Назад»)
      #   dashboard:lead:<id>        — карточка лида (issue #277)
      #   dashboard:lead:<id>:s<sid>:<spage> — карточка лида, открытая из
      #     карточки сотрудника (origin для «Назад», ревью #280)
      #   dashboard:lead:<id>[:s<sid>:<spage>]:del    — confirm удаления лида
      #   dashboard:lead:<id>[:s<sid>:<spage>]:del:yes — выполнить soft-delete
      #   dashboard:refresh          — пересчитать main dashboard
      #   dashboard:back             — обратно на main dashboard
      class DashboardDrillCallback < Base
        manager_only

        def handle
          subcmd = @args[0].to_s

          case subcmd
          when 'drill'    then handle_drill(@args[1].to_s)
          when 'leads'    then handle_list(:leads)
          when 'staff'    then handle_staff
          when 'lead'     then handle_lead_card
          when 'refresh'  then refresh_main
          when 'back'     then refresh_main
          else
            ack('⚠️ Неизвестный шаг.', alert: true)
          end
        end

        private

        # Карточка лида (issue #277): dashboard:lead:<id>[:s<sid>:<spage>][:del[:yes]].
        # Действия карточки (стадия/назначение/спам/редактирование) уходят в
        # существующие callback-механики — здесь только рендер и soft-delete.
        def handle_lead_card
          lead_id = @args[1].to_s
          return ack('⚠️ Неизвестный шаг.', alert: true) unless lead_id.match?(/\A\d+\z/)

          lead = LeadEvent.find_by(id: lead_id)
          return ack('⚠️ Лид не найден (возможно, удалён).', alert: true) unless lead
          # Центральный гейт Base#lead_event здесь не срабатывает (id в @args[1]),
          # поэтому staff_test-проверка продублирована явно (issue #214).
          return ack("🧪 Лид ##{lead.id} — тестовый (probe). Действие недоступно.", alert: true) if lead.staff_test?

          origin, action, subaction = parse_lead_route(@args[2..] || [])
          card = DashboardLeadCard.new(lead: lead, origin: origin)
          result = case action
                   when ''    then card.call
                   when 'del' then subaction == 'yes' ? card.perform_delete(actor: tg_user) : card.confirm_delete
                   else return ack('⚠️ Неизвестный шаг.', alert: true)
                   end
          edit(result.text, result.keyboard)
          ack
        end

        # Origin-сегмент s<staff_id>:<staff_page> — карточка открыта из
        # карточки сотрудника: «Назад» вернёт в неё, а не в список лидов
        # (ревью #280). Без сегмента — обычный путь из списка лидов.
        def parse_lead_route(rest)
          origin = nil
          if (m = rest[0].to_s.match(/\As(\d+)\z/))
            origin = { staff_id: m[1].to_i,
                       staff_page: DashboardPagination.normalize_page(rest[1]) }
            rest = rest[2..] || []
          end
          [origin, rest[0].to_s, rest[1].to_s]
        end

        def handle_drill(target)
          case target
          when 'leads'  then render_list(:leads, 1)
          when 'tasks'  then render_tasks_detail
          when 'staff'  then render_list(:staff, 1)
          when 'search' then render_search_prompt
          else
            ack('⚠️ Неизвестная секция.', alert: true)
          end
        end

        # Страничная навигация dashboard:<section>:p:<page>. Числовой id
        # (dashboard:staff:123) — карточка сотрудника (issue #277).
        def handle_list(section)
          parsed = DashboardPagination.parse_page(@args)
          return ack('⚠️ Неизвестный шаг.', alert: true) unless parsed

          render_list(section, parsed[1])
        end

        # dashboard:staff:p:<page> — список; dashboard:staff:<id>[...] —
        # карточка сотрудника (DashboardStaffCallback, issue #277).
        def handle_staff
          parsed = DashboardPagination.parse_page(@args)
          return render_list(:staff, parsed[1]) if parsed

          DashboardStaffCallback.new(callback_query: callback_query, tg_user: tg_user,
                                     args: @args[1..], client: client).call
        end

        def render_list(section, page)
          result = DashboardListPage.new(section: section, page: page).call
          edit(result.text, result.keyboard)
          ack
        end

        def refresh_main
          result = Telegram::WorkBot::DirectorDashboard.new(tg_user: tg_user, period: :today).call
          edit(result.markdown, result.keyboard)
          ack('🔄 Обновлено')
        end

        def render_tasks_detail
          lines = ['✅ <b>Задачи — детально</b>', '']

          overdue = ::Task.status_open.overdue.order(:due_at).limit(10).includes(:assignee)
          if overdue.any?
            lines << '<b>⚠️ Просроченные:</b>'
            overdue.each do |t|
              days = ((Time.current - t.due_at) / 1.day).round
              lines << "  • ##{t.id} #{t.title.to_s.truncate(50)} — #{t.assignee&.mention} (#{days} дн.)"
            end
          end

          due_today = ::Task.status_open.due_today.order(:due_at).limit(10).includes(:assignee)
          if due_today.any?
            lines << ''
            lines << '<b>📅 Со сроком сегодня:</b>'
            due_today.each do |t|
              lines << "  • ##{t.id} #{t.title.to_s.truncate(50)} — #{t.assignee&.mention}"
            end
          end

          edit(lines.join("\n"), back_keyboard)
          ack
        end

        def render_search_prompt
          text = "🔍 <b>Поиск</b>\n\n" \
                 "Просто напиши боту в DM что найти. Примеры:\n" \
                 "  • <i>«найди сообщения про Канищево за неделю»</i>\n" \
                 "  • <i>«какие задачи overdue у всех»</i>\n" \
                 "  • <i>«лиды на стадии показа»</i>\n" \
                 "  • <i>«покажи задания которые я давал в этом месяце»</i>\n\n" \
                 "Бот сам выберет нужный tool (search_group_messages / search_all_tasks / " \
                 "search_all_leads / director_self_audit / kpi_for)."
          edit(text, back_keyboard)
          ack
        end

        def edit(text, markup)
          chat_id = callback_query.dig('message', 'chat', 'id')
          message_id = callback_query.dig('message', 'message_id')
          return if chat_id.blank? || message_id.blank?

          client.edit_message_text(
            text,
            chat_id: chat_id,
            message_id: message_id,
            reply_markup: markup,
            parse_mode: 'HTML'
          )
        rescue ::Telegram::Client::Error => e
          Rails.logger.warn("[DashboardDrillCallback#edit] #{e.message}")
        end

        def back_keyboard
          {
            inline_keyboard: [[
              { text: '⬅️ Назад',  callback_data: 'dashboard:back' },
              { text: '🔄 Обновить', callback_data: 'dashboard:refresh' }
            ]]
          }
        end
      end
    end
  end
end
