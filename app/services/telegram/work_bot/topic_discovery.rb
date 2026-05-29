# frozen_string_literal: true

module Telegram
  module WorkBot
    # Собирает соответствие topic_key ↔ message_thread_id из webhook-сообщений.
    # Telegram Bot API не имеет метода getForumTopics, поэтому единственный путь —
    # «увидеть» каждый топик через одно из событий:
    #
    #   1. `message.forum_topic_created` — приходит при создании топика
    #      (только если бот в группе на момент создания, и подписан на 'message').
    #      Содержит forum_topic_created.name + сообщение это и есть маркер с
    #      message_thread_id = message_id.
    #
    #   2. `message.message_thread_id` + `message.reply_to_message.forum_topic_created` —
    #      когда любое сообщение приходит внутри существующего топика, первое
    #      такое сообщение часто включает reply на маркер-создатель с именем.
    #
    #   3. `message.message_thread_id` без имени — fallback, имя достаём
    #      синхронно через getChat если бот админ; иначе нужен /learn_topic.
    #
    # Команда `/learn_topic <topic_key>` (только для is_manager) — ручная
    # привязка thread_id текущего топика к нашему ключу: используется когда
    # автоматический матчинг по имени не сработал (например, имя в TG отличается
    # от tg_title в YAML).
    class TopicDiscovery
      WORK_CHAT_ID = -1_003_779_115_845

      def self.maybe_record(message)
        return unless message.is_a?(Hash)
        return unless message.dig('chat', 'id') == WORK_CHAT_ID

        thread_id = message['message_thread_id']
        return unless thread_id

        title = extract_title(message)
        if title.present?
          key = Telegram::TopicRegistry.key_by_title(title)
          if key
            Telegram::TopicRegistry.record_discovery(key, thread_id)
          else
            Rails.logger.warn("[TopicDiscovery] unknown title '#{title}' for thread_id=#{thread_id}")
          end
        else
          Rails.logger.debug("[TopicDiscovery] message in thread_id=#{thread_id} without title hint")
        end
      end

      # Имя топика приходит в трёх местах:
      #   1. message.forum_topic_created.name (само сообщение — service marker)
      #   2. message.reply_to_message.forum_topic_created.name (реплай на маркер)
      #   3. message.forum_topic_edited.name (если редактировали имя)
      def self.extract_title(msg)
        msg.dig('forum_topic_created', 'name') ||
          msg.dig('reply_to_message', 'forum_topic_created', 'name') ||
          msg.dig('forum_topic_edited', 'name')
      end
    end
  end
end
