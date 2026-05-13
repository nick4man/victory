# frozen_string_literal: true

require 'yaml'

module Telegram
  # Реестр Telegram-топиков рабочего чата АН «Виктори».
  #
  # Источник данных: config/telegram_topics.yml. После Phase 0 discovery
  # message_thread_id заполняется автоматически. Для записей с не-заполненным
  # thread_id `for(key)` возвращает nil — вызывающий код должен это учитывать
  # (например, `LeadAnnouncer` пропускает публикацию, если #ДИСПЕТЧЕРСКАЯ ещё
  # не обнаружена, и пишет warning в логи).
  #
  # Также хранит обнаруженные при runtime thread_id в Rails.cache —
  # `record_discovery(thread_id, title)` находит ключ по `tg_title` и обновляет
  # YAML без перезапуска приложения.
  class TopicRegistry
    CONFIG_PATH = Rails.root.join('config/telegram_topics.yml').freeze
    CACHE_KEY   = 'telegram:topic_registry:overrides'

    class << self
      def chat_id
        config.fetch(:chat_id).to_i
      end

      # @return [Integer, nil] message_thread_id или nil если ещё не известен
      def thread_id(key)
        key = key.to_s
        return nil unless valid_key?(key)
        overrides[key] || config.dig(:topics, key.to_sym, :message_thread_id)
      end

      # @return [String, nil] человекочитаемое название топика
      def title(key)
        config.dig(:topics, key.to_sym, :tg_title)
      end

      def role(key)
        config.dig(:topics, key.to_sym, :role)
      end

      def bot_writes?(key)
        config.dig(:topics, key.to_sym, :bot_writes) != false
      end

      def bot_reacts?(key)
        config.dig(:topics, key.to_sym, :bot_reacts) != false
      end

      # General-топик (корневой) форум-группы — у него нет message_thread_id,
      # сообщение пишется в группу без указания thread_id.
      def general_topic?(key)
        config.dig(:topics, key.to_sym, :is_general_topic) == true
      end

      def all_keys
        config.fetch(:topics).keys.map(&:to_s)
      end

      def anchor_keys
        config.fetch(:topics).select { |_, t| t[:role] == 'anchor' }.keys.map(&:to_s)
      end

      def routing_buttons
        config.fetch(:routing_buttons, []).map(&:to_s)
      end

      # @return [String, nil] anchor_topic_key, для которого данный source
      # в YAML указан в auto_route_from. nil — нет автомаршрута.
      def auto_route_for(source)
        return nil if source.blank?
        config.fetch(:topics).each do |key, attrs|
          sources = Array(attrs[:auto_route_from]).map(&:to_s)
          return key.to_s if sources.include?(source.to_s)
        end
        nil
      end

      def valid_key?(key)
        all_keys.include?(key.to_s)
      end

      # Найти ключ по русскому названию топика (для discovery из webhook).
      def key_by_title(title)
        return nil if title.blank?
        normalized = title.to_s.strip.upcase
        config.fetch(:topics).each do |key, attrs|
          return key.to_s if attrs[:tg_title].to_s.strip.upcase == normalized
        end
        nil
      end

      # Зафиксировать обнаруженный thread_id для топика.
      # Источники: forum_topic_created event, message в топике с известным title,
      # или ручная команда /learn_topic.
      def record_discovery(key, thread_id)
        return false unless valid_key?(key)
        return false if thread_id.blank?
        store = (Rails.cache.read(CACHE_KEY) || {}).merge(key.to_s => thread_id.to_i)
        Rails.cache.write(CACHE_KEY, store)
        Rails.logger.info("[TopicRegistry] discovered #{key} → thread_id=#{thread_id}")
        true
      end

      def discovered
        Rails.cache.read(CACHE_KEY) || {}
      end

      # Diagnostic: какие ключи ещё без thread_id.
      # General-топики (is_general_topic: true) исключаются — для них thread_id
      # законно nil (сообщения пишутся в корень группы).
      def missing_keys
        all_keys.reject { |k| thread_id(k) || general_topic?(k) }
      end

      # Сброс памяти процесса (тесты + после ручного редактирования YAML).
      def reload!
        @config = nil
        Rails.cache.delete(CACHE_KEY)
      end

      private

      def overrides
        Rails.cache.read(CACHE_KEY) || {}
      end

      def config
        @config ||= YAML.safe_load_file(CONFIG_PATH, symbolize_names: true, permitted_classes: [Symbol])
      end
    end
  end
end
