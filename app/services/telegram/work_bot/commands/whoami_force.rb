# frozen_string_literal: true

module Telegram
  module WorkBot
    module Commands
      # `/whoami_force email@example.com` — manager-only регистрация сотрудника
      # БЕЗ проверки в Topnlab. Нужно когда:
      #   • новый агент пока не заведён в Topnlab CRM
      #   • email в CRM в другом регистре, обычный /whoami не находит
      #   • срочная регистрация в случае проблем с Topnlab API
      #
      # Создаёт TelegramUser напрямую, ставит is_manager: false (обычный агент;
      # повышать до manager — отдельно через rails console / `/promote @user`).
      # Без `topnlab_user_id` — последующий /assign не сможет двигать CRM-stage,
      # но локальная карточка и якорь работают.
      class WhoamiForce < Base
        manager_only

        def handle
          if args.blank?
            return reply(
              'Формат: <code>/whoami_force email@example.com</code> в DM сотрудника к боту.\n' \
              'Сотрудник должен сам написать эту команду — её надо запустить с его аккаунта, ' \
              'либо использовать вариант через rails console (см. документацию).'
            )
          end

          email = args.strip.downcase
          unless email.match?(URI::MailTo::EMAIL_REGEXP)
            return reply("⚠️ Не похоже на email: <code>#{escape(email)}</code>")
          end

          from = message['from'] || {}
          tg_user_id = from['id']
          return reply('⚠️ Не удалось определить ваш tg_user_id') if tg_user_id.blank?

          tu = TelegramUser.find_or_initialize_by(tg_user_id: tg_user_id)
          tu.assign_attributes(
            tg_username: from['username'],
            email: email,
            first_name: from['first_name'] || tu.first_name,
            last_name: from['last_name'] || tu.last_name,
            dm_chat_id: message.dig('chat', 'id') || tg_user_id,
            status: 'active'
          )
          tu.save!

          log_audit('force_registered', "#{email} tg=#{tg_user_id}")

          reply(
            "✅ Зарегистрирован: <b>#{escape(tu.display_name)}</b> (#{escape(email)}).\n" \
            '⚠️ Без привязки к Topnlab — CRM-операции пропускаются. Чтобы подключить CRM, ' \
            "выполните <code>/whoami #{escape(email)}</code> после заведения в Topnlab."
          )
        end

        private

        def log_audit(result, args_text)
          BotCommandLog.create!(
            tg_user_id: message.dig('from', 'id'),
            command: '/whoami_force',
            args: args_text.to_s,
            result: result
          )
        rescue StandardError => e
          Rails.logger.warn("[WhoamiForce#log_audit] #{e.class}: #{e.message}")
        end

        def escape(text)
          text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
        end
      end
    end
  end
end
