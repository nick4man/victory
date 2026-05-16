# frozen_string_literal: true

module Telegram
  # Parses an inbound Telegram webhook update. The two paths we care about:
  #
  # 1. Reply-to-bot:
  #    Staff member long-presses one of our escalation messages and replies.
  #    update.message.reply_to_message.message_id matches Conversation.telegram_message_id
  #    → save ChatMessage(role: :agent), broadcast to widget.
  #
  # 2. Slash commands inside a conversation thread:
  #    /close, /assign — operate on the matched conversation.
  #
  # Anything else is logged and ignored (silent ack so Telegram doesn't retry).
  class InboundProcessor
    def initialize(payload)
      @update = if payload.is_a?(Hash)
                  payload
                else
                  begin
                    JSON.parse(payload.to_s)
                  rescue StandardError
                    {}
                  end
                end
    end

    def call
      # Phase 2 — callback_query от inline-кнопок маршрутизации/назначения/спама.
      # Должен сработать ДО разбора message — это отдельный тип апдейта без message.
      if (cb = @update['callback_query'])
        return Telegram::WorkBot::CallbacksRouter.new(cb).call
      end

      # Phase 3 — реакции 👍/🔥/✅ на якорь = «принято в работу» (комплементарный
      # сигнал для SLA-watchdog наравне с note в CRM). Требует расширенного
      # allowed_updates через `bin/rails telegram:webhook:setup`.
      if (rx = @update['message_reaction'])
        return Telegram::ReactionHandler.new(rx).call
      end

      msg = @update['message'] || @update['edited_message']
      return :ignored unless msg

      # Discovery топиков рабочей группы — пассивно: смотрим каждое сообщение,
      # которое прилетает с message_thread_id, и сохраняем маппинг key → thread_id
      # если по имени удалось определить топик. См. TopicDiscovery.
      Telegram::WorkBot::TopicDiscovery.maybe_record(msg)

      # Рабочий бот: команды в работчей группе или DM от привязанного сотрудника.
      # Router сам решает что обрабатывать (см. WorkBot::Router#call).
      workbot_result = Telegram::WorkBot::Router.new(msg).call

      # Phase 2 — хэштеги в сообщениях рабочей группы (только #ахтунг). Не блокирует
      # дальнейшую обработку — это side-effect handler. Хэштеги вне группы (DM) игнорируем.
      if msg.dig('chat', 'type') == 'supergroup' && msg['text'].to_s.match?(/#ахтунг/i)
        Telegram::WorkBot::HashtagHandler.new(msg).call
      end

      # Phase 2 hotfix — auto-discovery TG-юзеров в рабочей группе. При первом
      # сообщении от незарегистрированного создаётся TelegramUser(inactive) +
      # DM manager'у с просьбой активировать через /promote.
      if msg.dig('chat', 'type') == 'supergroup'
        Telegram::WorkBot::AutoDiscovery.new(msg).call
      end

      return workbot_result if [:handled, :verified, :code_failed].include?(workbot_result)

      # Inbox saver — enqueued, NOT synchronous. Telegram disconnects the
      # webhook after ~5s, and large photo/document downloads from
      # api.telegram.org easily blow past that. The job does the actual
      # save work; the webhook always returns 200 in milliseconds.
      TelegramInboxSaveJob.perform_later(msg) if Telegram::InboxSaver.whitelisted?(msg)

      reply_to_id = msg.dig('reply_to_message', 'message_id')
      return log_and_ignore('no reply_to_message_id') if reply_to_id.blank?

      conv = Conversation.find_by(telegram_message_id: reply_to_id)
      return log_and_ignore("no conversation for tg_message_id=#{reply_to_id}") unless conv

      text = msg['text'].to_s.strip
      return :ignored if text.empty?

      return handle_command(conv, text, msg) if text.start_with?('/')

      handle_reply(conv, text, msg)
      :delivered
    rescue StandardError => e
      Rails.logger.error("[Telegram::InboundProcessor] #{e.class} #{e.message}")
      :error
    end

    private

    def handle_reply(conv, text, msg)
      author = resolve_author(msg)

      message = ChatMessage.create!(
        conversation: conv,
        role: :agent,
        body: text,
        author: author,
        telegram_message_id: msg['message_id']
      )

      ConversationChannel.broadcast_to(conv,
                                       type: 'message',
                                       message: serialize(message))

      Rails.logger.info("[Telegram] agent reply ##{message.id} on conversation ##{conv.id}")
    end

    def handle_command(conv, text, _msg)
      cmd, *_args = text.split(/\s+/, 2)
      case cmd.downcase
      when '/close'
        conv.update(status: :closed)
        ChatMessage.create!(conversation: conv, role: :system,
                            body: 'Диалог закрыт сотрудником.')
        ConversationChannel.broadcast_to(conv, type: 'closed')
        :closed
      else
        log_and_ignore("unknown command #{cmd}")
      end
    end

    # Telegram users have no link to our User table by default. We fall back
    # to looking up by username if it matches a User#email prefix; otherwise
    # author stays nil and we record the Telegram username in metadata.
    def resolve_author(msg)
      from = msg['from'] || {}
      username = from['username'].to_s
      return nil if username.blank?

      User.where('LOWER(email) LIKE ?', "#{username.downcase}@%").first
    end

    def serialize(m)
      {
        id: m.id,
        role: m.role,
        body: m.body,
        author: m.author&.short_name,
        created_at: m.created_at.iso8601
      }
    end

    def log_and_ignore(reason)
      Rails.logger.info("[Telegram::InboundProcessor] ignored: #{reason}")
      :ignored
    end
  end
end
