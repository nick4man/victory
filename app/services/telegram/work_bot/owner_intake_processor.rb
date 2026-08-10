# frozen_string_literal: true

module Telegram
  module WorkBot
    # Приём контакта собственника, присланного агентом в личку боту.
    #
    # Срабатывает только когда сотрудник до этого нажал «Прислать контакт» под
    # запросом по конкретному объекту — состояние лежит в
    # TelegramUser#dm_pending_action (type: 'owner_intake'). Без этого условия
    # процессор перехватывал бы любое сообщение в личке и ломал бы остальные
    # сценарии бота.
    #
    # Построен по образцу WorkBot::PhotoIntakeProcessor: та же пара applies?/call
    # и тот же механизм состояния с TTL.
    class OwnerIntakeProcessor
      PENDING_TYPE = 'owner_intake'

      def self.applies?(msg, tg_user = nil)
        return false unless msg.is_a?(Hash)
        return false unless msg.dig('chat', 'type') == 'private'

        from_id = msg.dig('from', 'id')
        return false if from_id.blank? || msg.dig('from', 'is_bot')
        return false if msg['contact'].blank? && msg['text'].blank?

        tg_user ||= ::TelegramUser.find_by(tg_user_id: from_id)
        return false unless tg_user&.status == 'active'

        tg_user.pending_action&.dig('type') == PENDING_TYPE
      end

      def self.call(msg, client: ::Telegram::Client.new)
        new(msg, client: client).call
      end

      def initialize(msg, client: ::Telegram::Client.new)
        @msg = msg
        @client = client
        @tg_user = ::TelegramUser.find_by(tg_user_id: msg.dig('from', 'id'))
      end

      def call
        pending = @tg_user&.pending_action
        return :ignored unless pending&.dig('type') == PENDING_TYPE

        property = Property.unscoped.find_by(id: pending.dig('data', 'property_id'))
        if property.nil?
          @tg_user.clear_pending_action!
          return reply('Объект не найден — запрос отменён.')
        end

        parsed = parse_contact
        # Не разобрали — состояние НЕ сбрасываем: человек уже согласился прислать
        # контакт, и терять этот шаг из-за опечатки значит начинать сначала.
        return reply(retry_hint) if parsed.nil?

        link_owner(property, parsed)
      end

      private

      def parse_contact
        Crm::ContactParser.from_telegram(@msg['contact']) ||
          Crm::ContactParser.from_text(@msg['text'])
      end

      def link_owner(property, parsed)
        user, created = Crm::OwnerLinker.from_contact(**parsed.slice(:first_name, :last_name, :phone, :email))

        if user.nil?
          Rails.logger.warn("[OwnerIntake] клиент не создан property=#{property.id}")
          return reply('Не удалось завести клиента по этому контакту. Попробуйте прислать телефон и имя ещё раз.')
        end

        attached = Crm::OwnerLinker.attach!(property, user)
        @tg_user.clear_pending_action!

        return reply("У объекта #{label(property)} уже указан собственник — контакт сохранён, но связь не менялась.") unless attached

        reply(success_text(property, user, created), keyboard: invite_keyboard(property))
      end

      def success_text(property, user, created)
        who = [user.first_name, user.last_name].compact_blank.join(' ').presence || user.phone.presence || user.email
        status = created ? 'заведён' : 'найден в базе'
        contacts = [user.phone.presence, user.email.presence].compact.join(', ')

        "✅ Собственник #{status}: <b>#{ERB::Util.html_escape(who)}</b>" \
          "#{contacts.present? ? " (#{ERB::Util.html_escape(contacts)})" : ''}\n" \
          "Объект #{label(property)}.\n\n" \
          "Отправить ему ссылку на подписание договора? После подписания объект попадёт на витрину."
      end

      def invite_keyboard(property)
        { inline_keyboard: [[
          { text: '📨 Отправить ссылку', callback_data: "owner:invite:#{property.id}" }
        ]] }
      end

      def retry_hint
        'Не нашёл в сообщении телефон или почту. Перешлите карточку контакта ' \
          'или напишите текстом — например: <i>Светлана Петрова +7 900 123-45-67</i>'
      end

      def label(property)
        parts = [property.district.presence, property.address.presence].compact
        "##{property.id}#{parts.any? ? " — #{parts.join(', ')}" : ''}"
      end

      def reply(text, keyboard: nil)
        opts = { chat_id: @msg.dig('chat', 'id'), parse_mode: 'HTML' }
        opts[:reply_markup] = keyboard if keyboard
        @client.send_message(text, **opts)
        :handled
      end
    end
  end
end
