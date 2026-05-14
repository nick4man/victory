# frozen_string_literal: true

module Telegram
  module WorkBot
    module Commands
      # Текстовый аналог inline-кнопки маршрутизации.
      # Используется когда руководителю удобнее писать `/route apartments` в reply
      # на якорную карточку, чем кликать кнопку (например, с мобильного, когда
      # клавиатура уже открыта).
      #
      # Формат: `/route <topic_key>` (например, `/route apartments`).
      # Аргумент должен быть из TopicRegistry.routing_buttons.
      class Route < Base
        manager_only

        def handle
          target_key = args.strip.downcase
          return reply("Формат: <code>/route apartments</code>. Доступно: #{Telegram::TopicRegistry.routing_buttons.join(', ')}") if target_key.blank?

          unless Telegram::TopicRegistry.valid_key?(target_key)
            return reply("⚠️ Неизвестный топик: <code>#{target_key}</code>")
          end

          lead = find_lead_via_reply
          return reply('⚠️ Команда должна быть reply на якорную карточку лида.') unless lead

          migrated = Telegram::WorkBot::AnchorMigrator.new(lead, target_key, actor: tg_user, client: client).call
          if migrated
            title = Telegram::TopicRegistry.title(target_key)
            reply("→ ##{title} ✅")
          else
            reply('⚠️ Маршрутизация пропущена (см. логи).')
          end
        end

        private

        def find_lead_via_reply
          reply_to = message['reply_to_message']
          return nil unless reply_to

          LeadEvent.find_by(anchor_message_id: reply_to['message_id'])
        end
      end
    end
  end
end
