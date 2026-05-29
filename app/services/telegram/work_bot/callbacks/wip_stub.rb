# frozen_string_literal: true

module Telegram
  module WorkBot
    module Callbacks
      # Заглушка для Phase 2 шаг 3 — проверяет что цикл webhook → CallbacksRouter
      # → answer_callback_query замкнулся. Будет заменена реальными обработчиками
      # в шагах 4-9 (RouteCallback, AssignCallback, AssignToCallback, SpamCallback).
      class WipStub < Base
        def handle
          prefix = callback_query['data'].to_s.split(':').first
          ack("⏳ #{prefix.upcase} — WIP (Phase 2 в работе)", alert: false)
          Rails.logger.info("[WipStub] data=#{callback_query['data']} from=#{actor_mention}")
          :wip
        end
      end
    end
  end
end
