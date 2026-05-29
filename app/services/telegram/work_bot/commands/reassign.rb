# frozen_string_literal: true

module Telegram
  module WorkBot
    module Commands
      # Phase 11 Iter 23 — `/reassign <task_id> @new_assignee` — manager-only
      # передача активной задачи другому сотруднику.
      #
      # Зачем: до этого фикса перенос задачи требовал ручного UPDATE через
      # rails console + ручной DM обоим сторонам — fragile + invisible audit.
      # Теперь — atomic transaction + DM прежнему (что лид у него забрали) +
      # DM новому (что ему пришла задача). Refresh digest учитывает изменение.
      #
      # Гарантии:
      #   • Manager-only (audit-критично — нельзя дать агенту перебрасывать
      #     свои задачи коллегам без manager-санкции)
      #   • Не-открытая задача (done/canceled) → reject — переоткрытие через /reopen (Iter 24)
      #   • Self-reassign (тот же assignee) → no-op + friendly reply
      #   • Новый assignee должен быть active + assignable
      #   • notified_at сбрасывается (новый assignee должен получить fresh DM)
      #   • first_acked_at/started_at сохраняются (audit-trail прошлой работы)
      #
      # Пример: `/reassign 142 @oksana_director`
      class Reassign < Base
        manager_only

        def handle
          parts = args.split(/\s+/, 2)
          task_id = parts[0].to_i
          username = parts[1].to_s.strip

          if task_id.zero? || username.blank?
            return reply('Формат: <code>/reassign 42 @username</code> — где 42 это task_id, ' \
                         '@username — новый ответственный (active + assignable).')
          end

          task = ::Task.find_by(id: task_id)
          return reply("⚠️ Задача ##{task_id} не найдена.") if task.nil?

          unless task.status_open?
            return reply("⚠️ Задача ##{task.id} в статусе <b>#{task.status}</b> — " \
                         'переоткрой через <code>/reopen ' + task.id.to_s + '</code> (Iter 24).')
          end

          new_assignee = TelegramUser.find_by_username(username)
          return reply("⚠️ Сотрудник <code>#{escape_html(username)}</code> не найден.") if new_assignee.nil?

          unless new_assignee.status_active? && new_assignee.assignable?
            return reply("🚫 #{new_assignee.mention} не доступен для назначения " \
                         "(status=#{new_assignee.status}, assignable=#{new_assignee.assignable}).")
          end

          prev_assignee = task.assignee
          if prev_assignee && prev_assignee.id == new_assignee.id
            return reply("ℹ️ Задача ##{task.id} уже назначена на #{new_assignee.mention}.")
          end

          # Phase 12 Iter 34 — capture stale TG-card coordinates ПЕРЕД update.
          # После update notified_at сбрасывается, но нам нужен старый
          # tg_message_id чтобы инвалидировать кнопки в DM-карточке прежнего.
          stale_card = { chat_id: prev_assignee&.dm_chat_id || prev_assignee&.tg_user_id, message_id: task.tg_message_id }

          ::Task.transaction do
            task.assign_attributes(
              assignee: new_assignee,
              assigned_at: Time.current,
              notified_at: nil, # новый DM-цикл — fresh notification
              tg_message_id: nil # новый dispatch получит свежий message_id
            )
            task.save!
          end

          invalidate_stale_card(stale_card, new_assignee) if stale_card[:message_id].present?
          dispatch_new_card(task) # full DM-карта с inline-кнопками [▶][✅] для new assignee
          notify_previous_assignee(task, prev_assignee, new_assignee) if prev_assignee

          prev_mention = prev_assignee&.mention || '<i>никого</i>'
          reply("🔄 Задача ##{task.id} передана: #{prev_mention} → #{new_assignee.mention}")
        end

        private

        # Phase 12 Iter 34 — отправляем full DM-card (с inline-кнопками) через
        # TaskDispatcher. До этого фикса /reassign слал plain DM без кнопок,
        # новый assignee мог /done только через команду — UX неравенство
        # с обычным dispatch.
        def dispatch_new_card(task)
          Telegram::WorkBot::TaskDispatcher.new(tasks: [task.reload], client: @client).call
        rescue StandardError => e
          Rails.logger.warn("[Reassign#dispatch_new_card] #{e.class}: #{e.message}")
        end

        # Phase 12 Iter 34 — инвалидируем старую DM-карточку прежнего assignee.
        # Кнопки [▶][✅] в ней по-прежнему живые: callback приходит,
        # TaskActionCallback#authorized? отсеивает (assignee_id != tg_user.id),
        # юзер видит «🚫 Это не твоя задача» toast — confusing UX. Убираем кнопки
        # через editMessageReplyMarkup. Текст не трогаем (multiline, с history) —
        # явный notice о передаче идёт отдельным DM через notify_previous_assignee.
        def invalidate_stale_card(coords, _new_assignee)
          return if coords[:chat_id].blank? || coords[:message_id].blank?

          @client.edit_message_reply_markup(
            chat_id: coords[:chat_id],
            message_id: coords[:message_id],
            reply_markup: { inline_keyboard: [] }
          )
        rescue Telegram::Client::Error => e
          Rails.logger.warn("[Reassign#invalidate_stale_card] #{e.message}")
        end

        def notify_previous_assignee(task, prev_assignee, new_assignee)
          text = "🔄 <b>Задача передана</b> ##{task.id}\n" \
                 "📋 #{escape_html(task.title)}\n" \
                 "Новый ответственный: #{new_assignee.mention}\n" \
                 "Передал: #{@tg_user.mention}"
          dm(text, to: prev_assignee)
        end
      end
    end
  end
end
