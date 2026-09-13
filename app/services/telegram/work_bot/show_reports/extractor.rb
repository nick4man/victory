# frozen_string_literal: true

module Telegram
  module WorkBot
    module ShowReports
      # BOTTLENECK — LLM-раскладка транскрипта после показа. Копия паттерна
      # TaskExtractor: Result-struct, никогда не бросает, normalize + quality gate.
      #
      # Зачем один вызов возвращает и данные, и черновик собственнику: сообщение
      # по регламенту уходит день в день до 11:00, и его всё равно пишет человек;
      # черновик из тех же возражений экономит агенту пять минут и гарантирует,
      # что в сообщении нет того, чего не было на показе.
      #
      # transcript — RAW (с PII): имена нужны для owner_message. В БД он не
      # попадает — Intake персистит только redacted-версию.
      class Extractor
        OUTCOMES = ShowReport.outcomes.keys.freeze
        MAX_CANDIDATES = 30

        Result = Struct.new(:lead_id, :conducted_by_director, :conducted_at, :outcome, :objections,
                            :offered_price, :next_step, :owner_message, :uncertainties, :model, :error,
                            keyword_init: true) do
          def success? = error.nil?
        end

        def self.call(...)
          new(...).call
        end

        def initialize(transcript:, candidates:, reporter:, now: Time.current, client: Llm::OmniClient.new)
          @transcript = transcript.to_s.strip
          @candidates = Array(candidates).first(MAX_CANDIDATES)
          @reporter   = reporter
          @now        = now
          @client     = client
        end

        def call
          return failure('пустой транскрипт') if @transcript.empty?

          res = @client.complete(
            [{ role: 'system', content: system_prompt },
             { role: 'user',   content: "Рассказ после показа:\n\n#{@transcript}" }],
            chain: :staff_analysis,
            response_format: { type: 'json_object' },
            temperature: 0.2,
            max_tokens: 900
          )
          parsed = JSON.parse(res[:content].to_s)
          build(parsed, res[:model])
        rescue JSON::ParserError => e
          failure("LLM вернул не JSON: #{e.message.truncate(80)}")
        rescue StandardError => e
          Rails.logger.error("[ShowReports::Extractor] #{e.class}: #{e.message}")
          failure(e.message)
        end

        private

        def failure(error)
          Result.new(objections: [], uncertainties: [], error: error)
        end

        def build(parsed, model)
          uncertainties = Array(parsed['uncertainties']).map(&:to_s).compact_blank
          lead_id = resolve_lead_id(parsed['lead_id'], uncertainties)
          objections = Array(parsed['objections']).map { |o| o.to_s.strip.downcase }.compact_blank.uniq.first(10)
          outcome = OUTCOMES.include?(parsed['outcome'].to_s) ? parsed['outcome'].to_s : 'thinking'

          Result.new(
            lead_id: lead_id,
            conducted_by_director: parsed['conducted_by_director'] == true,
            conducted_at: parse_time(parsed['conducted_at']),
            outcome: outcome,
            objections: objections,
            offered_price: parse_price(parsed['offered_price']),
            next_step: parsed['next_step'].to_s.strip.presence&.truncate(200),
            owner_message: parsed['owner_message'].to_s.strip.presence || template_owner_message(outcome, objections),
            uncertainties: uncertainties,
            model: model,
            error: nil
          )
        end

        def resolve_lead_id(raw, uncertainties)
          id = raw.to_i
          return id if id.positive? && @candidates.any? { |c| c.id == id }

          uncertainties << 'не удалось определить, по какому лиду показ' if @candidates.any?
          nil
        end

        def parse_time(raw)
          t = Time.zone.parse(raw.to_s)
          return @now if t.nil? || t > @now + 5.minutes || t < @now - 30.days

          t
        rescue ArgumentError
          @now
        end

        # Одна интерпретация цифры для голоса и для /bargain.
        def parse_price(raw)
          Formatters::PriceParse.call(raw)
        end

        def template_owner_message(outcome, objections)
          what = ShowReport::OUTCOME_LABELS[outcome].to_s.sub(/\A\S+\s/, '').downcase
          tail = objections.any? ? " Смутило: #{objections.join(', ')}." : ''
          "Добрый день! Это #{@reporter.first_name.presence || 'агент'}, АН «Виктори». " \
            "Провели показ вашей квартиры. Покупатели: #{what}.#{tail} Держим с ними связь, " \
            'как будет конкретика — сразу сообщу.'
        end

        def system_prompt
          <<~PROMPT.strip
            Ты — ассистент агентства недвижимости «Виктори». Сотрудник рассказывает (голосом) о только что
            проведённом показе квартиры. Извлеки структурированные данные в JSON.

            Открытые лиды сотрудника (выбери lead_id по адресу/имени покупателя; если не уверен — null):
            #{candidates_block}

            Сейчас: #{@now.strftime('%d.%m.%y %H:%M')} (Москва). Рассказчик: #{@reporter.first_name.presence || 'сотрудник'}
            (роль: #{@reporter.role}).

            Поля:
            - lead_id: число из списка выше или null.
            - conducted_by_director: true, если показ проводил руководитель (Оксана / директор), false — если сам рассказчик.
            - conducted_at: ISO8601 момент показа («только что» → сейчас, «утром» → сегодня 10:00, «вчера» → вчера 12:00).
            - outcome: один из #{OUTCOMES.join(' | ')} (thinking — думают/пауза, declined — отказ,
              second_show — хотят прийти ещё, bargain — назвали свою цену, deposit_intent — готовы к задатку).
            - objections: массив коротких тегов на русском в нижнем регистре, 1–4 слова каждый, что не понравилось
              («маленькая кухня», «первый этаж», «шумная дорога»). Одинаковые — один раз. Пусто, если возражений не было.
            - offered_price: число в рублях, если покупатель назвал цену, иначе null.
            - next_step: короткая фраза о следующем шаге или null.
            - owner_message: готовое сообщение собственнику от имени рассказчика, 2–4 предложения, тёплый тон,
              без цифр торга, без телефонов, только факты из рассказа. Начни с «Добрый день!».
            - uncertainties: массив строк — что осталось непонятным.

            Верни СТРОГО JSON:
            {"lead_id": 12, "conducted_by_director": true, "conducted_at": "2026-09-11T14:00:00",
             "outcome": "thinking", "objections": ["маленькая кухня"], "offered_price": null,
             "next_step": "перезвонят в пятницу", "owner_message": "Добрый день! ...", "uncertainties": []}
          PROMPT
        end

        def candidates_block
          return '(список пуст — lead_id всегда null)' if @candidates.empty?

          @candidates.map do |lead|
            address = lead.property&.address.presence || lead.metadata['summary'].to_s.truncate(60).presence || 'адрес неизвестен'
            name    = lead.metadata['name'].presence || 'имя неизвестно'
            "  • ##{lead.id} — #{address} — покупатель: #{name} — стадия: #{lead.current_stage}"
          end.join("\n")
        end
      end
    end
  end
end
