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

        # Phase 13 Iter 43 — reject если у director уже есть pending TaskBatch.
        # Иначе два неподтверждённых пакета в DM одновременно → confusion
        # «какой preview мой»; race при approve неверного.
        pending = TaskBatch.pending.where(created_by: tg_user).order(created_at: :desc).first
        return refuse_pending_batch(pending) if pending

        process_voice(tg_user, file_id)
      rescue StandardError => e
        Rails.logger.error("[VoiceIntakeProcessor] #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
        reply("⚠️ Внутренняя ошибка: #{e.message.to_s.truncate(120)}")
        :error
      end

      private

      def process_voice(tg_user, file_id)
        # Phase 10 Iter 15 — store ack message_id чтобы edit-in-place, не
        # плодить «Слушаю» + «error» как два отдельных reply.
        ack_msg = reply('🎙 Слушаю и парсю…') # ~5-15s до transcribe done
        @ack_message_id = ack_msg&.dig('message_id')

        transcription = Telegram::WorkBot::VoiceTranscriber.call(file_id: file_id)
        return transcription_failed(transcription) unless transcription.success?
        return hallucinated if transcription.hallucination?
        return too_short    if transcription.text.length < MIN_TRANSCRIPT_LENGTH
        return low_confidence(transcription) if transcription.low_confidence?

        # Iter 59 — split: query (self-audit) vs task_batch (распределение).
        # Раньше любой голос шёл через TaskExtractor — теперь вопросы про
        # себя/отчёты роутятся в StaffChatResponder (tool-loop).
        intent = Telegram::WorkBot::VoiceIntentBranch.call(transcription.text)
        if intent == :query
          return handle_query(tg_user, transcription)
        end

        extraction = Telegram::WorkBot::TaskExtractor.call(
          transcript: transcription.raw['text'].to_s, # raw для LLM (PII нужны для names)
          staff: TelegramUser.assignable.to_a,        # active + assignable=true (опт-аут админов)
          now: Time.current
        )

        return extract_failed(extraction) unless extraction.success?
        return no_tasks(extraction) if extraction.tasks.empty?

        batch = create_batch(tg_user, transcription, extraction)
        Telegram::WorkBot::TaskBatchConfirmer.new(batch: batch, client: @client).call

        # Phase 7.8b — архивация .ogg + redacted transcript в NC AUDIT-LOGS.
        # Soft-fail: NC down не блокирует основной flow. Запускаем после
        # confirmer чтобы preview отобразился без задержки на upload.
        archive_voice_to_nc(tg_user, transcription.text, batch.id)
        :dispatched
      end

      # Iter 59 — voice → query branch. Транскрипт уходит в StaffChatResponder
      # (он сам решает classify → tool-call → final answer). Edit-in-place
      # ack-сообщение «🎙 Слушаю…» на финальный ответ (UX consistency с task path).
      def handle_query(tg_user, transcription)
        result = Llm::StaffChatResponder.call(
          question: transcription.text,
          asked_by: tg_user,
          msg: @msg
        )
        text = if result.respond_to?(:success?) && result.success?
                 prefix = '🎙 ➜ 💬 '
                 suffix = result.used_tools.present? ? "\n\n<i>(#{result.used_tools.join(', ')})</i>" : ''
                 "#{prefix}#{result.answer}#{suffix}"
               else
                 "⚠️ Не удалось обработать запрос: #{result&.error.to_s.truncate(120)}"
               end
        edit_ack(text)

        # Архивируем voice-query так же как task-batch — для аудита и обучения.
        archive_voice_to_nc(tg_user, transcription.text, nil)
        :query
      end

      def archive_voice_to_nc(tg_user, redacted_transcript, task_batch_id)
        file_id = @msg.dig('voice', 'file_id')
        return if file_id.blank?

        Nextcloud::VoiceArchiver.call(
          file_id: file_id,
          transcript: redacted_transcript,
          actor: tg_user,
          task_batch_id: task_batch_id
        )
      rescue StandardError => e
        Rails.logger.warn("[VoiceIntakeProcessor#archive_voice_to_nc] #{e.class}: #{e.message}")
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

      # Phase 10 Iter 14 — PII redaction для persist'а task в jsonb.
      # title может содержать «позвонить клиенту Анна Петрова +79991234567» —
      # без redaction PII сидят в БД. related_property_address тоже маскируется.
      # JSONB hates Time objects → ISO8601.
      REDACT_KEYS = %i[title related_property_address].freeze

      def serialize_task(task)
        task.each_with_object({}) do |(k, v), h|
          v = v.iso8601 if v.is_a?(Time) || v.is_a?(Date) || v.is_a?(DateTime)
          v = Privacy::TranscriptRedactor.call(v) if REDACT_KEYS.include?(k) && v.is_a?(String)
          h[k.to_s] = v
        end
      end

      # ---- replies ----

      def reply(text)
        @client.send_message(text,
                             chat_id: @msg.dig('chat', 'id'),
                             reply_to_message_id: @msg['message_id'],
                             parse_mode: 'HTML')
      end

      # Phase 10 Iter 15 — edit-in-place вместо нового reply. Если ack_message_id
      # есть — обновляем «🎙 Слушаю…» на result. Иначе fallback на reply.
      # Используется ТОЛЬКО для error paths (transcription_failed/hallucinated/
      # low_confidence/extract_failed/no_tasks). Success path уже отрабатывает
      # через TaskBatchConfirmer preview — отдельное сообщение.
      def edit_ack(text)
        return reply(text) if @ack_message_id.blank?

        @client.edit_message_text(text,
                                  chat_id: @msg.dig('chat', 'id'),
                                  message_id: @ack_message_id,
                                  parse_mode: 'HTML')
      rescue Telegram::Client::Error => e
        Rails.logger.warn("[VoiceIntakeProcessor] edit_ack failed, fallback to reply: #{e.message}")
        reply(text)
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

      # Phase 13 Iter 43 — отказ при уже существующем pending TaskBatch.
      # Auto-cancel предыдущего опасен (потеря заметок) — поэтому делаем
      # explicit reject + inline-кнопка [✖️ Отменить старый] (Phase 14 Iter 56)
      # для one-click cancel без скролла истории к preview.
      def refuse_pending_batch(pending)
        age_min = ((Time.current - pending.created_at) / 60).to_i
        text = "🚫 У вас есть недоподтверждённый пакет <b>##{pending.id}</b> (создан #{age_min}мин назад). " \
               "Подтверди или отмени его в DM (через inline-кнопки preview), затем повтори голосовое. " \
               "Если preview потерялся — используй <code>/resume_batch #{pending.id}</code>."

        # Phase 14 Iter 56 — inline-кнопка для быстрой отмены прежнего batch.
        # callback_data reuses TaskBatchConfirmCallback prefix 'batch_confirm:'
        # — он уже умеет :cancel. Director кликает → batch.cancel! → может
        # сразу записать новый voice. UX one-click вместо ручного поиска preview.
        markup = {
          inline_keyboard: [
            [{ text: "✖️ Отменить старый ##{pending.id} и попробовать снова",
               callback_data: "batch_confirm:#{pending.id}:cancel" }]
          ]
        }

        @client.send_message(text,
                             chat_id: @msg.dig('chat', 'id'),
                             reply_to_message_id: @msg['message_id'],
                             parse_mode: 'HTML',
                             reply_markup: markup)
        Rails.logger.info("[VoiceIntakeProcessor] refused new voice — pending batch ##{pending.id}")
        :refused_pending
      end

      def transcription_failed(t)
        edit_ack("⚠️ Не удалось распознать голос: #{t.error.to_s.truncate(120)}")
        :transcribe_failed
      end

      def hallucinated
        edit_ack('⚠️ Распознанный текст похож на шум/тишину (типовая Whisper-галлюцинация). ' \
                 'Попробуй ещё раз, держи микрофон ближе.')
        :hallucinated
      end

      def too_short
        edit_ack('⚠️ Сообщение слишком короткое для распределения. Произнеси задачи целиком.')
        :transcript_too_short
      end

      def low_confidence(t)
        edit_ack("⚠️ Низкая уверенность распознавания (confidence=#{t.confidence.to_s.truncate(8)}). " \
                 'Повтори чётче или напиши текстом.')
        :low_confidence
      end

      def extract_failed(e)
        edit_ack("⚠️ Не удалось распарсить задачи: #{e.error.to_s.truncate(120)}")
        :extract_failed
      end

      def no_tasks(e)
        msg = '⚠️ LLM не нашёл задач в сообщении.'
        msg += "\nУточнения: #{e.uncertainties.join('; ')}" if e.uncertainties.any?
        edit_ack(msg)
        :no_tasks
      end
    end
  end
end
