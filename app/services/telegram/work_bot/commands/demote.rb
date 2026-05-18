# frozen_string_literal: true

module Telegram
  module WorkBot
    module Commands
      # Phase 12 Iter 32 — `/demote @user` — manager-only revoke is_manager.
      #
      # Зачем: до этого фикса понижение manager → agent требовало rails console.
      # Если manager-сотрудник переводится в другую роль (или сокращается до
      # field-agent), его привилегии остаются — может выполнять manager_only
      # команды (/assign, /lead, /promote, /demote, /reassign).
      #
      # Fix: manager-only /demote @user:
      #   • is_manager → false
      #   • role 'manager' → 'agent' (director/admin не трогаем)
      #   • Status остаётся active — это НЕ deactivate (Iter 27)
      #   • DM понижаемому: 'Тебя понизили до agent. Manager: @who'
      #   • DM other managers: audit-trail
      #   • Self-demote reject — нужен другой manager
      #   • Director/admin demote reject — выше уровень, требует console
      class Demote < Base
        manager_only

        def handle
          username = args.split(/\s+/).first.to_s.strip
          return reply('Формат: <code>/demote @username</code>') if username.blank?

          target = TelegramUser.find_by_username(username)
          return reply("⚠️ Сотрудник <code>#{escape_html(username)}</code> не найден.") if target.nil?

          if target.id == tg_user.id
            return reply('🚫 Нельзя понижать себя. Попроси другого manager.')
          end

          if %w[director admin].include?(target.role)
            return reply("🚫 #{target.mention} имеет role=<b>#{target.role}</b> — " \
                         'через бота не понижаем. Используй rails console.')
          end

          unless target.is_manager? || target.role == 'manager'
            return reply("ℹ️ #{target.mention} и так не manager " \
                         "(is_manager=<b>#{target.is_manager}</b>, role=<b>#{target.role}</b>).")
          end

          new_attrs = { is_manager: false }
          new_attrs[:role] = 'agent' if target.role == 'manager'

          TelegramUser.transaction do
            target.update!(new_attrs)
          end

          Rails.logger.info(
            "[Demote] #{target.mention} demoted by #{tg_user.mention} (is_manager → false, role → #{target.role})"
          )

          notify_target(target)
          notify_other_managers(target)

          reply("⬇️ #{target.mention} понижен → <code>role=#{target.reload.role}</code>, " \
                "<code>is_manager=#{target.is_manager}</code>.")
        end

        private

        def notify_target(target)
          text = "⬇️ <b>Тебя понизили до agent</b>\n" \
                 "Manager-привилегии больше не доступны.\n" \
                 "Источник: #{tg_user.mention} в #{Time.current.strftime('%d.%m.%y %H:%M')}.\n\n" \
                 "Если это ошибка — свяжись с #{tg_user.mention}."
          dm(text, to: target)
        end

        def notify_other_managers(target)
          others = TelegramUser.managers.where(status: 'active').where.not(id: tg_user.id)
          text = "⬇️ <b>Demote alert</b>\n" \
                 "Понижен: #{target.mention} → role=<b>#{target.reload.role}</b>\n" \
                 "Источник: #{tg_user.mention}"

          others.each do |mgr|
            chat_id = mgr.dm_chat_id || mgr.tg_user_id
            next if chat_id.blank?

            client.send_message(text, chat_id: chat_id, parse_mode: 'HTML')
          rescue Telegram::Client::Error => e
            Rails.logger.warn("[Demote] DM to #{mgr.mention}: #{e.message}")
          end
        end
      end
    end
  end
end
