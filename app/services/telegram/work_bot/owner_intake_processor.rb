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

      # Второй тип ожидания: собственник заведён, но приглашение не ушло — не
      # было ни почты, ни телеграма. Раньше бот об этом просил, а состояния не
      # ставил, и ответ агента доставался LLM-ассистенту вместо обработчика.
      EMAIL_PENDING_TYPE = 'owner_email'

      PENDING_TYPES = [PENDING_TYPE, EMAIL_PENDING_TYPE].freeze

      def self.applies?(msg, tg_user = nil)
        return false unless msg.is_a?(Hash)
        return false unless msg.dig('chat', 'type') == 'private'

        from_id = msg.dig('from', 'id')
        return false if from_id.blank? || msg.dig('from', 'is_bot')
        return false if msg['contact'].blank? && msg['text'].blank?

        # Команды не перехватываем. Процессор стоит выше WorkBot::Router, и без
        # этой строки на всё время ожидания (полчаса) сотрудник терял бы /help,
        # /dashboard, /task — бот отвечал бы «не нашёл телефон» на каждую, а
        # состояние намеренно не сбрасывается, так что выйти было бы нечем.
        # Соседние DM-обработчики делают ровно ту же проверку.
        return false if msg['contact'].blank? && msg['text'].to_s.lstrip.start_with?('/')

        tg_user ||= ::TelegramUser.find_by(tg_user_id: from_id)
        return false unless tg_user&.status == 'active'

        PENDING_TYPES.include?(tg_user.pending_action&.dig('type'))
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
        type = pending&.dig('type')
        return :ignored unless PENDING_TYPES.include?(type)

        property = Property.unscoped.find_by(id: pending.dig('data', 'property_id'))
        if property.nil?
          @tg_user.clear_pending_action!
          return reply('Объект не найден — запрос отменён.')
        end

        return accept_email(property) if type == EMAIL_PENDING_TYPE

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

      # Агент дослал почту после неудачной отправки приглашения. Состояние не
      # сбрасываем, пока почта не разобрана: опечатка не должна возвращать
      # человека к началу.
      def accept_email(property)
        # Приводим к нижнему регистру: агент набирает почту с телефона, где
        # первая буква автоматически заглавная, а уникальность в индексе
        # регистрозависимая — иначе Svetlana@… и svetlana@… разойдутся.
        email = Crm::ContactParser.from_text(@msg['text'].to_s)&.dig(:email)&.strip&.downcase
        return reply('Не нашёл почту в сообщении. Пришлите её одним словом — например: <i>svetlana@example.com</i>') if email.blank?

        owner = property.owner_user_id && User.find_by(id: property.owner_user_id)
        if owner.nil?
          @tg_user.clear_pending_action!
          return reply("У объекта #{label(property)} больше не указан собственник — начните заново.")
        end

        # Проверяем занятость до записи, а не ловим RecordNotUnique после.
        # Исключение из базы обрывает транзакцию целиком, и всё, что идёт
        # следом, падает уже на отравленном соединении — включая сброс
        # ожидания. unscoped обязателен: удалённые учётки продолжают занимать
        # почту в индексе.
        if User.unscoped.where.not(id: owner.id).exists?(email: email)
          return reply('Эта почта уже привязана к другой учётке. Пришлите другую или передайте ссылку собственнику сами.')
        end

        save_email_and_invite(property, owner, email)
      end

      # update_columns, а не update!: собственника заводит Crm::OwnerLinker через
      # save(validate: false) — у контакта с одним телефоном нет ни почты, ни
      # фамилии, и валидацию такая запись не проходит по причинам, к почте
      # отношения не имеющим. update! падал бы на них всегда, и агент видел бы
      # «почта занята» там, где она свободна.
      #
      # Уникальность при этом не теряется: её стережёт частичный индекс по
      # users.email, и нарушение прилетит сюда как RecordNotUnique.
      def save_email_and_invite(property, owner, email)
        owner.update_columns(email: email, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
        @tg_user.clear_pending_action!

        result = CabinetInvitationDispatcher.call(owner, property, channels: %i[email tg])
        if Array(result&.channels_succeeded).empty?
          errors = Array(result&.errors).join('; ').presence || 'причина не указана'
          return reply("Почта сохранена, но приглашение всё равно не ушло: #{ERB::Util.html_escape(errors)}")
        end

        reply("✅ Приглашение отправлено на #{ERB::Util.html_escape(email)} — объект #{label(property)}.")
      rescue ActiveRecord::RecordNotUnique => e
        # Страховка от гонки: между проверкой и записью почту мог занять
        # параллельный синк из Topnlab.
        Rails.logger.warn("[OwnerIntake] почта не сохранена owner=#{owner.id}: #{e.class}: #{e.message.first(120)}")
        reply('Эта почта уже привязана к другой учётке. Пришлите другую или передайте ссылку собственнику сами.')
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

        flag = staff_owner_flag(user)
        notify_directors_on_staff_owner(property, user, flag) if flag

        reply(success_text(property, user, created), keyboard: invite_keyboard(property))
      end

      # Собственником оказался сотрудник: приглашение уйдёт ему, и договор в
      # кабинете он подпишет за «собственника» — то есть выведет карточку на
      # витрину в обход всего смысла этого гейта.
      #
      # Запрещать нельзя: агент может продавать собственную квартиру, и по
      # одному присланному контакту законный случай неотличим от подлога.
      # Поэтому связь остаётся, но перестаёт быть тихой — как и в
      # OwnerRequestCallback#decline, спорный случай уходит директору.
      #
      # Проверять только «прислал сам себя» мало: это ловит ровно честный
      # случай. Достаточно второй симки или свежей почты, чтобы завести нового
      # client'а и пройти молча. Поэтому сюда же попадает и чужая сотрудничья
      # учётка — сговор двух агентов. Полностью на входе это не закрывается:
      # окончательная проверка живёт на подписании договора (отдельная задача),
      # где сверяется, что подписант не является ответственным агентом объекта.
      #
      # @return [Symbol, nil] :self | :staff | nil
      def staff_owner_flag(user)
        linked_id = @tg_user&.user&.id
        return :self if linked_id.present? && linked_id == user.id
        return :staff if user.role_agent? || user.role_admin?

        nil
      end

      def notify_directors_on_staff_owner(property, user, flag)
        Rails.logger.warn(
          "[OwnerIntake] собственником указан сотрудник (#{flag}) " \
          "property=#{property.id} user=#{user.id} by_tg=#{@tg_user.tg_user_id}"
        )

        ::TelegramUser.where(status: 'active', role: %w[director admin])
                      .where.not(dm_chat_id: nil)
                      .find_each do |d|
          # rescue на каждого получателя, а не на весь обход: один директор с
          # заблокированным ботом (Telegram отдаёт 403) иначе глушил бы
          # оповещение всем следующим по порядку id — а это единственный
          # контроль над сознательно разрешённой связью.
          @client.send_message(staff_owner_text(user, property, flag), chat_id: d.dm_chat_id, parse_mode: 'HTML')
        rescue StandardError => e
          Rails.logger.warn("[OwnerIntake] не предупредил директора #{d.id}: #{e.class}: #{e.message}")
        end
      end

      def staff_owner_text(user, property, flag)
        who = flag == :self ? 'самого себя' : "сотрудника #{ERB::Util.html_escape(owner_name(user))}"

        "⚠️ #{ERB::Util.html_escape(@tg_user.display_name)} указал собственником объекта " \
          "#{ERB::Util.html_escape(label(property))} #{who}.\n" \
          'Если это и правда владелец — ничего делать не нужно. Иначе подписание договора ' \
          'пройдёт мимо настоящего собственника.'
      end

      def owner_name(user)
        [user.first_name, user.last_name].compact_blank.join(' ').presence ||
          user.email.presence || user.phone.to_s
      end

      def success_text(property, user, created)
        who = [user.first_name, user.last_name].compact_blank.join(' ').presence || user.phone.presence || user.email
        status = created ? 'заведён' : 'найден в базе'
        contacts = [user.phone.presence, user.email.presence].compact.join(', ')

        "✅ Собственник #{status}: <b>#{ERB::Util.html_escape(who)}</b>" \
          "#{contacts.present? ? " (#{ERB::Util.html_escape(contacts)})" : ''}\n" \
          "Объект #{label(property)}.\n\n" \
          'Отправить собственнику ссылку на подписание договора? После подписания объект попадёт на витрину.'
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
