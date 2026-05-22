# frozen_string_literal: true

module Telegram
  module WorkBot
    # Iter 59 — разделение голосовых сообщений Оксаны на два типа intent'а:
    #
    #   :task_batch — поручение другому сотруднику («передай Ирине: позвони…»)
    #                 → текущий pipeline (TaskExtractor → TaskBatch → preview)
    #   :query      — вопрос про себя / отчёт / аудит («какие лиды я направила
    #                 сегодня?», «сколько у меня открытых задач?»)
    #                 → перенаправление в Llm::StaffChatResponder (tool-loop)
    #
    # До Iter 59 VoiceIntakeProcessor предполагал ВСЕГДА task_batch — любой
    # запрос вида «покажи мне X» становился фейковой задачей с непонятным
    # assignee. Этот сервис отделяет ветки на самом раннем этапе.
    #
    # Algorithm: одна LLM-call в :staff_analysis chain (cheap-first), JSON-mode,
    # с двумя классами + confidence. Если confidence < 0.7 — fallback на
    # task_batch (safer default, иначе обычная задача попадёт в StaffChatResponder
    # и потеряется). Любая LLM-ошибка → также task_batch.
    #
    # @example
    #   VoiceIntentBranch.call('Васе позвонить клиенту Анне')
    #   # => :task_batch
    #   VoiceIntentBranch.call('Какие задания я давала сегодня?')
    #   # => :query
    class VoiceIntentBranch
      CONFIDENCE_THRESHOLD = 0.7

      SYSTEM_PROMPT = <<~SYS.strip
        Ты классифицируешь голосовые сообщения сотрудников агентства недвижимости.
        Сообщение приходит от руководителя (директора) в личной переписке с ботом.

        Верни JSON ровно вида:
          {"kind": "query"|"task_batch", "confidence": <0.0..1.0>}

        query — вопрос/отчёт/аудит о собственной работе или о фактах в системе.
        Примеры query:
          • "какие лиды я сегодня направила в рабочий чат"
          • "покажи мои задания на неделе"
          • "сколько у меня открытых лидов"
          • "какие задачи я давала Ирине вчера"
          • "сколько сделок в этом месяце"

        task_batch — поручение конкретному сотруднику или нескольким (распределение
        задач голосом, которое затем превратится в задачи в системе).
        Примеры task_batch:
          • "Ирине: позвонить Анне до 16:00"
          • "Серёге показать квартиру на Ленина в пятницу"
          • "Маша, подготовь договор по сделке #87"

        Если непонятно или 50/50 — выставляй confidence < 0.7 и любой kind.
        Caller интерпретирует низкий confidence как task_batch (safer default).

        ВЕРНИ ТОЛЬКО JSON, без markdown-обёртки.
      SYS

      def self.call(transcript, client: Llm::OmniClient.new)
        new(transcript, client: client).call
      end

      def initialize(transcript, client: Llm::OmniClient.new)
        @transcript = transcript.to_s.strip
        @client     = client
      end

      # @return [Symbol] :query или :task_batch
      def call
        return :task_batch if @transcript.empty?

        res = @client.complete(
          [
            { role: 'system', content: SYSTEM_PROMPT },
            { role: 'user',   content: @transcript }
          ],
          chain: :staff_analysis,
          response_format: { type: 'json_object' },
          temperature: 0.1,
          max_tokens: 80
        )

        parsed = JSON.parse(res[:content].to_s)
        kind = parsed['kind'].to_s
        conf = parsed['confidence'].to_f

        if kind == 'query' && conf >= CONFIDENCE_THRESHOLD
          Rails.logger.info("[VoiceIntentBranch] kind=query confidence=#{conf} transcript=#{@transcript.truncate(80).inspect}")
          :query
        else
          Rails.logger.info("[VoiceIntentBranch] kind=task_batch confidence=#{conf} llm_kind=#{kind.inspect}")
          :task_batch
        end
      rescue StandardError => e
        Rails.logger.warn("[VoiceIntentBranch] fallback to task_batch: #{e.class} #{e.message}")
        :task_batch
      end
    end
  end
end
