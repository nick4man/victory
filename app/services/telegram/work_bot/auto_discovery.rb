# frozen_string_literal: true

module Telegram
  module WorkBot
    # Автоматическая регистрация новых сотрудников при первом сообщении
    # в рабочей TG-группе.
    #
    # Зачем: чтобы сотрудник появился в picker'е [👤 Назначить] — у него должна
    # быть запись в TelegramUser с `tg_user_id`. `tg_user_id` знает только
    # Telegram (приходит в webhook payload как `from.id` когда юзер пишет боту
    # или в группу где бот член). SMTP для /whoami email-кода не настроен →
    # этот flow невозможен. Решение — auto-discovery.
    #
    # Логика: любое сообщение от незарегистрированного юзера в рабочей группе
    # → создаём TelegramUser(status='inactive', is_manager=false) → шлём DM
    # всем активным manager-ам с предложением активировать через `/promote`.
    #
    # `status='inactive'` не появляется в `TelegramUser.active.where.not(...)`
    # фильтре AssignCallback'а — то есть в picker'е новый юзер пока невидим.
    # Manager сначала активирует, потом юзер виден.
    #
    # Race-safe: при concurrent webhook'ах от одного юзера ловим
    # `ActiveRecord::RecordNotUnique` и возвращаем `:exists`.
    class AutoDiscovery
      WORK_CHAT_ID = -1_003_779_115_845

      def initialize(message, client: Telegram::Client.new)
        @msg    = message.is_a?(Hash) ? message : {}
        @client = client
      end

      def call
        return :wrong_chat unless @msg.dig('chat', 'id') == WORK_CHAT_ID

        from = @msg['from'] || {}
        return :no_from if from.blank?
        return :bot     if from['is_bot']

        tg_user_id = from['id']
        return :no_tg_user_id if tg_user_id.blank?
        return :exists        if TelegramUser.exists?(tg_user_id: tg_user_id)

        tu = TelegramUser.create!(
          tg_user_id: tg_user_id,
          tg_username: from['username'],
          first_name: from['first_name'],
          last_name: from['last_name'],
          status: 'inactive',
          is_manager: false
        )
        Rails.logger.info("[AutoDiscovery] Created TelegramUser id=#{tu.id} #{tu.mention} (status=inactive)")

        notify_managers(tu)
        :registered
      rescue ActiveRecord::RecordNotUnique
        :exists
      rescue StandardError => e
        Rails.logger.error("[AutoDiscovery] #{e.class}: #{e.message}")
        :error
      end

      private

      def notify_managers(tu)
        managers = TelegramUser.managers.active
        return :no_managers if managers.empty?

        full_name = [tu.first_name, tu.last_name].compact.join(' ').presence
        username  = tu.tg_username.present? ? "@#{tu.tg_username}" : "tg_id=#{tu.tg_user_id}"

        text = "👤 <b>Новый кандидат для регистрации</b> в work-bot АН\n  " \
               "• #{escape(username)}#{" (#{escape(full_name)})" if full_name}\n  " \
               "• tg_id: <code>#{tu.tg_user_id}</code>\n\n" \
               "Активировать (даст возможность принимать назначения):\n" \
               "<code>/promote #{tu.tg_username || tu.tg_user_id}</code>\n\n" \
               "Если нужен manager-уровень:\n" \
               "<code>/promote #{tu.tg_username || tu.tg_user_id} manager</code>"

        managers.find_each do |mgr|
          chat_id = mgr.dm_chat_id || mgr.tg_user_id
          next if chat_id.blank?

          begin
            @client.send_message(text, chat_id: chat_id, parse_mode: 'HTML')
          rescue Telegram::Client::Error => e
            Rails.logger.warn("[AutoDiscovery] DM to #{mgr.mention} failed: #{e.message}")
          end
        end
      end

      def escape(text)
        text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
      end
    end
  end
end
