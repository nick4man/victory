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
      #   dashboard:refresh          — пересчитать main dashboard
      #   dashboard:back             — обратно на main dashboard
      #
      # dashboard:lead:<id> / dashboard:staff:<id> — карточки сущностей
      # (соседние подзадачи issue #277, сюда добавят свои ветки).
      class DashboardDrillCallback < Base
        manager_only

        def handle
          subcmd = @args[0].to_s

          case subcmd
          when 'drill'    then handle_drill(@args[1].to_s)
          when 'leads'    then handle_list(:leads)
          when 'staff'    then handle_list(:staff)
          when 'refresh'  then refresh_main
          when 'back'     then refresh_main
          else
            ack('⚠️ Неизвестный шаг.', alert: true)
          end
        end

        private

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
        # (dashboard:staff:123) — карточка сотрудника из подзадачи #277.
        def handle_list(section)
          parsed = DashboardPagination.parse_page(@args)
          return ack('⚠️ Неизвестный шаг.', alert: true) unless parsed

          render_list(section, parsed[1])
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
