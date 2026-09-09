# frozen_string_literal: true

module Telegram
  module WorkBot
    module Callbacks
      # Кнопки карточки обучения: `tutorial:go:<index>` и `tutorial:finish`.
      #
      # Ролевых макросов здесь намеренно НЕТ. `manager_only` в Callbacks::Base
      # проверяет `is_manager?`, а не `manager_or_director?` — директор с
      # role='director', is_manager=false был бы отрезан от собственных кнопок.
      # Фильтрация идёт пер-урок в TutorialLessons.visible_for, тем же набором
      # предикатов, что и на стороне команды.
      class TutorialCallback < Base
        def handle
          return ack('Открой обучение в личке: /tutorial', alert: true) unless private_chat?

          case args.first
          when 'go' then render(renderer.call(index: args[1].to_i))
          when 'finish' then render(renderer.finish, ack_text: '✅ Обучение пройдено')
          else ack('Неизвестный шаг обучения', alert: true)
          end
        end

        private

        def renderer
          @renderer ||= Telegram::WorkBot::TutorialRenderer.new(tg_user: tg_user)
        end

        def render(result, ack_text: nil)
          client.edit_message_text(
            result.markdown,
            chat_id: chat_id,
            message_id: message_id,
            parse_mode: 'HTML',
            reply_markup: result.keyboard
          )
          ack(ack_text)
        rescue Telegram::Client::Error => e
          # Повторное нажатие того же шага — Telegram отвечает «message is not
          # modified». Слать на это новую карточку значило бы засорять личку
          # на каждый дабл-тап.
          return ack(ack_text) if e.message.match?(/not modified/i)

          # Карточку нажали спустя дни: editMessageText уже недоступен. Оставлять
          # человека с мёртвой кнопкой не годится — открываем свежую карточку.
          Rails.logger.warn("[Callbacks::TutorialCallback] edit failed: #{e.message}")
          client.send_message(
            result.markdown,
            chat_id: chat_id,
            parse_mode: 'HTML',
            reply_markup: result.keyboard
          )
          ack('Открыл свежую карточку')
        end

        def private_chat?
          callback_query.dig('message', 'chat', 'type') == 'private'
        end

        def chat_id
          callback_query.dig('message', 'chat', 'id')
        end

        def message_id
          callback_query.dig('message', 'message_id')
        end
      end
    end
  end
end
