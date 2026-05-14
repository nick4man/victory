# frozen_string_literal: true

module Telegram
  module WorkBot
    module Callbacks
      # Базовый класс callback-обработчика (нажатия на inline-кнопки в карточке лида).
      #
      # callback_data — строка вида "<prefix>:<arg1>:<arg2>:...". Префикс определяет
      # класс-обработчик (см. CallbacksRouter::PREFIX_MAP); оставшиеся сегменты передаются
      # подклассу в @args (Array<String>).
      #
      # Подкласс реализует #handle. По окончании обязательно вызывать ack(...) —
      # иначе кнопка в TG будет крутиться у пользователя.
      class Base
        class << self
          attr_accessor :_manager_only

          def manager_only(val = true)
            self._manager_only = val
          end

          def manager_only?
            _manager_only == true
          end
        end

        attr_reader :callback_query, :tg_user, :args, :client

        def initialize(callback_query:, tg_user:, args:, client: Telegram::Client.new)
          @callback_query = callback_query
          @tg_user        = tg_user
          @args           = Array(args)
          @client         = client
        end

        def call
          if self.class.manager_only? && !tg_user.is_manager?
            return ack('🚫 Только для руководителей', alert: true)
          end

          handle
        rescue StandardError => e
          Rails.logger.error("[WorkBot::Callbacks #{self.class.name}] #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
          ack("⚠️ #{e.message.to_s[0, 180]}", alert: true)
        end

        protected

        def handle
          raise NotImplementedError, "#{self.class} must implement #handle"
        end

        # Обязательный ответ Telegram'у — иначе кнопка крутится у пользователя.
        # @param text [String, nil] всплывающая подсказка (если nil — без неё)
        # @param alert [Boolean] true = модальный алерт, false = toast
        def ack(text = nil, alert: false)
          client.answer_callback_query(callback_query['id'], text: text, show_alert: alert)
        end

        # @return [LeadEvent] первый аргумент callback_data, парсится как lead_event_id.
        def lead_event
          @lead_event ||= LeadEvent.find(@args[0])
        end

        # Прислать текстовое сообщение в тот же топик, где была нажата кнопка.
        def reply_in_topic(text, **opts)
          msg = callback_query['message'] || {}
          client.send_message(
            text,
            chat_id: msg.dig('chat', 'id'),
            message_thread_id: msg['message_thread_id'],
            parse_mode: opts.fetch(:parse_mode, 'HTML')
          )
        end

        def actor_mention
          tg_user.tg_username.present? ? "@#{tg_user.tg_username}" : "tg_user_id=#{tg_user.tg_user_id}"
        end
      end
    end
  end
end
