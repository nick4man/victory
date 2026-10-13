# frozen_string_literal: true

module Telegram
  module WorkBot
    module Callbacks
      # Кнопки пошаговых мастеров. Формат callback_data — см. Wizard::Engine.
      #   wiz:s:<flow>[:<id>] · wiz:p:<flow>:<step>:<idx> · wiz:m:<flow>:<step>
      #   wiz:b:<flow> · wiz:x · wiz:menu
      #
      # Права мастера проверяет Engine#start (manager_only → отказ до первого
      # вопроса), поэтому класс не объявляет manager_only: иначе агент с
      # кнопки «Закрыть» получил бы безликий алерт вместо объяснения.
      class WizardCallback < Base
        def handle
          action, *rest = @args
          case action
          when 's'    then start(rest[0], rest[1])
          when 'p'    then answer(engine.pick(rest[0], rest[1], rest[2]))
          when 'm'    then answer(engine.ask_manual(rest[0], rest[1]))
          when 'b'    then answer(engine.back(rest[0]))
          when 'x'    then answer(engine.cancel)
          when 'menu' then answer(engine.menu ? :ok : :dm_unavailable)
          else ack('⚠️ Неизвестное действие мастера', alert: true)
          end
        end

        private

        def engine
          @engine ||= Wizard::Engine.new(tg_user: tg_user, client: client)
        end

        def start(flow_key, seed_id)
          return ack('⚠️ Неизвестный мастер', alert: true) unless Wizard::Engine.flow_class(flow_key)

          seed = seed_id.present? ? { Wizard::Engine::SEED_STEP.fetch(flow_key) => seed_id } : {}
          case engine.start(flow_key, seed: seed)
          when :dm_unavailable
            ack('Не могу написать в личку. Открой чат с ботом, нажми «Start» и нажми кнопку ещё раз.', alert: true)
          else
            ack(in_private_chat? ? nil : '↘︎ Ответ — в личке с ботом')
          end
        end

        def answer(outcome)
          return ack('Этот шаг уже неактуален — мастер ушёл дальше, отменён или истёк.', alert: true) if outcome == :stale

          ack
        end

        def in_private_chat?
          callback_query.dig('message', 'chat', 'type') == 'private'
        end
      end
    end
  end
end
