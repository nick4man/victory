# frozen_string_literal: true

module Telegram
  module ClientBot
    # Phase 4D — Orchestrator для inbound client text-messages в DM боту.
    # Триггер: InboundProcessor → applies?(msg) → TextIntakeProcessor.call(msg)
    #
    # Conditions для apply (см. .applies?):
    #   • chat.type == 'private' (DM, не group)
    #   • not staff (TelegramUser does not exist)
    #   • message.text present (не photo/voice/sticker — те routes separately)
    #   • не /команда (commands route через WorkBot::Router)
    #
    # Flow:
    #   1. Rate-limit check (Redis counter — 10 msg/hour per tg_user_id)
    #   2. IntentClassifier (free-chain LLM) → intent + confidence
    #   3. Branch:
    #      • spam/abuse → silently drop + counter в health metric
    #      • test → soft reply «Здравствуйте! Опишите задачу — что хотите найти?»
    #      • unclear (confidence < 0.5) → same soft reply
    #      • inquiry/question/appointment → Lead::Intake.call(source: 'tg_dm')
    #        → LeadAnnouncer → anchor в #ДИСПЕТЧЕРСКОЙ + reply клиенту
    #
    # Privacy: Privacy::TranscriptRedactor применяется к stored text (PII-mask).
    # IntentClassifier гет's raw text (LLM не сохраняет; cost economy).
    class TextIntakeProcessor
      RATE_LIMIT_PER_HOUR = 10
      SPAM_COUNTER_KEY = 'client_intake:spam_24h'

      def self.applies?(msg)
        return false unless msg.is_a?(Hash)
        return false unless msg.dig('chat', 'type') == 'private'

        text = msg['text'].to_s.strip
        return false if text.empty? || text.start_with?('/')

        from_id = msg.dig('from', 'id')
        return false if from_id.blank?
        return false if msg.dig('from', 'is_bot')

        # Если уже staff — пропускаем (WorkBot::Router обработает)
        !TelegramUser.exists?(tg_user_id: from_id)
      end

      def self.call(msg)
        new(msg).call
      end

      def initialize(msg, client: ::Telegram::Client.new)
        @msg = msg
        @client = client
      end

      def call
        from_id = @msg.dig('from', 'id')

        # Rate-limit per tg_user_id (Redis 1h sliding counter)
        return rate_limited(from_id) if rate_limit_exceeded?(from_id)

        text = @msg['text'].to_s.strip

        sender_ctx = {
          first_message_in_chat: Inquiry.where(client_tg_user_id: from_id).none?,
          prior_inquiries_count: Inquiry.where(client_tg_user_id: from_id).count
        }
        classification = ::Llm::IntentClassifier.call(text: text, sender_context: sender_ctx)

        log_classification(from_id, classification, text)

        if classification.droppable?
          increment_spam_counter
          return :dropped_spam
        end

        if classification.intent == 'test' || classification.confidence < 0.5
          return soft_greeting(from_id)
        end

        return :ignored unless classification.actionable?

        process_intake(text, classification)
      rescue StandardError => e
        Rails.logger.error("[ClientBot::TextIntakeProcessor] #{e.class}: #{e.message}\n#{e.backtrace.first(3).join("\n")}")
        :error
      end

      private

      def process_intake(text, classification)
        from = @msg['from'] || {}
        chat = @msg['chat'] || {}

        # PII-redact для persisted text (Phase 7.7 reuse)
        redacted = ::Privacy::TranscriptRedactor.call(text)

        payload = {
          text: redacted,
          tg_user_id: from['id'],
          tg_username: from['username'],
          first_name: from['first_name'],
          last_name: from['last_name'],
          dm_chat_id: chat['id'],
          intent: classification.intent,
          intent_confidence: classification.confidence,
          intent_reasoning: classification.reasoning
        }

        result = ::Lead::Intake.call(source: 'tg_dm', payload: payload)

        if result.is_a?(Hash) && result[:lead_event]
          confirm_intake_to_client(result[:lead_event], classification)
          :announced
        else
          Rails.logger.warn("[ClientBot::TextIntakeProcessor] Lead::Intake returned #{result.inspect.to_s.truncate(120)}")
          :intake_failed
        end
      end

      def confirm_intake_to_client(lead_event, classification)
        meta = lead_event.metadata || {}
        text = if meta['returning_client']
                 "👋 Спасибо, что вернулись! Передал агенту — он скоро ответит."
               else
                 reply_text_for(classification.intent)
               end
        @client.send_message(text,
                             chat_id: @msg.dig('chat', 'id'),
                             reply_to_message_id: @msg['message_id'])
      rescue ::Telegram::Client::Error => e
        Rails.logger.warn("[ClientBot::TextIntakeProcessor] reply failed: #{e.message}")
      end

      def reply_text_for(intent)
        case intent
        when 'appointment'
          '📅 Принято! Передал агенту — он свяжется чтобы согласовать время.'
        when 'question'
          '💬 Спасибо за вопрос! Передал агенту — он скоро ответит.'
        else # inquiry
          '✅ Заявка принята! Агент свяжется с вами в течение часа.'
        end
      end

      def soft_greeting(from_id)
        text = 'Здравствуйте! Я бот АН «Виктори» — могу помочь с подбором, оценкой или вопросом по сделке. ' \
               'Опишите кратко что ищете (тип объекта, район, бюджет) — передам агенту.'
        @client.send_message(text,
                             chat_id: @msg.dig('chat', 'id'),
                             reply_to_message_id: @msg['message_id'])
        :soft_greeting
      rescue ::Telegram::Client::Error => e
        Rails.logger.warn("[ClientBot::TextIntakeProcessor] soft_greeting failed: #{e.message}")
        :error
      end

      def rate_limit_exceeded?(tg_user_id)
        return false if tg_user_id.blank?
        return false unless (redis = redis_connection)

        key = "client_intake:rate:#{tg_user_id}"
        count = redis.incr(key)
        redis.expire(key, 3600) if count == 1
        count > RATE_LIMIT_PER_HOUR
      rescue StandardError => e
        Rails.logger.warn("[TextIntakeProcessor] rate limit redis error: #{e.message}")
        false # fail-open
      end

      def rate_limited(from_id)
        Rails.logger.info("[ClientBot::TextIntakeProcessor] rate-limited tg_user_id=#{from_id}")
        @client.send_message(
          '⚠️ Слишком много сообщений за час. Подождите немного — агент скоро ответит.',
          chat_id: @msg.dig('chat', 'id'),
          reply_to_message_id: @msg['message_id']
        )
        :rate_limited
      rescue ::Telegram::Client::Error => e
        Rails.logger.warn("[ClientBot::TextIntakeProcessor] rate_limited reply failed: #{e.message}")
        :rate_limited
      end

      def increment_spam_counter
        return unless (redis = redis_connection)

        redis.incr(SPAM_COUNTER_KEY)
        redis.expire(SPAM_COUNTER_KEY, 86_400) # 24h rolling
      rescue StandardError => e
        Rails.logger.warn("[TextIntakeProcessor] spam_counter redis: #{e.message}")
      end

      def log_classification(tg_user_id, classification, text)
        Rails.logger.info(
          "[ClientBot::TextIntakeProcessor] tg_user_id=#{tg_user_id} " \
          "intent=#{classification.intent} conf=#{classification.confidence} " \
          "model=#{classification.model} text=#{text.to_s.truncate(60).inspect}"
        )
      end

      def redis_connection
        @redis ||= begin
          url = ENV['REDIS_URL'].presence || 'redis://redis:6379/0'
          require 'redis' unless defined?(Redis)
          Redis.new(url: url)
        rescue StandardError
          nil
        end
      end
    end
  end
end
