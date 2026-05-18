# frozen_string_literal: true

module Telegram
  module WorkBot
    module Commands
      # Базовый класс командного хендлера. Подкласс получает разобранную команду
      # и сырое TG message, отвечает текстом обратно в тот же чат/топик.
      #
      # Подкласс должен реализовать #handle(args) и опц. указать:
      #   `manager_only true`  — требует TelegramUser#is_manager (legacy boolean)
      #   `director_only true` — требует role=director|admin (Phase 7.1+ для voice intake)
      class Base
        class << self
          def manager_only(val = true)
            @manager_only = val
          end

          def manager_only?
            @manager_only == true
          end

          def director_only(val = true)
            @director_only = val
          end

          def director_only?
            @director_only == true
          end

          # Phase 7.3 — публичные команды (/help, /start). Не требуют
          # tg_user.present?. Гарантирует пропуск всех role-gates.
          def public_command(val = true)
            @public_command = val
          end

          def public_command?
            @public_command == true
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
          # Публичные команды не требуют регистрации — пропускаем все gates.
          return handle if self.class.public_command?

          return reply('🚫 Команда доступна только сотрудникам АН. Свяжитесь с руководителем.') if tg_user.nil?
          return reply('🚫 Команда доступна только руководителям.') if self.class.manager_only? && !tg_user.is_manager?
          return reply('🚫 Только для директора АН. Используй /task @username dd.MM.yy <текст> для одиночной задачи.') if self.class.director_only? && !tg_user.can_voice_distribute?

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
            chat_id: message.dig('chat', 'id'),
            reply_to_message_id: message['message_id'],
            message_thread_id: message['message_thread_id'],
            parse_mode: opts.fetch(:parse_mode, 'HTML')
          )
        end

        # Phase 9 Iter 1 — Authorization helper для commands которые операют
        # ОТДЕЛЬНЫЙ lead-event (не обязательно "свой"). Разрешает: assignee
        # лида ИЛИ manager (для override). Используется в /stage, /note.
        # @param lead [LeadEvent]
        def assignee_or_manager?(lead)
          return false if tg_user.nil?
          return true  if tg_user.is_manager?
          return false if lead.nil?

          lead.assigned_to_id == tg_user.id
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
