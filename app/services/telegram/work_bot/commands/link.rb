# frozen_string_literal: true

module Telegram
  module WorkBot
    module Commands
      # `/link @username email@victory.ru [manager]` — manager-only маппинг
      # TelegramUser ↔ CRM-staff. Используется в паре с auto-discovery + /promote:
      #
      #   1. Сотрудник пишет в рабочую группу → AutoDiscovery создаёт TelegramUser(inactive)
      #   2. Manager: `/promote @username` → status='active'
      #   3. Manager: `/link @username email@victory.ru` → topnlab_user_id + email
      #   4. После этого `/assign @username` реально дёргает Topnlab transfer_client
      #
      # Опциональный третий аргумент `manager` повышает is_manager (если ещё не).
      class Link < Base
        manager_only

        def handle
          parts = args.to_s.split(/\s+/)
          username = parts[0]
          email    = parts[1]
          role     = parts[2]&.downcase

          if username.blank? || email.blank?
            return reply('Формат: <code>/link @username email@victory.ru [manager]</code>')
          end

          # rubocop:disable Rails/DynamicFindBy -- custom class method, не Rails dynamic finder
          tu = TelegramUser.find_by_username(username)
          # rubocop:enable Rails/DynamicFindBy
          unless tu
            return reply("⚠️ #{escape(username.sub(/\A@/, ''))} не зарегистрирован в боте. " \
                         'Попроси сотрудника написать одно сообщение в рабочую группу — auto-discovery создаст запись.')
          end

          crm_user = Staff::Resolver.new.find_by(email: email)
          unless crm_user
            return reply("⚠️ Email <code>#{escape(email)}</code> не найден в CRM (Topnlab getUsers). " \
                         'Проверь регистр и точное написание (учётка должна быть заведена в Topnlab Admin).')
          end

          was_manager = tu.is_manager?
          new_attrs = {
            topnlab_user_id: crm_user['id'],
            email: email.downcase.strip,
            is_manager: was_manager || role == 'manager'
          }
          # Phase 12 Iter 31 — синхронизируем role enum с is_manager.
          # Если повышаем до manager и role был 'agent' — поднимаем role.
          # director/admin не понижаем (более высокий уровень).
          if role == 'manager' && !was_manager && tu.role == 'agent'
            new_attrs[:role] = 'manager'
          end

          begin
            tu.update!(new_attrs)
          rescue ActiveRecord::RecordNotUnique
            return reply("⚠️ Topnlab id=#{crm_user['id']} уже привязан к другому TelegramUser. " \
                         'Разлинкуй существующего через rails console: ' \
                         "<code>TelegramUser.find_by(topnlab_user_id: #{crm_user['id']}).update!(topnlab_user_id: nil)</code>")
          end

          role_msg  = !was_manager && role == 'manager' ? ' и повышен до <b>manager</b>' : ''
          crm_name  = [crm_user['firstname'], crm_user['lastname']].compact_blank.join(' ').presence
          crm_label = crm_name ? "#{crm_name} (Topnlab id=#{crm_user['id']})" : "Topnlab id=#{crm_user['id']}"

          reply("✅ #{tu.mention} связан с CRM: <b>#{escape(crm_label)}</b>#{role_msg}. " \
                'Теперь <code>/assign</code> будет переводить лиды на этого сотрудника в Topnlab.')
        end

        private

        def escape(text)
          text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
        end
      end
    end
  end
end
