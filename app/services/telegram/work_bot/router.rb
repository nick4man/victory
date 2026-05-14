# frozen_string_literal: true

module Telegram
  module WorkBot
    # Маршрутизатор апдейтов рабочего Telegram-бота.
    #
    # Точка входа из webhook-контроллера (когда сообщение пришло из рабочей
    # группы AН или из DM сотрудника). Распознаёт:
    #   * /команды (whoami, lead, route, assign, task, stage, note, close, …)
    #   * 6-значный код в DM — верификация после /whoami
    #   * упоминание @victory62_bot в любом топике (Phase 5 — NL ответы)
    #   * сообщения в топике ВОПРОС - ОТВЕТ (Phase 5 — NL без упоминания)
    #
    # В Phase 1 реализованы только /whoami + DM-code path. Остальные команды
    # отвечают «Команда будет в Phase N» — это сразу видно агенту, не молчит.
    class Router
      WORK_CHAT_ID = -1_003_779_115_845
      CODE_REGEX   = /\A\d{6}\z/
      COMMAND_PREFIX = '/'

      COMMANDS = {
        '/whoami' => Commands::Whoami,
        '/whoami_force' => Commands::WhoamiForce,
        '/learn_topic' => :handle_learn_topic,
        '/lead' => Commands::Lead,
        '/route' => Commands::Route,
        '/assign' => Commands::Assign,
        '/stage' => Commands::Stage,
        '/note' => Commands::Note,
        '/close' => Commands::Close,
        '/task' => Commands::Task
      }.freeze

      def initialize(message, client: Telegram::Client.new)
        @msg = message.is_a?(Hash) ? message : {}
        @client = client
      end

      def call
        return :ignored if @msg.empty?

        # 1. DM code verification — приоритет, должен сработать до общих веток
        return verify_code_in_dm if dm_code?

        # 2. Команды
        text = @msg['text'].to_s.strip
        return dispatch_command(text) if text.start_with?(COMMAND_PREFIX)

        # 3. Прочее — игнорируем (другие фазы добавят NL-ответы)
        :ignored
      end

      private

      def dispatch_command(text)
        cmd, rest = text.split(/\s+/, 2)
        cmd = cmd.downcase

        # В групповых чатах TG автоматически дописывает @bot_name к команде:
        # «/whoami@victory62_bot brettiney370@gmail.com». Убираем суффикс перед lookup.
        cmd = cmd.sub(/@\w+\z/, '') if cmd.include?('@')

        case COMMANDS[cmd]
        when Class
          tg_user = TelegramUser.find_by(tg_user_id: @msg.dig('from', 'id'))
          handler = COMMANDS[cmd].new(message: @msg, args: rest, tg_user: tg_user, client: @client)
          handler.call
          :handled
        when Symbol
          send(COMMANDS[cmd], rest)
          :handled
        else
          reply("Команда #{cmd} не распознана либо ещё не реализована. Доступно: <code>/whoami email</code>")
          :unknown_command
        end
      end

      # `/learn_topic <topic_key>` — ручная привязка thread_id текущего топика
      # к ключу в TopicRegistry. Используется когда автоматический discovery
      # не сработал (например, имя топика в TG отличается от YAML).
      def handle_learn_topic(rest)
        key = rest.to_s.strip.downcase
        thread_id = @msg['message_thread_id']

        return reply('Используйте: <code>/learn_topic apartments</code> (см. ключи в config/telegram_topics.yml). Команда работает только внутри топика.') if key.blank? || thread_id.nil?
        return reply("⚠️ Неизвестный ключ топика: <code>#{escape(key)}</code>") unless Telegram::TopicRegistry.valid_key?(key)

        tg_user = TelegramUser.find_by(tg_user_id: @msg.dig('from', 'id'))
        return reply('🚫 Только для руководителей.') unless tg_user&.is_manager?

        Telegram::TopicRegistry.record_discovery(key, thread_id)
        reply("✅ Топик <b>#{escape(Telegram::TopicRegistry.title(key))}</b> привязан к ключу <code>#{escape(key)}</code> (thread_id=#{thread_id}).")
      end

      def dm_code?
        chat_type = @msg.dig('chat', 'type')
        return false unless chat_type == 'private'

        text = @msg['text'].to_s.strip
        text.match?(CODE_REGEX)
      end

      def verify_code_in_dm
        code = @msg['text'].to_s.strip
        if Commands::Whoami.verify_code(message: @msg, code: code, client: @client)
          :verified
        else
          reply('Код неверен или истёк. Запросите новый через <code>/whoami email@victory.ru</code>.')
          :code_failed
        end
      end

      def reply(text)
        @client.send_message(
          text,
          chat_id: @msg.dig('chat', 'id'),
          reply_to_message_id: @msg['message_id'],
          message_thread_id: @msg['message_thread_id'],
          parse_mode: 'HTML'
        )
      end

      def escape(s)
        s.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
      end
    end
  end
end
