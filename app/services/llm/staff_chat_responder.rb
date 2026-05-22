# frozen_string_literal: true

module Llm
  # Phase 7.5 — Orchestrator для вопросов в #ВОПРОС/ОТВЕТ топике.
  #
  # Flow:
  #   1. Llm::QuestionClassifier → kind (clarification/information/escalation)
  #   2. Если kind=escalation → ping Оксаны (DM + @mention в qna) + save question
  #   3. Иначе — OmniClient :chat с ChatTools::Staff::Registry tools.
  #      Tool-use loop: LLM → tool_call → execute → tool result → LLM → ... → final
  #   4. Save StaffQuestion record (для KPI dependency metric)
  #   5. Return {answer:, kind:, used_tools:, model:}
  #
  # Security boundary: используется ТОЛЬКО для staff (chat=qna topic в supergroup
  # с whitelisted bot_id). НЕ должен быть доступен клиентскому чатботу.
  #
  # @example
  #   r = Llm::StaffChatResponder.call(
  #     question: 'Какие у меня задачи на завтра?',
  #     asked_by: tg_user_petrov,
  #     msg: tg_message_payload
  #   )
  #   r.answer       # => "Завтра у тебя 3 задачи: ..."
  #   r.kind         # => "clarification"
  #   r.used_tools   # => ["list_my_open_tasks"]
  class StaffChatResponder
    MAX_TOOL_ITERATIONS = 4 # cap loop — обычно достаточно 1-2 вызовов tools

    Result = Struct.new(:answer, :kind, :used_tools, :model, :record, :error,
                        keyword_init: true) do
      def success? = error.nil?
    end

    def self.call(...)
      new(...).call
    end

    def initialize(question:, asked_by:, msg: {}, client: Llm::OmniClient.new,
                   tg_client: Telegram::Client.new)
      @question  = question.to_s.strip
      @asked_by  = asked_by
      @msg       = msg
      @client    = client
      @tg_client = tg_client
    end

    def call
      return empty_result('пустой вопрос') if @question.empty?

      classification = Llm::QuestionClassifier.call(question_text: @question, client: @client)

      if classification.kind == 'escalation'
        handle_escalation(classification)
      else
        handle_with_tools(classification)
      end
    rescue StandardError => e
      Rails.logger.error("[StaffChatResponder] #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
      empty_result(e.message)
    end

    private

    # --- Escalation path ---

    def handle_escalation(classification)
      manager = pick_manager
      ping_manager(manager) if manager
      answer = build_escalation_reply(manager)
      record = persist_question(classification, answer: answer, used_tools: [],
                                                escalated_to: manager, model: classification.model)
      Result.new(answer: answer, kind: 'escalation', used_tools: [],
                 model: classification.model, record: record, error: nil)
    end

    def pick_manager
      TelegramUser.directors.active.first ||
        TelegramUser.managers.active.first
    end

    def ping_manager(manager)
      chat_id = manager.dm_chat_id || manager.tg_user_id
      return if chat_id.blank?

      asker = @asked_by.mention
      text  = "🚨 <b>Эскалация в #ВОПРОС-ОТВЕТ</b>\n" \
              "От: #{escape(asker)}\n" \
              "Вопрос: <i>#{escape(@question.truncate(400))}</i>\n\n" \
              '<i>Бот пометил как escalation — нужен живой ответ.</i>'
      @tg_client.send_message(text, chat_id: chat_id, parse_mode: 'HTML')
    rescue Telegram::Client::Error => e
      Rails.logger.warn("[StaffChatResponder] manager ping failed: #{e.message}")
    end

    def build_escalation_reply(manager)
      mention = manager&.mention || 'руководитель'
      "🚨 Это нужно решать живьём — #{mention} получил уведомление. " \
        'Если срочно — позвони/напиши напрямую.'
    end

    # --- Tool-use path ---

    def handle_with_tools(classification)
      messages = [
        { role: 'system', content: system_prompt },
        { role: 'user',   content: @question }
      ]

      used_tools = []
      final_content = nil
      final_model   = nil
      tools = ChatTools::Staff::Registry.schemas

      MAX_TOOL_ITERATIONS.times do
        res = @client.complete(messages, chain: :chat, tools: tools, max_tokens: 800,
                                         temperature: 0.4)
        final_model = res[:model]

        if res[:tool_calls].present?
          handle_tool_calls(res[:tool_calls], messages, used_tools)
        else
          final_content = res[:content].to_s.strip
          break
        end
      end

      final_content ||= '(модель не дала финальный ответ после нескольких tool-вызовов)'
      record = persist_question(classification, answer: final_content,
                                                used_tools: used_tools, model: final_model)
      Result.new(answer: final_content, kind: classification.kind, used_tools: used_tools,
                 model: final_model, record: record, error: nil)
    end

    def handle_tool_calls(tool_calls, messages, used_tools)
      messages << {
        role: 'assistant',
        content: nil,
        tool_calls: tool_calls.map do |tc|
          {
            id: tc[:id], type: 'function',
            function: { name: tc[:name], arguments: JSON.generate(tc[:arguments] || {}) }
          }
        end
      }

      tool_calls.each do |tc|
        used_tools << tc[:name]
        # Iter 59 — пробрасываем asked_by для tools которым нужен caller-context
        # (например director_self_audit для role-check). Registry sniff'ит сигнатуру
        # и подаёт kwarg только если handler его принимает.
        result = ChatTools::Staff::Registry.call(tc[:name], tc[:arguments] || {}, asked_by: @asked_by)
        messages << {
          role: 'tool',
          tool_call_id: tc[:id],
          name: tc[:name],
          content: JSON.generate(result)
        }
      end
    end

    # --- Persistence ---

    def persist_question(classification, answer:, used_tools:, model:, escalated_to: nil)
      record = StaffQuestion.create!(
        asked_by: @asked_by,
        kind: classification.kind,
        question_text: @question,
        answer_text: answer,
        answered_by_id: nil, # bot, не человек
        escalated_to_id: escalated_to&.id,
        tg_message_id: @msg['message_id'],
        tg_chat_id: @msg.dig('chat', 'id'),
        tg_thread_id: @msg['message_thread_id'],
        llm_model: model,
        classifier_confidence: classification.confidence,
        answered_at: Time.current
      )
      # Phase 5.4 — dual-track audit. StaffQuestion = full Q&A record (KPI
      # question_dependency metric). BotCommandLog = unified bot-action stream
      # (для /admin/health observability + cross-action filtering).
      log_to_bot_command_log(classification, used_tools)
      record
    rescue StandardError => e
      Rails.logger.warn("[StaffChatResponder#persist_question] #{e.class}: #{e.message}")
      nil
    end

    def log_to_bot_command_log(classification, used_tools)
      return if @asked_by.nil?

      args_payload = {
        question_truncated: @question.to_s.truncate(120),
        used_tools: used_tools,
        confidence: classification.confidence,
        escalated: classification.kind == 'escalation'
      }
      BotCommandLog.create!(
        tg_user_id: @asked_by.tg_user_id,
        command: 'qna',
        args: args_payload.to_json,
        result: classification.kind || 'unclear'
      )
    rescue StandardError => e
      Rails.logger.warn("[StaffChatResponder#log_to_bot_command_log] #{e.class}: #{e.message}")
    end

    def empty_result(error)
      Result.new(answer: '⚠️ Не удалось обработать вопрос.', kind: nil, used_tools: [],
                 model: nil, record: nil, error: error)
    end

    def system_prompt
      asker = @asked_by.mention
      <<~PROMPT.strip
        Ты — корпоративный ассистент агентства недвижимости «Виктори» (Рязань).
        Отвечаешь сотрудникам в общем чате #ВОПРОС/ОТВЕТ.

        Сейчас спрашивает: #{asker} (#{@asked_by.first_name}, role=#{@asked_by.role}).

        Правила:
        1. ВСЕГДА отвечай по-русски, профессионально и кратко (≤ 4 предложения для базовых вопросов).
        2. ИСПОЛЬЗУЙ tools для конкретных запросов про задачи/лиды/папки/шаблоны.
           Никогда не выдумывай данные — лучше скажи «не нашёл, уточни id или имя клиента».
        3. Для общих вопросов (комиссия, процедура, юр.ликбез) — отвечай из общих знаний
           о российском real-estate. Если не уверен — скажи прямо.
        4. Никогда не раскрывай внутренние ID систем (Topnlab id, telegram user_id)
           без явного запроса. PII клиентов (полные телефоны/паспорта) — НЕ упоминай.
        5. Используй dd.MM.yy для дат, HH:MM для времени Moscow.
        6. Подписи команд бота — используй <code>команда</code> formatting.

        Tools доступны (вызывай ТОЛЬКО когда они помогут конкретно):
          • list_my_open_tasks — мои/чужие открытые задачи
          • lookup_task — задача по id/title
          • lookup_lead — лид по id/имени/телефону
          • agent_status — нагрузка сотрудника
          • document_checklist_status — Phase 4 docs checklist по lead_id
            (сколько получено / overdue / pending)
          • kpi_for — KPI snapshot по сотруднику или агентству за период
          • nextcloud_lookup_deal — папка сделки + share-link
          • nextcloud_list_templates — шаблоны договоров
          • director_self_audit — какие лиды/задания manager+ роль раздал за период.
            Применяй на запросы «какие задания я давала сегодня», «лиды я направила
            на этой неделе», «что Оксана раздала вчера». period обязателен; agent
            видит только себя (silent fallback). Возвращает структуру с counts и
            items — затем рендери human-readable список с dd.MM.yy датами.
          • search_group_messages — FTS-поиск по сообщениям рабочего чата (русский
            dict, морфология). Применяй: «что писали про Канищево», «что Ирина
            писала за неделю», «обсуждение в #КВАРТИРЫ». Возвращает items с
            sender/excerpt/tg_link. Manager+ only. Phase 15.
          • search_all_tasks — поиск задач cross-staff с фильтрами (assignee,
            status, priority, kind, period). Применяй: «какие задачи overdue»,
            «задачи Ирины», «high-priority открытые». Agent видит свои. Phase 15.
          • search_all_leads — поиск лидов cross-staff с FTS по metadata
            + фильтры (stage, topic, assignee, period). Применяй: «найди лиды
            по Солотче», «открытые лиды на стадии показа», «лиды направленные
            Серёгой за вчера». Phase 15.
          • summarize_group_messages — LLM-summary обсуждений в рабочем чате
            (3 секции: темы / открытые вопросы / решения). Применяй: «суммируй
            вчерашнее», «сводка по #КВАРТИРЫ за неделю», «что было обсуждено
            про Канищево — кратко». Подходит когда сообщений много (>5) и
            нужен анализ. Для точечного поиска — search_group_messages. Phase 15.5.
      PROMPT
    end

    def escape(text)
      text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
    end
  end
end
