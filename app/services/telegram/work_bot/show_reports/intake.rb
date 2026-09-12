# frozen_string_literal: true

module Telegram
  module WorkBot
    module ShowReports
      # BOTTLENECK — общий вход для голосового и `/show`: извлечь → создать
      # pending ShowReport → показать превью. Сам ничего не отвечает при
      # ошибке: возвращает Result с текстом, который вызывающий шлёт тем
      # способом, который у него есть (edit_ack у voice, reply у команды).
      class Intake
        Result = Struct.new(:ok, :report, :message, keyword_init: true)

        PENDING_LIMIT_MESSAGE = '🚫 У тебя есть неподтверждённый отчёт о показе <b>#%<id>d</b>. ' \
                                'Сохрани или отмени его кнопками в превью, потом присылай новый.'

        # Открытые лиды, из которых LLM выбирает: агент — свои, руководитель — все.
        # Порядок по updated_at: только что показанный лид почти наверняка
        # трогали (стадия/заметка) — он окажется первым в промпте.
        def self.candidates_for(reporter)
          scope = LeadEvent.real.open.includes(:property).order(updated_at: :desc)
          reporter.manager_or_director? ? scope : scope.for_agent(reporter)
        end

        def initialize(reporter:, transcript_raw:, transcript_redacted:, source:, chat_id:, lead: nil,
                       client: Telegram::Client.new, extractor: Extractor)
          @reporter = reporter
          @transcript_raw = transcript_raw.to_s
          @transcript_redacted = transcript_redacted.to_s
          @source = source
          @chat_id = chat_id
          @lead = lead
          @client = client
          @extractor = extractor
        end

        def call
          pending = ShowReport.status_pending_confirm.where(reported_by: @reporter).order(created_at: :desc).first
          return Result.new(ok: false, message: format(PENDING_LIMIT_MESSAGE, id: pending.id)) if pending

          candidates = @lead ? [@lead] : self.class.candidates_for(@reporter).to_a
          extraction = @extractor.call(transcript: @transcript_raw, candidates: candidates,
                                       reporter: @reporter, now: Time.current)
          unless extraction.success?
            return Result.new(ok: false,
                              message: "⚠️ Не удалось разобрать рассказ: #{extraction.error.to_s.truncate(120)}")
          end

          lead = @lead || candidates.find { |c| c.id == extraction.lead_id }
          return Result.new(ok: false, message: lead_hint(candidates)) if lead.nil?

          report = create_report(lead, extraction)
          Confirmer.new(report: report, client: @client).call
          Result.new(ok: true, report: report)
        rescue StandardError => e
          Rails.logger.error("[ShowReports::Intake] #{e.class}: #{e.message}")
          Result.new(ok: false, message: "⚠️ Внутренняя ошибка: #{e.message.truncate(120)}")
        end

        private

        def create_report(lead, ex)
          ShowReport.create!(
            lead_event: lead,
            property: Lead::PropertyResolver.call(lead),
            conducted_by: conductor_for(lead, ex),
            reported_by: @reporter,
            conducted_at: ex.conducted_at || Time.current,
            outcome: ex.outcome,
            objections: ex.objections,
            offered_price: ex.offered_price,
            next_step: ex.next_step,
            owner_message: ex.owner_message,
            uncertainties: ex.uncertainties,
            transcript_redacted: @transcript_redacted.truncate(4000),
            source: @source
          )
        end

        # Кто показывал: если LLM услышал «Оксана показывала» — директор, иначе
        # рассказчик. Переключается кнопкой в превью. Стек C добавит третий
        # источник — назначенного через show_assign (metadata['show_conductor_id']).
        def conductor_for(lead, ex)
          assigned = TelegramUser.find_by(id: lead.metadata['show_conductor_id'])
          return assigned if assigned

          return @reporter unless ex.conducted_by_director

          TelegramUser.directors.active.first || @reporter
        end

        def lead_hint(candidates)
          list = candidates.first(5).map do |c|
            "  • <code>/show #{c.id}</code> — #{escape(c.property&.address.presence || c.metadata['name'].presence || "лид ##{c.id}")}"
          end
          head = '🤔 Не понял, по какому лиду показ. Напиши текстом с номером лида, например ' \
                 '<code>/show 12 показ прошёл, кухня не понравилась</code>'
          list.any? ? "#{head}\nТвои открытые лиды:\n#{list.join("\n")}" : head
        end

        def escape(text)
          text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
        end
      end
    end
  end
end
