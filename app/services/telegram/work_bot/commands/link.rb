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

          # Без аргументов показываем кнопочный экран вместо подсказки формата.
          # Текстовыми командами в этом боте не пользуются — из 24 команд за всё
          # время вызывались 9, и ни одна из них не набиралась руками. Экран
          # LinkStaffCallback связывает telegram-аккаунт с учёткой CRM
          # (users.telegram_user_id), от которой зависит вся адресная рассылка;
          # без точки входа он был бы недостижим.
          return show_link_screen if username.blank? && email.blank?

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

          # Iter 58 — если /link одновременно повышает до manager, refresh
          # native TG-меню в DM этого юзера. Soft-fail.
          if !was_manager && role == 'manager'
            begin
              Telegram::WorkBot::CommandsMenuSync.new.sync_for_user!(tu.reload)
            rescue StandardError => e
              Rails.logger.warn("[CommandsMenuSync] /link sync skip for tg_user=#{tu.id}: #{e.class} #{e.message}")
            end
          end

          role_msg  = !was_manager && role == 'manager' ? ' и повышен до <b>manager</b>' : ''
          crm_name  = [crm_user['firstname'], crm_user['lastname']].compact_blank.join(' ').presence
          crm_label = crm_name ? "#{crm_name} (Topnlab id=#{crm_user['id']})" : "Topnlab id=#{crm_user['id']}"

          reply("✅ #{tu.mention} связан с CRM: <b>#{escape(crm_label)}</b>#{role_msg}. " \
                'Теперь <code>/assign</code> будет переводить лиды на этого сотрудника в Topnlab.')
        end

        private

        # Кнопочный вход в связывание сотрудник ↔ телеграм. Сами кнопки
        # обрабатывает Callbacks::LinkStaffCallback.
        def show_link_screen
          client.send_message(
            "<b>Связка сотрудников с Telegram</b>\n\n" \
            'От этой связи зависит, дойдут ли до сотрудника уведомления по его объектам.',
            chat_id: message.dig('chat', 'id'),
            message_thread_id: message['message_thread_id'],
            parse_mode: 'HTML',
            reply_markup: { inline_keyboard: [
              [{ text: '🔗 Связать аккаунт с учёткой', callback_data: 'link_staff:list' }],
              [{ text: '🔎 Кому бот не сможет написать', callback_data: 'link_staff:report' }]
            ] }
          )
        end

        def escape(text)
          text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
        end
      end
    end
  end
end
