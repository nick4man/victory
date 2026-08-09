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
        'spam' => 'Telegram::WorkBot::Callbacks::SpamCallback',
        'batch_confirm' => 'Telegram::WorkBot::Callbacks::TaskBatchConfirmCallback',
        'task' => 'Telegram::WorkBot::Callbacks::TaskActionCallback',
        # Iter 60 — manager+ photo disposition (cloud upload / staff dispatch).
        'photo' => 'Telegram::WorkBot::Callbacks::PhotoDispositionCallback',
        # Phase 15 — /dashboard drilldown (cards, refresh, back).
        'dashboard' => 'Telegram::WorkBot::Callbacks::DashboardDrillCallback',
        # Связывание телеграм-аккаунта с учёткой сотрудника кнопками (директор).
        # Заменяет команду /link, которой не пользовались ни разу.
        'link_staff' => 'Telegram::WorkBot::Callbacks::LinkStaffCallback'
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
        from_id = @cb.dig('from', 'id')

        unless handler_name
          Rails.logger.warn("[CallbacksRouter] unknown prefix=#{prefix.inspect} data=#{data.inspect}")
          @client.answer_callback_query(@cb['id'], text: 'Неизвестное действие.', show_alert: true)
          log_audit(from_id, "callback:#{prefix}", data, 'unknown_command')
          return :unknown
        end

        tg_user = TelegramUser.find_by(tg_user_id: from_id)
        unless tg_user
          Rails.logger.warn("[CallbacksRouter] unregistered tg_user_id=#{from_id} clicked #{prefix} — alert shown")
          @client.answer_callback_query(@cb['id'], text: 'Команды доступны только сотрудникам АН.', show_alert: true)
          log_audit(from_id, "callback:#{prefix}", data, 'forbidden')
          return :forbidden
        end

        handler_class = handler_name.constantize
        handler_class.new(callback_query: @cb, tg_user: tg_user, args: rest, client: @client).call
        log_audit(from_id, "callback:#{prefix}", data, 'ok')
        :handled
      rescue StandardError => e
        Rails.logger.error("[CallbacksRouter] #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
        log_audit(@cb&.dig('from', 'id'), "callback:#{@cb&.dig('data').to_s.split(':').first}", @cb&.dig('data'),
                  'error', error_class: e.class.name, error_message: e.message)
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

      # Phase 14 Iter 52 — extended audit log с error_message (full exception text).
      # До фикса debugging failed callbacks был blind: result='error' + error_class
      # без full message не позволял diagnose без grep prod logs.
      def log_audit(tg_user_id, command, args, result, error_class: nil, error_message: nil)
        return if tg_user_id.blank?

        BotCommandLog.create!(
          tg_user_id: tg_user_id,
          command: command,
          args: args.to_s,
          result: result,
          error_class: error_class,
          error_message: error_message.to_s.presence&.truncate(500)
        )
      rescue StandardError => e
        Rails.logger.warn("[CallbacksRouter#log_audit] #{e.class}: #{e.message}")
      end
    end
  end
end
