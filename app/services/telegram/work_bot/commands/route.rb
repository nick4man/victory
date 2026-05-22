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
          # Phase 15 — resolve_lead! сначала «съест» lead_id если он есть в @args.
          lead = resolve_lead!
          return reply(lead_not_found_hint('route apartments')) unless lead

          target_key = @args.to_s.strip.downcase
          return reply("Формат: <code>/route apartments</code> (reply) ИЛИ <code>/route &lt;lead_id&gt; apartments</code> (DM). " \
                       "Доступно: #{Telegram::TopicRegistry.routing_buttons.join(', ')}") if target_key.blank?

          unless Telegram::TopicRegistry.valid_key?(target_key)
            return reply("⚠️ Неизвестный топик: <code>#{target_key}</code>")
          end

          migrated = Telegram::WorkBot::AnchorMigrator.new(lead, target_key, actor: tg_user, client: client).call
          if migrated
            title = Telegram::TopicRegistry.title(target_key)
            reply("Лид ##{lead.id} → ##{title} ✅")
          else
            reply('⚠️ Маршрутизация пропущена (см. логи).')
          end
        end
      end
    end
  end
end
