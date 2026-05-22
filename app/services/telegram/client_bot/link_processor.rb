# frozen_string_literal: true

module Telegram
  module ClientBot
    # Deep-link Telegram linking processor. Activated by `/start <token>` в
    # private chat от клиента (non-staff).
    #
    # Flow:
    #   1. Cabinet UI генерирует TgLinkToken и редиректит на
    #      https://t.me/<TG_BOT_USERNAME>?start=<token>
    #   2. Telegram открывает бота, клиент жмёт «Start» → bot получает
    #      `/start <token>` в private DM.
    #   3. InboundProcessor роутит сюда (см. inbound_processor.rb ранний branch).
    #   4. consume! → user.tg_user_id выставлен + reply «Готово!».
    #
    # Не обрабатывает bare `/start` без payload — пусть default-меню бота
    # покажется (через WorkBot::Router → bot commands).
    #
    # Failure replies (text, no PII):
    #   :not_found → «Ссылка не распознана. Попробуйте подключить TG ещё раз
    #               через личный кабинет.»
    #   :expired → «Ссылка устарела (срок 30 мин). Создайте новую в кабинете.»
    #   :already_consumed → «Эта ссылка уже использована.»
    #   :user_already_linked → «Ваш аккаунт уже привязан к другому TG.
    #               Сначала отключите в кабинете.»
    #   :tg_user_already_linked_to_other → «Этот TG уже привязан к другому
    #               аккаунту в АН Виктори.»
    class LinkProcessor
      ERROR_MESSAGES = {
        not_found:                        'Ссылка не распознана. Создайте новую в личном кабинете.',
        expired:                          'Ссылка устарела (срок 30 мин). Создайте новую в кабинете.',
        already_consumed:                 'Эта ссылка уже использована.',
        user_already_linked:              'Ваш аккаунт уже привязан к другому Telegram. Сначала отключите старый в кабинете.',
        tg_user_already_linked_to_other:  'Этот Telegram уже привязан к другому аккаунту АН Виктори.'
      }.freeze

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

        text = @msg['text'].to_s.strip
        return false unless text.start_with?('/start')

        # Token payload required — bare `/start` does NOT match.
        text.split(/\s+/, 2)[1].present?
      end

      def call
        token   = @msg['text'].to_s.strip.split(/\s+/, 2)[1]
        from_id = @msg.dig('from', 'id')
        username = @msg.dig('from', 'username')

        if token.blank? || from_id.blank?
          reply(ERROR_MESSAGES[:not_found])
          return :handled
        end

        user, err = TgLinkToken.consume!(
          raw_token:   token,
          tg_user_id:  from_id.to_i,
          tg_username: username
        )

        if err
          Rails.logger.info("[ClientBot::LinkProcessor] consume failed: #{err} (tg_user=#{from_id})")
          reply(ERROR_MESSAGES[err] || 'Не получилось подключить. Попробуйте ещё раз через кабинет.')
        else
          Rails.logger.info("[ClientBot::LinkProcessor] linked user=#{user.id} tg=#{from_id}")
          reply(success_message(user))
        end

        :handled
      rescue StandardError => e
        Rails.logger.error("[ClientBot::LinkProcessor] #{e.class}: #{e.message.first(200)}")
        Sentry.capture_exception(e, extra: { tg_user_id: @msg.dig('from', 'id') }) if defined?(Sentry)
        reply('Произошла ошибка. Попробуйте ещё раз позже.')
        :handled
      end

      private

      def private_chat?
        @msg.dig('chat', 'type') == 'private'
      end

      # Staff пишут в private chat боту тоже (DM Q&A) — но `/start` от них
      # не должен случайно линковать staff record к client User'у.
      def from_staff?
        from_id = @msg.dig('from', 'id')
        return false if from_id.blank?
        TelegramUser.exists?(tg_user_id: from_id)
      end

      def success_message(user)
        name = user.first_name.presence || 'Здравствуйте'
        <<~MSG.strip
          ✅ <b>#{name}, ваш Telegram подключён к личному кабинету АН «Виктори».</b>

          Теперь уведомления (приглашения, события по сделкам, документы) будут приходить сюда — бесплатно, без SMS.

          Отключить можно в любой момент в /cabinet/profile.
        MSG
      end

      def reply(text)
        chat_id = @msg.dig('chat', 'id') || @msg.dig('from', 'id')
        return if chat_id.blank?

        Telegram::Client.new.send_message(
          text,
          chat_id: chat_id,
          parse_mode: 'HTML',
          disable_web_page_preview: true
        )
      rescue StandardError => e
        Rails.logger.warn("[ClientBot::LinkProcessor#reply] #{e.class}: #{e.message.first(160)}")
      end
    end
  end
end
