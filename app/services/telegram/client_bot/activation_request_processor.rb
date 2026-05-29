# frozen_string_literal: true

module Telegram
  module ClientBot
    # Inbound TG activation flow — клиент сам пишет боту (без token), бот
    # выясняет phone через TG `request_contact` keyboard, ищет User по
    # phone, активирует кабинет.
    #
    # Use-case (#413f): Phone-only клиенты Topnlab (большинство). У нас
    # НЕТ способа написать им первыми (Bot API constraint), но если они
    # сами найдут @anvictorybot (через sales script / QR в офисе /
    # email-подпись агента / лендинг сайта) — этот processor доводит до
    # активации без SMS.
    #
    # Flow:
    #   Stage A — `/start` без token payload:
    #     Bot reply'ит с `request_contact: true` reply_markup кнопкой.
    #   Stage B — `message.contact` payload (после нажатия кнопки):
    #     Validate user_id == from.id (anti-share fraud)
    #     PhoneStopList check (152-ФЗ)
    #     Match User.role=:client by phone last10
    #     Atomic link → user.tg_user_id + invited_at + tg_linked_at
    #     Reply с MagicLinkToken-URL для web cabinet auto-login
    #
    # Boundary с LinkProcessor:
    #   - `/start <token>` → LinkProcessor (opt-in flow из /cabinet/profile)
    #   - bare `/start` или `contact` → ActivationRequestProcessor (это)
    #
    # Privacy:
    #   - НЕ логируем phone в plain (только last 4 цифр через mask helper)
    #   - НЕ форвардим contact payload в Sentry
    #   - На не-match отвечаем politely без leak'a существования аккаунта
    class ActivationRequestProcessor
      def self.applies?(msg)
        new(msg).applies?
      end

      def self.call(msg)
        new(msg).call
      end

      def initialize(msg)
        @msg = msg || {}
      end

      def applies?
        return false unless private_chat?
        return false if from_staff?

        # /start с token payload — relegate to LinkProcessor (он handle'ит
        # opt-in flow от уже-имеющих-кабинет users).
        if @msg['text'].to_s.strip.start_with?('/start')
          token_payload = @msg['text'].to_s.strip.split(/\s+/, 2)[1]
          return token_payload.blank? # bare /start matches; /start <token> — nope
        end

        # message.contact — Stage B
        @msg['contact'].is_a?(Hash) && @msg['contact']['phone_number'].present?
      end

      def call
        if @msg['contact'].is_a?(Hash) && @msg['contact']['phone_number'].present?
          handle_contact
        else
          handle_start
        end
        :handled
      rescue StandardError => e
        Rails.logger.error("[ActivationRequest] #{e.class}: #{e.message.first(200)}")
        Sentry.capture_exception(e, extra: { tg_user_id: @msg.dig('from', 'id') }) if defined?(Sentry)
        reply('Произошла ошибка. Попробуйте ещё раз позже.')
        :handled
      end

      private

      def handle_start
        Rails.logger.info("[ActivationRequest] start request tg_user=#{@msg.dig('from', 'id')}")
        reply(<<~MSG.strip, reply_markup: contact_keyboard)
          👋 <b>Здравствуйте! Это бот АН «Виктори».</b>

          Если вы наш клиент — поделитесь номером телефона, и я привяжу ваш личный кабинет к этому Telegram. Уведомления (события сделки, документы) дальше будут бесплатно сюда.

          Нажмите кнопку <b>«Подтвердить телефон»</b> ниже.
        MSG
      end

      def handle_contact
        contact = @msg['contact']
        from_id = @msg.dig('from', 'id').to_i
        contact_user_id = contact['user_id'].to_i
        phone = contact['phone_number'].to_s

        # SECURITY: пользователь может share'нуть ЧУЖОЙ контакт через
        # стандартный «Attach contact» picker. Тогда `contact.user_id`
        # либо отсутствует, либо принадлежит ДРУГОМУ TG-юзеру.
        # Принимаем только когда контакт = собственный.
        if contact_user_id.zero? || contact_user_id != from_id
          Rails.logger.warn(
            "[ActivationRequest] contact user_id mismatch: from=#{from_id} " \
            "contact_user=#{contact_user_id} (suspicious share)"
          )
          reply(<<~MSG.strip)
            ⚠️ Пожалуйста, поделитесь <b>своим</b> телефоном (кнопкой «Подтвердить телефон»).
            Контакт другого человека привязать нельзя.
          MSG
          return
        end

        last10 = PhoneStopList.normalize(phone)
        if last10.nil?
          reply('Не удалось разобрать номер. Попробуйте ещё раз.')
          return
        end

        if PhoneStopList.blocked?(phone)
          Rails.logger.info("[ActivationRequest] stop-list hit phone=***#{last10.last(4)}")
          reply(<<~MSG.strip)
            Ваш номер исключён из коммуникаций по запросу. Для активации обратитесь к агенту: +7 (4912) 99-23-23.
          MSG
          return
        end

        username = @msg.dig('from', 'username')
        link_result = link_user_by_phone(last10: last10, tg_user_id: from_id, tg_username: username)

        case link_result[:status]
        when :linked
          user = link_result[:user]
          # #413f Шаг 5 — channel='inbound' (клиент сам пришёл, no token).
          ActivationEvent.log!(
            user:     user,
            channel:  'inbound',
            metadata: { tg_user_id: from_id, tg_username: username }
          )
          login_url = generate_login_link(user)
          reply(<<~MSG.strip)
            ✅ <b>Здравствуйте, #{user.first_name.presence || 'клиент АН Виктори'}!</b>

            Привязали ваш Telegram к личному кабинету. Уведомления о сделках, документах и событиях будут приходить сюда.

            Открыть кабинет в браузере: #{login_url}
            <i>(ссылка действует 30 минут)</i>
          MSG
        when :not_found
          Rails.logger.info("[ActivationRequest] no User match phone=***#{last10.last(4)}")
          reply(<<~MSG.strip)
            Не нашли вас в системе. Возможно вы ещё не клиент АН «Виктори», или ваш агент ещё не завёл карточку.

            Свяжитесь с офисом: +7 (4912) 99-23-23 — мы поможем.
          MSG
        when :tg_taken
          reply(<<~MSG.strip)
            Этот Telegram уже привязан к другому аккаунту АН «Виктори».
            Свяжитесь с агентом, если это ошибка.
          MSG
        when :already_linked_to_other
          reply(<<~MSG.strip)
            Ваш номер привязан к другому Telegram. Сначала отключите старый в личном кабинете (раздел «Профиль»).
          MSG
        end
      end

      # Atomic link через transaction + lock. Возвращает Hash со status:
      #   :linked, :not_found, :tg_taken, :already_linked_to_other
      def link_user_by_phone(last10:, tg_user_id:, tg_username:)
        User.transaction do
          # Lookup по last10 digits. Phones в DB хранятся как '+7XXXXXXXXXX'
          # (через `normalize_phone` в OwnerSyncService) — LIKE match с
          # %last10 ловит любой формат.
          user = User.unscoped
                     .where(deleted_at: nil, active: true, role: :client)
                     .where('phone LIKE ?', "%#{last10}")
                     .lock
                     .first

          return { status: :not_found } if user.nil?

          # User уже linked к ДРУГОМУ tg_user_id?
          if user.tg_user_id.present? && user.tg_user_id != tg_user_id
            return { status: :already_linked_to_other, user: user }
          end

          # Этот tg_user_id уже у ДРУГОГО User?
          other = User.where(tg_user_id: tg_user_id).where.not(id: user.id).first
          return { status: :tg_taken, user: user } if other

          user.update!(
            tg_user_id:   tg_user_id,
            tg_username:  tg_username.to_s.delete('@').presence,
            tg_linked_at: Time.current,
            invited_at:   user.invited_at || Time.current
          )
          { status: :linked, user: user }
        end
      end

      def generate_login_link(user)
        # MagicLinkToken — 30-min single-use. identifier хранится как
        # нормализованная форма (для phone — last10 digits).
        token = MagicLinkToken.generate!(
          identifier:      user.phone.presence || user.email.to_s,
          identifier_type: user.phone.present? ? 'phone' : 'email',
          scope:           'login'
        )
        "#{ENV.fetch('APP_URL', 'https://victory62.org')}/cabinet/verify/#{token.token}"
      end

      def private_chat?
        @msg.dig('chat', 'type') == 'private'
      end

      def from_staff?
        from_id = @msg.dig('from', 'id')
        return false if from_id.blank?
        TelegramUser.exists?(tg_user_id: from_id)
      end

      def contact_keyboard
        {
          keyboard: [[{ text: 'Подтвердить телефон', request_contact: true }]],
          resize_keyboard: true,
          one_time_keyboard: true
        }
      end

      def reply(text, reply_markup: nil)
        chat_id = @msg.dig('chat', 'id') || @msg.dig('from', 'id')
        return if chat_id.blank?

        Telegram::Client.new.send_message(
          text,
          chat_id: chat_id,
          parse_mode: 'HTML',
          disable_web_page_preview: false,
          reply_markup: reply_markup
        )
      rescue StandardError => e
        Rails.logger.warn("[ActivationRequest#reply] #{e.class}: #{e.message.first(160)}")
      end
    end
  end
end
