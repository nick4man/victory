# frozen_string_literal: true

module Telegram
  module WorkBot
    module Callbacks
      # Обработчик нажатия кнопки маршрутизации (КВАРТИРЫ / ДОМА / … / ОЦЕНКА)
      # под якорной карточкой лида в #ДИСПЕТЧЕРСКОЙ.
      #
      # callback_data формат: "route:<lead_event_id>:<topic_key>"
      # args = [lead_event_id, topic_key]
      class RouteCallback < Base
        manager_only

        def handle
          target_key = @args[1].to_s
          unless Telegram::TopicRegistry.valid_key?(target_key)
            return ack("Неизвестный топик: #{target_key}", alert: true)
          end

          migrated = AnchorMigrator.new(lead_event, target_key, actor: tg_user, client: client).call
          if migrated
            title = Telegram::TopicRegistry.title(target_key)
            ack("→ ##{title} ✅")
          else
            ack('Маршрутизация пропущена (см. логи)', alert: true)
          end
        end
      end
    end
  end
end
