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

          ::Task.transaction do
            task.assign_attributes(
              assignee: new_assignee,
              assigned_at: Time.current,
              notified_at: nil # новый DM-цикл — fresh notification
            )
            task.save!
          end

          notify_new_assignee(task, new_assignee, prev_assignee)
          notify_previous_assignee(task, prev_assignee, new_assignee) if prev_assignee

          prev_mention = prev_assignee&.mention || '<i>никого</i>'
          reply("🔄 Задача ##{task.id} передана: #{prev_mention} → #{new_assignee.mention}")
        end

        private

        def notify_new_assignee(task, new_assignee, prev_assignee)
          due_str = task.due_at ? "до #{task.due_at.strftime('%d.%m.%y %H:%M')}" : 'без срока'
          prev_str = prev_assignee ? " (была у #{prev_assignee.mention})" : ''
          text = "🆕 <b>Тебе передана задача</b> ##{task.id}#{prev_str}\n" \
                 "📋 #{escape_html(task.title)}\n" \
                 "⏰ #{due_str}\n" \
                 "Передал: #{@tg_user.mention}"
          dm(text, to: new_assignee)
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
