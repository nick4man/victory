# frozen_string_literal: true

module Telegram
  module WorkBot
    module Callbacks
      # Кнопки карточки CRM вне мастеров.
      # callback_data: "crm_card:<card_id>:<view|submit|retry>".
      #
      # Решения модератора с последствиями (одобрить, вернуть) идут мастерами
      # с подтверждением; здесь — действия без выбора и ввода. Права
      # перепроверяет Workflow: устаревшая кнопка в старом сообщении
      # получает отказ с объяснением, а не второе действие.
      class CrmCardCallback < Base
        def handle
          card = ::CrmCard.find_by(id: @args[0].to_s[/\A\d+\z/])
          return ack('⚠️ Карточка не найдена', alert: true) unless card

          case @args[1]
          when 'view'   then show(card)
          when 'submit' then apply(workflow.submit!(card, actor: tg_user), '📤 Отправлено на модерацию')
          when 'retry'  then apply(workflow.retry_export!(card, actor: tg_user), '🔁 Выгрузка запущена снова')
          else ack('⚠️ Неизвестное действие', alert: true)
          end
        end

        private

        def workflow
          @workflow ||= ::CrmCards::Workflow.new(notifier: ::CrmCards::Notifier.new(client: client))
        end

        # В карточке телефон клиента — показываем только в личке, даже если
        # кнопку нажали под лидом в группе.
        def show(card)
          return ack('🚫 Карточку видят автор, ответственный по лиду и модераторы.', alert: true) unless viewer?(card)
          unless send_dm(::CrmCards::CardView.render(card, viewer: tg_user))
            return ack('Не могу написать в личку. Открой чат с ботом, нажми «Start» и нажми кнопку ещё раз.', alert: true)
          end

          ack(private_chat? ? nil : '↘︎ Карточка — в личке с ботом')
        end

        # В личке перерисовываем нажатое сообщение — старые кнопки под ним
        # исчезают. Из группы — новое сообщение в личку.
        def apply(result, success_text)
          return ack("⚠️ #{result.error}".truncate(190), alert: true) unless result.ok?

          view = ::CrmCards::CardView.render(result.card.reload, viewer: tg_user)
          private_chat? ? redraw(view) : send_dm(view)
          ack(success_text)
        end

        def viewer?(card)
          card.author_id == tg_user.id || card.responsible&.id == tg_user.id ||
            card.lead_event&.assigned_to_id == tg_user.id ||
            ::CrmCards::Permissions.for(tg_user).can?(:moderate)
        end

        def redraw(view)
          msg = callback_query['message'] || {}
          client.edit_message_text(view[:text], chat_id: msg.dig('chat', 'id'), message_id: msg['message_id'],
                                                reply_markup: { inline_keyboard: view[:keyboard] }, parse_mode: 'HTML')
        rescue Telegram::Client::Error => e
          Rails.logger.info("[CrmCardCallback#redraw] #{e.message} — шлю новым сообщением")
          send_dm(view)
        end

        def send_dm(view)
          client.send_message(view[:text], chat_id: tg_user.dm_chat_id || tg_user.tg_user_id, parse_mode: 'HTML',
                                           reply_markup: { inline_keyboard: view[:keyboard] })
          true
        rescue Telegram::Client::Error => e
          Rails.logger.warn("[CrmCardCallback] DM to #{tg_user.mention} failed: #{e.message}")
          false
        end

        def private_chat?
          callback_query.dig('message', 'chat', 'type') == 'private'
        end
      end
    end
  end
end
