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

          case action
          when 'contact' then start_contact_intake(property)
          when 'snooze'  then snooze(property)
          when 'decline' then decline(property)
          when 'invite'  then invite_owner(property)
          else ack('Неизвестное действие', alert: true)
          end
        end

        private

        # Дальше ответ ловит OwnerIntakeProcessor: он смотрит pending_action и
        # понимает, что следующее сообщение от этого сотрудника — контакт
        # собственника, а не вопрос боту.
        def start_contact_intake(property)
          tg_user.set_pending_action!(
            type: 'owner_intake',
            data: { 'property_id' => property.id },
            ttl: 30.minutes
          )
          reply_in_topic(
            "Пришлите контакт собственника объекта #{property_label(property)}.\n\n" \
            'Можно переслать карточку контакта из телефона или написать текстом — ' \
            'например: <i>Светлана Петрова +7 900 123-45-67</i>'
          )
          ack('Жду контакт')
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
          CabinetInvitationDispatcher.call(owner, property, channels: %i[email tg])
          reply_in_topic("Приглашение отправлено: #{owner_label(owner)}")
          ack('Отправлено')
        rescue StandardError => e
          Rails.logger.warn("[OwnerRequest] приглашение не ушло property=#{property.id}: #{e.class}: #{e.message}")
          ack('Не удалось отправить приглашение', alert: true)
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
