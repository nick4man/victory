# frozen_string_literal: true

module Telegram
  module WorkBot
    module Commands
      # Phase 11 Iter 27 — `/deactivate @user` — graceful offboarding сотрудника
      # (уволился / в отпуске / временно недоступен).
      #
      # Зачем: до этого фикса offboarding требовал rails console + ручной audit
      # открытых задач/лидов. Иначе:
      #   • Открытые задачи остаются на inactive — assignee не видит DM, SLA-watchdog
      #     спамит (Iter 21 фикс снизил, но всё равно остаются «приклеенные» лиды)
      #   • Лиды остаются назначенными — manager не понимает что они «бесхозные»
      #   • KPI snapshot включает inactive в average → искажает метрики
      #
      # Fix: manager-only /deactivate сначала показывает diagnosis (что повиснет),
      # требует /deactivate @user confirm для apply. Apply:
      #   • TelegramUser.status='inactive', assignable=false
      #   • Открытые задачи — assignee_id остаётся, но Rails.logger.info с list
      #     (manager должен перенаправить /reassign — НЕ автоматически, чтобы
      #     не сломать context)
      #   • Открытые лиды — assigned_to остаётся, но flag в logger
      #   • DM offboardируемому: «Тебя деактивировали. Манагер: @{mgr_name}»
      #   • DM other managers: «@{user} деактивирован, открыто N задач + M лидов»
      #
      # Контракт «summary first» — `/deactivate @user` без confirm = diagnosis.
      class Deactivate < Base
        manager_only

        def handle
          parts = args.split(/\s+/, 2)
          username = parts[0].to_s.strip
          flag = parts[1].to_s.strip.downcase

          if username.blank?
            return reply('Формат: <code>/deactivate @username</code> (diagnosis) или ' \
                         '<code>/deactivate @username confirm</code> (apply).')
          end

          target = TelegramUser.find_by_username(username)
          return reply("⚠️ Сотрудник <code>#{escape_html(username)}</code> не найден.") if target.nil?

          if target.id == tg_user.id
            return reply('🚫 Нельзя деактивировать себя. Попроси другого manager.')
          end

          if target.status != 'active'
            return reply("ℹ️ #{target.mention} уже не active (status=<b>#{target.status}</b>).")
          end

          open_tasks = ::Task.status_open.where(assignee_id: target.id)
          open_leads = LeadEvent.where(assigned_to_id: target.id, closed_at: nil)

          if flag != 'confirm'
            return reply(diagnosis_text(target, open_tasks, open_leads))
          end

          apply_deactivation!(target, open_tasks, open_leads)
        end

        private

        def diagnosis_text(target, open_tasks, open_leads)
          lines = ["🔍 <b>Diagnosis: #{target.mention}</b>"]
          lines << "Status: <b>active</b> → станет <b>inactive</b>"
          lines << "Assignable: <b>#{target.assignable}</b> → станет <b>false</b>"
          lines << "Открытых задач: <b>#{open_tasks.count}</b>"
          lines << "Активных лидов: <b>#{open_leads.count}</b>"
          if open_tasks.any? || open_leads.any?
            lines << ''
            lines << '<i>После деактивации — задачи/лиды останутся на нём, но без DM-нотификаций.</i>'
            lines << '<i>Рекомендация: перенаправь через /reassign перед confirm.</i>'
          end
          lines << ''
          lines << "Подтверди: <code>/deactivate #{target.mention} confirm</code>"
          lines.join("\n")
        end

        def apply_deactivation!(target, open_tasks, open_leads)
          TelegramUser.transaction do
            target.update!(status: 'inactive', assignable: false)
          end

          Rails.logger.info(
            "[Deactivate] #{target.mention} deactivated by #{tg_user.mention} — " \
            "open_tasks=#{open_tasks.pluck(:id).inspect} open_leads=#{open_leads.pluck(:id).inspect}"
          )

          notify_target(target)
          notify_other_managers(target, open_tasks.count, open_leads.count)

          summary = "🔒 <b>#{target.mention} деактивирован</b>\n" \
                    "  • открытых задач: #{open_tasks.count}\n" \
                    "  • активных лидов: #{open_leads.count}\n"
          if open_tasks.any?
            summary += "\nПерекинь задачи через /reassign:\n"
            summary += open_tasks.limit(5).map { |t| "  • <code>/reassign #{t.id} @username</code>" }.join("\n")
            summary += "\n  …" if open_tasks.count > 5
          end
          reply(summary)
        end

        def notify_target(target)
          text = "🔒 <b>Аккаунт деактивирован</b>\n" \
                 "Тебя деактивировал #{tg_user.mention} #{Time.current.strftime('%d.%m.%y %H:%M')}.\n\n" \
                 "Ты больше не получаешь DM по новым задачам/лидам. " \
                 "Если это ошибка — свяжись с #{tg_user.mention}."
          dm(text, to: target)
        end

        def notify_other_managers(target, task_count, lead_count)
          other_managers = TelegramUser.managers.where(status: 'active').where.not(id: tg_user.id)
          text = "🔒 <b>Offboarding alert</b>\n" \
                 "Деактивирован: #{target.mention}\n" \
                 "Источник: #{tg_user.mention}\n" \
                 "Незакрытых: задач=<b>#{task_count}</b>, лидов=<b>#{lead_count}</b>"

          other_managers.each do |mgr|
            chat_id = mgr.dm_chat_id || mgr.tg_user_id
            next if chat_id.blank?

            client.send_message(text, chat_id: chat_id, parse_mode: 'HTML')
          rescue Telegram::Client::Error => e
            Rails.logger.warn("[Deactivate] DM to #{mgr.mention}: #{e.message}")
          end
        end
      end
    end
  end
end
