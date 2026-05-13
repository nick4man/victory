# frozen_string_literal: true

module Telegram
  module WorkBot
    module Commands
      # Базовый класс командного хендлера. Подкласс получает разобранную команду
      # и сырое TG message, отвечает текстом обратно в тот же чат/топик.
      #
      # Подкласс должен реализовать #handle(args) и опц. указать
      #   `manager_only true` если команда требует TelegramUser#is_manager.
      class Base
        class << self
          def manager_only(val = true)
            @manager_only = val
          end

          def manager_only?
            @manager_only == true
          end
        end

        attr_reader :tg_user, :message, :args, :client

        def initialize(message:, args:, tg_user:, client: Telegram::Client.new)
          @message = message
          @args = args.to_s.strip
          @tg_user = tg_user
          @client = client
        end

        def call
          return reply('🚫 Команда доступна только сотрудникам АН. Свяжитесь с руководителем.') if tg_user.nil?
          return reply('🚫 Команда доступна только руководителям.') if self.class.manager_only? && !tg_user.is_manager?

          handle
        rescue StandardError => e
          Rails.logger.error("[WorkBot::Command #{self.class.name}] #{e.class}: #{e.message}")
          reply("⚠️ Ошибка: #{e.message}")
          :error
        end

        protected

        def handle
          raise NotImplementedError
        end

        def reply(text, **opts)
          client.send_message(
            text,
            chat_id:             message.dig('chat', 'id'),
            reply_to_message_id: message['message_id'],
            message_thread_id:   message['message_thread_id'],
            parse_mode:          opts.fetch(:parse_mode, 'HTML')
          )
        end

        # Личная переписка (DM) с пользователем-агентом — если у TelegramUser
        # есть dm_chat_id, шлём туда; иначе пытаемся отправить по tg_user_id
        # (Telegram примет, если пользователь когда-либо писал боту).
        def dm(text, to: tg_user, **opts)
          chat_id = to&.dm_chat_id || to&.tg_user_id
          return false if chat_id.blank?
          client.send_message(text, chat_id: chat_id, parse_mode: opts.fetch(:parse_mode, 'HTML'))
        rescue Telegram::Client::Error => e
          Rails.logger.warn("[WorkBot] DM failed for #{to&.mention}: #{e.message}")
          false
        end
      end
    end
  end
end
