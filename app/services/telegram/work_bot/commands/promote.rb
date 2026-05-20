# frozen_string_literal: true

module Telegram
  module WorkBot
    module Commands
      # `/promote @username [manager]` — manager-only активация TelegramUser.
      #
      # Используется в паре с AutoDiscovery: сотрудник пишет в рабочую группу,
      # AutoDiscovery создаёт TelegramUser(status='inactive'), уведомляет
      # manager-а в DM. Manager пишет `/promote @username` → юзер активируется
      # → появляется в picker'е [👤 Назначить] / доступен через /assign.
      #
      # Опциональный второй аргумент `manager` повышает is_manager=true сразу.
      class Promote < Base
        manager_only

        def handle
          parts  = args.to_s.split(/\s+/)
          target = parts[0]
          role   = parts[1]&.downcase
          return reply('Формат: <code>/promote @username [manager]</code>') if target.blank?

          # rubocop:disable Rails/DynamicFindBy -- наш custom class method, не Rails dynamic finder
          tu = TelegramUser.find_by_username(target)
          # rubocop:enable Rails/DynamicFindBy
          unless tu
            return reply("⚠️ #{escape(target.sub(/\A@/, ''))} не найден в TelegramUser. " \
                         'Возможно ещё не писал в рабочую группу — auto-discovery срабатывает на первом сообщении.')
          end

          changes = {}
          changes[:status]     = 'active' if tu.status != 'active'
          # Phase 12 Iter 31 — синхронизируем role enum с is_manager.
          # До этого фикса: /promote @user manager → is_manager=true, но role='agent'.
          # Phase 11 cascade (CriticalRecipients) использует role enum — skew → user
          # учитывается как manager в legacy scope, но не как manager в role-based.
          if role == 'manager' && !tu.is_manager?
            changes[:is_manager] = true
            changes[:role] = 'manager' if tu.role == 'agent' # не понижаем director/admin
          end

          if changes.empty?
            current_label = tu.is_manager? ? 'manager' : 'active agent'
            return reply("ℹ️ #{tu.mention} уже <b>#{current_label}</b> (role=<code>#{tu.role}</code>).")
          end

          tu.update!(changes)

          # Iter 58 — реактивный refresh native TG /-меню в DM этого юзера.
          # Soft-fail: sync issue не должна ломать promote flow.
          begin
            Telegram::WorkBot::CommandsMenuSync.new.sync_for_user!(tu.reload)
          rescue StandardError => e
            Rails.logger.warn("[CommandsMenuSync] /promote sync skip for tg_user=#{tu.id}: #{e.class} #{e.message}")
          end

          role_msg = changes[:is_manager] ? ' и повышен до <b>manager</b>' : ''
          reply("✅ #{tu.mention} активирован#{role_msg} (role=<code>#{tu.reload.role}</code>). " \
                'Доступен для [👤 Назначить] и <code>/assign</code>.')
        end

        private

        def escape(text)
          text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
        end
      end
    end
  end
end
