# frozen_string_literal: true

module Telegram
  module WorkBot
    module Callbacks
      # Кнопки под запросом «кто собственник этого объекта».
      #
      #   owner:contact:<property_id> — агент готов прислать контакт
      #   owner:snooze:<property_id>  — отложить на неделю
      #   owner:decline:<property_id> — объект не его, дальше разбирается директор
      #   owner:invite:<property_id>  — отправить собственнику ссылку на подписание
      #
      # Зачем это вообще: объект не попадает на витрину, пока собственник не
      # подписал агентский договор в кабинете. Кабинет находит объекты по
      # owner_user_id, а он пуст у всех карточек — Topnlab связь продавца с
      # объектом не отдаёт. Знает её только агент.
      class OwnerRequestCallback < Base
        SNOOZE_PERIOD = 7.days

        def handle
          action = args[0]
          property = Property.unscoped.find_by(id: args[1])
          return ack('Объект не найден', alert: true) if property.nil?

          # Действия по чужому объекту недоступны: decline навсегда выключает
          # объект из опроса, invite шлёт письмо собственнику. Директор при этом
          # может всё — он и разбирает спорные случаи.
          unless property.user_id == linked_user_id || tg_user.role_director? || tg_user.role_admin?
            return ack('Это не ваш объект', alert: true)
          end

          case action
          when 'contact' then start_contact_intake(property)
          when 'cancel'  then cancel_intake(property)
          when 'snooze'  then snooze(property)
          when 'decline' then decline(property)
          when 'invite'  then invite_owner(property)
          else ack('Неизвестное действие', alert: true)
          end
        end

        # Учётка CRM, привязанная к этому телеграму. nil, если связи ещё нет —
        # тогда любой объект будет чужим, и это правильно: рассылку такому
        # сотруднику мы и не отправляли.
        def linked_user_id
          @linked_user_id ||= tg_user.user&.id
        end

        private

        # Дальше ответ ловит OwnerIntakeProcessor: он смотрит pending_action и
        # понимает, что следующее сообщение от этого сотрудника — контакт
        # собственника, а не вопрос боту.
        # TTL восемь часов, а не полчаса: агент нажимает кнопку, идёт звонить
        # собственнику и возвращается сильно позже. При истёкшем состоянии
        # присланный контакт проваливается в LLM-Q&A — то есть ФИО и телефон
        # физлица уходят внешнему провайдеру, а агент получает бессмысленный
        # ответ ассистента вместо «срок истёк».
        INTAKE_TTL = 8.hours

        def start_contact_intake(property)
          tg_user.set_pending_action!(
            type: 'owner_intake',
            data: { 'property_id' => property.id },
            ttl: INTAKE_TTL
          )
          send_with_cancel(
            "Пришлите контакт собственника объекта #{property_label(property)}.\n\n" \
            'Можно переслать карточку контакта из телефона или написать текстом — ' \
            'например: <i>Светлана Петрова +7 900 123-45-67</i>',
            property
          )
          ack('Жду контакт')
        end

        # Кнопка отмены обязательна: пока бот ждёт контакт, выйти из режима
        # иначе нечем — команды он намеренно пропускает мимо себя.
        def send_with_cancel(text, property)
          msg = callback_query['message'] || {}
          client.send_message(
            text,
            chat_id: msg.dig('chat', 'id'),
            message_thread_id: msg['message_thread_id'],
            parse_mode: 'HTML',
            reply_markup: { inline_keyboard: [[
              { text: '✖️ Отмена', callback_data: "owner:cancel:#{property.id}" }
            ]] }
          )
        end

        def cancel_intake(_property)
          tg_user.clear_pending_action!
          reply_in_topic('Отменил. Вопрос вернётся позже.')
          ack('Отменено')
        end

        def snooze(property)
          property.update_columns( # rubocop:disable Rails/SkipsModelValidations
            owner_request_snoozed_until: SNOOZE_PERIOD.from_now,
            updated_at: Time.current
          )
          ack("Отложено до #{I18n.l(SNOOZE_PERIOD.from_now.to_date, format: :default)}")
        end

        # «Не мой объект» — не повод спрашивать снова: ответственный указан
        # неверно, и это правится в CRM человеком, а не повторной рассылкой.
        def decline(property)
          property.update_columns( # rubocop:disable Rails/SkipsModelValidations
            owner_request_declined_at: Time.current,
            updated_at: Time.current
          )
          notify_directors(
            "⚠️ #{actor_mention} сообщил, что объект #{property_label(property)} не его.\n" \
            'Нужно поправить ответственного в CRM — до этого объект не попадёт на витрину.'
          )
          ack('Передано директору')
        end

        def invite_owner(property)
          owner = property.owner_user_id && User.find_by(id: property.owner_user_id)
          return ack('У объекта ещё нет собственника', alert: true) if owner.nil?

          # SMS намеренно нет: цепочка email → telegram бесплатна, а платный
          # канал в автоматической рассылке — отдельное решение.
          result = CabinetInvitationDispatcher.call(owner, property, channels: %i[email tg])

          # Диспетчер НЕ бросает исключений: каждый канал обёрнут своим rescue, и
          # при неудаче возвращается Result с пустым channels_succeeded. Судить по
          # отсутствию исключения нельзя — самый частый вход, контакт с одним лишь
          # телефоном, тихо не отправляет ничего: email пуст, телеграма у клиента
          # нет. Агент считал бы объект сделанным, а собственник не получил бы
          # ничего.
          if Array(result&.channels_succeeded).empty?
            reply_in_topic(undelivered_text(owner, result))
            return ack('Отправить не удалось', alert: true)
          end

          reply_in_topic("✅ Приглашение отправлено (#{Array(result.channels_succeeded).join(', ')}): #{owner_label(owner)}")
          ack('Отправлено')
        rescue StandardError => e
          Rails.logger.warn("[OwnerRequest] приглашение не ушло property=#{property.id}: #{e.class}: #{e.message}")
          ack('Не удалось отправить приглашение', alert: true)
        end

        # Объясняем причину, а не просто «не получилось»: в подавляющем
        # большинстве случаев не хватает почты, и это решается одним сообщением
        # от агента.
        def undelivered_text(owner, result)
          reason =
            if owner.email.blank? && owner.tg_user_id.blank?
              'у него в системе нет ни почты, ни телеграма'
            elsif owner.invited_at.present?
              'приглашение ему уже отправляли раньше'
            else
              "каналы не отработали: #{Array(result&.errors).join('; ').presence || 'причина не указана'}"
            end

          "⚠️ Приглашение НЕ отправлено #{owner_label(owner)} — #{reason}.\n" \
            'Пришлите почту собственника ответным сообщением, и я повторю.'
        end

        def notify_directors(text)
          TelegramUser.where(status: 'active', role: %w[director admin])
                      .where.not(dm_chat_id: nil)
                      .find_each { |d| client.send_message(text, chat_id: d.dm_chat_id) }
        end

        def property_label(property)
          parts = [property.district.presence, property.address.presence].compact
          "##{property.id}#{parts.any? ? " — #{parts.join(', ')}" : ''}"
        end

        def owner_label(owner)
          [owner.first_name, owner.last_name].compact_blank.join(' ').presence ||
            owner.email.presence || owner.phone.to_s
        end
      end
    end
  end
end
