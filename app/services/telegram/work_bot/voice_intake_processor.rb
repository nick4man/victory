# frozen_string_literal: true

module Telegram
  module WorkBot
    # Phase 7.2 — Pipeline для voice-сообщений от директора АН в DM боту:
    #
    #   1. Авторизация: msg.chat.type=private + tg_user.can_voice_distribute?
    #   2. VoiceTranscriber (Groq Whisper) → text + hallucination check + DLP
    #   3. TaskExtractor (Llm::OmniClient :analysis) → структурированные tasks
    #   4. TaskBatch.create! + parsed_payload
    #   5. TaskBatchConfirmer → preview message с inline-кнопками
    #
    # Возвращает символ-статус: :dispatched / :refused / :transcribe_failed /
    # :no_tasks / :transcript_too_short.
    #
    # Не блокирует основной flow InboundProcessor — это side-effect handler.
    # Все ошибки логируются + reply'ятся пользователю.
    class VoiceIntakeProcessor
      MIN_TRANSCRIPT_LENGTH = 6 # минимум для попытки extract'а (короче — мусор)

      def self.applies?(msg)
        msg.is_a?(Hash) && msg['voice'].is_a?(Hash) && msg.dig('chat', 'type') == 'private'
      end

      def initialize(msg, client: Telegram::Client.new)
        @msg    = msg
        @client = client
      end

      def call
        from_id = @msg.dig('from', 'id')
        tg_user = TelegramUser.find_by(tg_user_id: from_id)

        return refuse_unregistered(from_id) if tg_user.nil?
        return refuse_non_director(tg_user) unless tg_user.can_voice_distribute?

        file_id = @msg.dig('voice', 'file_id')
        return reply('⚠️ Не вижу file_id в voice payload — TG-баг?') if file_id.blank?

        process_voice(tg_user, file_id)
      rescue StandardError => e
        Rails.logger.error("[VoiceIntakeProcessor] #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
        reply("⚠️ Внутренняя ошибка: #{e.message.to_s.truncate(120)}")
        :error
      end

      private

      def process_voice(tg_user, file_id)
        reply('🎙 Слушаю и парсю…') # quick ack — Whisper занимает 5-15 сек

        transcription = Telegram::WorkBot::VoiceTranscriber.call(file_id: file_id)
        return transcription_failed(transcription) unless transcription.success?
        return hallucinated if transcription.hallucination?
        return too_short    if transcription.text.length < MIN_TRANSCRIPT_LENGTH
        return low_confidence(transcription) if transcription.low_confidence?

        extraction = Telegram::WorkBot::TaskExtractor.call(
          transcript: transcription.raw['text'].to_s, # raw для LLM (PII нужны для names)
          staff: TelegramUser.assignable.to_a,        # active + assignable=true (опт-аут админов)
          now: Time.current
        )

        return extract_failed(extraction) unless extraction.success?
        return no_tasks(extraction) if extraction.tasks.empty?

        batch = create_batch(tg_user, transcription, extraction)
        Telegram::WorkBot::TaskBatchConfirmer.new(batch: batch, client: @client).call
        :dispatched
      end

      def create_batch(tg_user, transcription, extraction)
        TaskBatch.create!(
          created_by: tg_user,
          source: 'voice',
          status: 'pending_confirm',
          transcript_redacted: transcription.text, # text уже redacted (Phase 7.7)
          parsed_payload: {
            'tasks' => extraction.tasks.map { |t| serialize_task(t) },
            'uncertainties' => extraction.uncertainties,
            'model' => extraction.model,
            'transcribed_at' => Time.current.iso8601,
            'duration_sec' => transcription.duration_sec,
            'voice_confidence' => transcription.confidence
          }
        )
      end

      # JSONB hates Time objects → конвертим datetime'ы в ISO8601, остальное
      # оставляем как есть. Symbol keys → strings.
      def serialize_task(task)
        task.each_with_object({}) do |(k, v), h|
          h[k.to_s] = v.is_a?(Time) || v.is_a?(Date) || v.is_a?(DateTime) ? v.iso8601 : v
        end
      end

      # ---- replies ----

      def reply(text)
        @client.send_message(text,
                             chat_id: @msg.dig('chat', 'id'),
                             reply_to_message_id: @msg['message_id'],
                             parse_mode: 'HTML')
      end

      def refuse_unregistered(from_id)
        reply('🚫 Голосовое распределение доступно только сотрудникам АН. ' \
              'Напиши /whoami email@victory.ru.')
        Rails.logger.info("[VoiceIntakeProcessor] unregistered tg_user_id=#{from_id}")
        :refused
      end

      def refuse_non_director(_tg_user)
        reply('🚫 Только директор АН распределяет задачи голосом. ' \
              'Используй <code>/task @username dd.MM.yy &lt;текст&gt;</code> для одиночной.')
        :refused
      end

      def transcription_failed(t)
        reply("⚠️ Не удалось распознать голос: #{t.error.to_s.truncate(120)}")
        :transcribe_failed
      end

      def hallucinated
        reply('⚠️ Распознанный текст похож на шум/тишину (типовая Whisper-галлюцинация). ' \
              'Попробуй ещё раз, держи микрофон ближе.')
        :hallucinated
      end

      def too_short
        reply('⚠️ Сообщение слишком короткое для распределения. Произнеси задачи целиком.')
        :transcript_too_short
      end

      def low_confidence(t)
        reply("⚠️ Низкая уверенность распознавания (confidence=#{t.confidence.to_s.truncate(8)}). " \
              'Повтори чётче или напиши текстом.')
        :low_confidence
      end

      def extract_failed(e)
        reply("⚠️ Не удалось распарсить задачи: #{e.error.to_s.truncate(120)}")
        :extract_failed
      end

      def no_tasks(e)
        msg = '⚠️ LLM не нашёл задач в сообщении.'
        msg += "\nУточнения: #{e.uncertainties.join('; ')}" if e.uncertainties.any?
        reply(msg)
        :no_tasks
      end
    end
  end
end
