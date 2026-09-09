# frozen_string_literal: true

module Telegram
  module WorkBot
    module Commands
      # `/tutorial` — интерактивное обучение сотрудника работе с ботом.
      #
      # Открывает первый доступный по роли урок карточкой с inline-кнопками;
      # дальше листает Callbacks::TutorialCallback, перерисовывая ЭТО ЖЕ
      # сообщение. Состояние не хранится (см. TutorialRenderer).
      #
      # Не public_command: обучение описывает внутренние процессы АН (лиды,
      # распределение, KPI), клиенту оно не адресовано. Незарегистрированного
      # отсечёт гейт в Commands::Base.
      #
      # В группе карточку не показываем: её кнопки нажмёт кто угодно, а урок
      # адресный. Уходит в личку, в группу — одна строка.
      class Tutorial < Base
        def handle
          result = Telegram::WorkBot::TutorialRenderer.call(tg_user: tg_user, index: 0)

          return deliver_via_dm(result) if group_chat?

          send_card(result, chat_id: message.dig('chat', 'id'))
        end

        private

        def send_card(result, chat_id:)
          client.send_message(
            result.markdown,
            chat_id: chat_id,
            parse_mode: 'HTML',
            reply_markup: result.keyboard
          )
        end

        def deliver_via_dm(result)
          send_card(result, chat_id: tg_user.dm_chat_id || tg_user.tg_user_id)
          reply('📚 Обучение отправил тебе в личку.')
        rescue Telegram::Client::Error => e
          # В отличие от /help, откатиться на вывод в группу нельзя: у карточки
          # кнопки, и в общем чате их нажмёт не тот, кому урок адресован.
          Rails.logger.warn("[Commands::Tutorial] DM failed: #{e.message}")
          reply(dm_unavailable_hint)
        end

        def dm_unavailable_hint
          '📚 Обучение открывается в личке. Напиши мне в личные сообщения и повтори <code>/tutorial</code>.'
        end

        def group_chat?
          ['group', 'supergroup'].include?(message.dig('chat', 'type'))
        end
      end
    end
  end
end
