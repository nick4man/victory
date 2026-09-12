# frozen_string_literal: true

module Telegram
  module WorkBot
    module Callbacks
      # BOTTLENECK — кнопки превью отчёта о показе и карточки «собственнику».
      # callback_data: "show_report:<id>:approve|cancel|toggle_conductor|owner_push|owner_sent".
      #
      # Не manager_only: отчёт подтверждает тот, кто его надиктовал.
      class ShowReportCallback < Base
        def handle
          report = ShowReport.find_by(id: @args[0])
          return ack('⚠️ Отчёт не найден', alert: true) if report.nil?
          return ack('🚫 Это не твой отчёт', alert: true) unless authorized?(report)

          case @args[1].to_s
          when 'approve'          then approve(report)
          when 'cancel'           then cancel(report)
          when 'toggle_conductor' then toggle_conductor(report)
          when 'owner_push'       then owner_push(report)
          when 'owner_sent'       then owner_sent(report)
          else ack('⚠️ Неизвестное действие', alert: true)
          end
        end

        private

        def authorized?(report)
          return false if tg_user.nil?

          report.reported_by_id == tg_user.id || tg_user.manager_or_director?
        end

        def approve(report)
          status = ShowReports::Finalizer.new(report: report, actor: tg_user, client: client).call
          return ack("ℹ️ Уже #{report.reload.status}", alert: true) if status == :already_done

          edit_preview(report, "\n\n✅ <b>Сохранено.</b> Задача собственнику ##{report.reload.feedback_task_id}.")
          ack('✅ Показ сохранён')
        end

        def cancel(report)
          return ack("ℹ️ Уже #{report.status}", alert: true) unless report.status_pending_confirm?

          report.cancel!
          edit_preview(report, "\n\n✖️ <b>Отменено</b>")
          ack('✖️ Отменено')
        end

        def toggle_conductor(report)
          return ack("ℹ️ Уже #{report.status} — показывающего не сменить", alert: true) unless report.status_pending_confirm?

          report.toggle_conductor!(reporter: report.reported_by, director: TelegramUser.directors.active.first)
          confirmer = ShowReports::Confirmer.new(report: report, client: client)
          client.edit_message_text(confirmer.preview_text, chat_id: report.preview_chat_id, message_id: report.preview_message_id,
                                                           parse_mode: 'HTML', reply_markup: confirmer.keyboard)
          ack("Показывал(а): #{report.conducted_by.display_name}")
        rescue Telegram::Client::Error => e
          raise unless e.message.match?(/not modified/i)

          ack('Без изменений')
        end

        def owner_push(report)
          return ack('ℹ️ Собственник уже уведомлён', alert: true) if report.owner_notified_at.present?

          owner = report.property&.owner_user
          return ack('⚠️ У собственника нет Telegram — отправь сам', alert: true) if owner&.tg_user_id.blank?

          # BOTTLENECK — собственнику не шлём в тихие часы. Показы вечерние,
          # отчёт часто в 21:30, а регламент требует обратную связь «день в день
          # до 11:00» — то есть утром. Кнопка остаётся активной, задача с due_at
          # 11:00 уже стоит (см. #approve), состояние не теряется: сотруднику
          # просто говорят, когда нажимать. Авто-отправки по таймеру здесь нет
          # намеренно — правило «собственнику ничего без кнопки» сильнее удобства.
          if Telegram::WorkBot::QuietHours.active?
            return ack(
              '🌙 Тихие часы — собственнику отправим утром. Нажми эту же кнопку после ' \
              "#{Formatters::DateFormat.fmt_dt(Telegram::WorkBot::QuietHours.next_window_start)}",
              alert: true
            )
          end

          result = Telegram::PushToClient.send(user: owner, message: report.owner_message.to_s)
          return ack("⚠️ Не доставлено: #{result.error.to_s.truncate(80)}", alert: true) unless result.success?

          mark_owner_notified(report, 'tg')
          ack('📤 Отправлено собственнику')
        end

        def owner_sent(report)
          return ack('ℹ️ Уже отмечено', alert: true) if report.owner_notified_at.present?

          mark_owner_notified(report, 'manual')
          ack('✅ Задача закрыта')
        end

        def mark_owner_notified(report, via)
          report.update!(owner_notified_at: Time.current, owner_notified_via: via)
          ::Task.find_by(id: report.feedback_task_id)&.mark_completed!(acked_method: 'button')
          strike_owner_card("\n\n✅ <b>Собственник уведомлён</b> #{Formatters::DateFormat.fmt_dt(report.owner_notified_at)}")
        end

        def edit_preview(report, suffix)
          return if report.preview_message_id.blank?

          original = callback_query.dig('message', 'text').to_s
          client.edit_message_text("#{original}#{suffix}", chat_id: report.preview_chat_id, message_id: report.preview_message_id,
                                                           parse_mode: 'HTML', reply_markup: { inline_keyboard: [] })
        rescue Telegram::Client::Error => e
          Rails.logger.warn("[ShowReportCallback#edit_preview] #{e.message}")
        end

        # Карточка с черновиком — то сообщение, под которым нажали кнопку.
        def strike_owner_card(suffix)
          msg = callback_query['message']
          return if msg.blank?

          client.edit_message_text("#{msg['text']}#{suffix}", chat_id: msg.dig('chat', 'id'), message_id: msg['message_id'],
                                                              parse_mode: 'HTML', reply_markup: { inline_keyboard: [] })
        rescue Telegram::Client::Error => e
          Rails.logger.warn("[ShowReportCallback#strike_owner_card] #{e.message}")
        end
      end
    end
  end
end
