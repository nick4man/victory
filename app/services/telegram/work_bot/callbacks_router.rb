# frozen_string_literal: true

module Telegram
  module WorkBot
    # Диспетчер callback_query от inline-кнопок в карточках лидов.
    #
    # Парсит callback_data по первому ':' — это префикс действия. Например:
    #   "route:42:apartments"   → Callbacks::RouteCallback с args=[42, "apartments"]
    #   "assign:42"             → Callbacks::AssignCallback с args=[42]
    #   "assign_to:42:7"        → Callbacks::AssignToCallback с args=[42, 7]
    #   "spam:42"               → Callbacks::SpamCallback с args=[42]
    #
    # Если пользователь не зарегистрирован как TelegramUser — отвечаем алертом и
    # выходим. Любая необработанная ошибка в handler'е логируется в Rails.logger.
    class CallbacksRouter
      # Карта префиксов callback_data → класс-обработчик.
      # Заглушки: на Фазе 2 шаг 3 используем Callbacks::WipStub чтобы убедиться
      # что цикл webhook → CallbacksRouter → answer_callback_query замкнулся.
      # Реальные обработчики подменят эту мапу в шагах 4-9.
      PREFIX_MAP = {
        'route' => 'Telegram::WorkBot::Callbacks::RouteCallback',
        'assign' => 'Telegram::WorkBot::Callbacks::AssignCallback',
        'assign_to' => 'Telegram::WorkBot::Callbacks::AssignToCallback',
        'assign_cancel' => 'Telegram::WorkBot::Callbacks::AssignCancelCallback',
        'spam' => 'Telegram::WorkBot::Callbacks::SpamCallback'
      }.freeze

      def initialize(callback_query, client: Telegram::Client.new)
        @cb     = callback_query
        @client = client
      end

      def call
        return ignored('empty callback') if @cb.blank? || @cb['data'].blank?

        data = @cb['data'].to_s
        prefix, *rest = data.split(':')
        handler_name = PREFIX_MAP[prefix]

        unless handler_name
          Rails.logger.warn("[CallbacksRouter] unknown prefix=#{prefix.inspect} data=#{data.inspect}")
          @client.answer_callback_query(@cb['id'], text: 'Неизвестное действие.', show_alert: true)
          return :unknown
        end

        tg_user = TelegramUser.find_by(tg_user_id: @cb.dig('from', 'id'))
        unless tg_user
          @client.answer_callback_query(@cb['id'], text: 'Команды доступны только сотрудникам АН.', show_alert: true)
          return :forbidden
        end

        handler_class = handler_name.constantize
        handler_class.new(callback_query: @cb, tg_user: tg_user, args: rest, client: @client).call
        :handled
      rescue StandardError => e
        Rails.logger.error("[CallbacksRouter] #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
        begin
          @client.answer_callback_query(@cb['id'], text: '⚠️ Внутренняя ошибка', show_alert: true)
        rescue StandardError
          nil
        end
        :error
      end

      private

      def ignored(reason)
        Rails.logger.info("[CallbacksRouter] ignored: #{reason}")
        :ignored
      end
    end
  end
end
