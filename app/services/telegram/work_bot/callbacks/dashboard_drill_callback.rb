# frozen_string_literal: true

module Telegram
  module WorkBot
    module Callbacks
      # Phase 15 — drill-down callback'и для /dashboard.
      #
      # callback_data префиксы:
      #   dashboard:drill:leads   — детальный leads breakdown
      #   dashboard:drill:tasks   — детальный tasks
      #   dashboard:drill:staff   — per-staff cards
      #   dashboard:drill:search  — prompt: «что ищем»
      #   dashboard:refresh       — пересчитать main dashboard
      #   dashboard:back          — обратно на main dashboard
      class DashboardDrillCallback < Base
        manager_only

        def handle
          subcmd = @args[0].to_s
          target = @args[1].to_s

          case subcmd
          when 'drill'    then handle_drill(target)
          when 'refresh'  then refresh_main
          when 'back'     then refresh_main
          else
            ack('⚠️ Неизвестный шаг.', alert: true)
          end
        end

        private

        def handle_drill(target)
          case target
          when 'leads'  then render_leads_detail
          when 'tasks'  then render_tasks_detail
          when 'staff'  then render_staff_detail
          when 'search' then render_search_prompt
          else
            ack('⚠️ Неизвестная секция.', alert: true)
          end
        end

        def refresh_main
          result = Telegram::WorkBot::DirectorDashboard.new(tg_user: tg_user, period: :today).call
          edit(result.markdown, result.keyboard)
          ack('🔄 Обновлено')
        end

        def render_leads_detail
          lines = ['🎯 <b>Лиды — детально</b>', '']

          # Top-5 hot (high-priority topics + recent activity)
          hot = LeadEvent.open.order(updated_at: :desc).limit(5).includes(:assigned_to)
          if hot.any?
            lines << '<b>Топ-5 активных:</b>'
            hot.each do |le|
              name = (le.metadata || {})['name'].presence || "Лид ##{le.id}"
              lines << "  • #{name} (##{le.id}) — #{le.current_stage} → #{le.assigned_to&.mention || '<i>не назначен</i>'}"
            end
          end

          # Overdue first contact
          overdue = LeadEvent.awaiting_first_contact.where('assigned_at < ?', 30.minutes.ago).limit(5)
          if overdue.any?
            lines << ''
            lines << '<b>⚠️ Overdue first contact:</b>'
            overdue.each do |le|
              lines << "  • Лид ##{le.id} — #{le.assigned_to&.mention} (#{time_ago(le.assigned_at)})"
            end
          end

          edit(lines.join("\n"), back_keyboard)
          ack
        end

        def render_tasks_detail
          lines = ['✅ <b>Задачи — детально</b>', '']

          overdue = ::Task.status_open.overdue.order(:due_at).limit(10).includes(:assignee)
          if overdue.any?
            lines << '<b>⚠️ Overdue:</b>'
            overdue.each do |t|
              days = ((Time.current - t.due_at) / 1.day).round
              lines << "  • ##{t.id} #{t.title.to_s.truncate(50)} — #{t.assignee&.mention} (#{days}d)"
            end
          end

          due_today = ::Task.status_open.due_today.order(:due_at).limit(10).includes(:assignee)
          if due_today.any?
            lines << ''
            lines << '<b>📅 Due today:</b>'
            due_today.each do |t|
              lines << "  • ##{t.id} #{t.title.to_s.truncate(50)} — #{t.assignee&.mention}"
            end
          end

          edit(lines.join("\n"), back_keyboard)
          ack
        end

        def render_staff_detail
          lines = ['👥 <b>Сотрудники — детально</b>', '']

          staff = TelegramUser.assignable.where.not(role: 'admin').order(:first_name, :id)
          staff.each do |s|
            open = ::Task.where(assignee_id: s.id, status: 'open').count
            done_today = ::Task.where(assignee_id: s.id, status: 'done', updated_at: Time.current.all_day).count
            overdue = ::Task.where(assignee_id: s.id, status: 'open').where('due_at < ?', Time.current).count
            leads_open = LeadEvent.where(assigned_to_id: s.id).open.count

            lines << "<b>#{s.mention}</b> (#{s.role})"
            lines << "  • Задач: #{open} откр. / #{done_today} done сегодня / #{overdue} overdue"
            lines << "  • Лидов открытых: #{leads_open}"
            lines << ''
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
end
