# frozen_string_literal: true

# Async background worker for express valuation (POST /valuations).
# Mirrors InvestmentAuditJob pattern — moves heavy compute out of the
# request thread so user sees loader page сразу. Updates valuation status
# at the end + emits the same downstream notifications (mailer + CRM +
# Telegram staff dispatch) only когда status: :completed.
#
# Pipeline:
#   1. PropertyEvaluationService.new(valuation).call — comp finder + hedonic + bootstrap
#   2. On success → persist estimated_price/min/max/confidence/hedonic_data, status=completed
#   3. Async mailer (если email указан)
#   4. CRM lead создание (stub пока, see #create_crm_lead)
#   5. ExpressReportNotifier — staff TG group с HTML summary + attached PDF
#
# Если PropertyEvaluationService возвращает {success:false} или бросает
# исключение — status=failed + evaluation_data[:error] для UI / debugging.
class PropertyValuationJob < ApplicationJob
  queue_as :default

  discard_on ActiveRecord::RecordNotFound

  def perform(valuation_id)
    valuation = PropertyValuation.find(valuation_id)
    return if valuation.completed? || valuation.failed?

    result = PropertyEvaluationService.new(valuation).call

    if result[:success]
      apply_success!(valuation, result)
      dispatch_downstream(valuation)
    else
      valuation.update!(
        status:          'failed',
        evaluation_data: { error: result[:error] || 'Не удалось рассчитать оценку.' }
      )
    end
  rescue StandardError => e
    Rails.logger.error("[PropertyValuationJob] #{e.class}: #{e.message}")
    valuation&.update(status: 'failed', evaluation_data: { error: e.message })
    raise
  end

  private

  def apply_success!(valuation, result)
    # Phase 4.6: hedonic + composite + bootstrap_ci moved out of evaluation_data
    # blob into dedicated hedonic_data jsonb так analytics могут query R² etc.
    # без парсинга всего blob'а.
    hedonic_payload = {
      hedonic:      result[:hedonic],
      composite:    result[:composite],
      bootstrap_ci: result[:bootstrap_ci]
    }.compact

    valuation.update!(
      estimated_price:  result[:estimated_price],
      min_price:        result[:min_price],
      max_price:        result[:max_price],
      confidence_level: result[:confidence_level],
      evaluation_data:  result.except(:success),
      hedonic_data:     hedonic_payload,
      status:           'completed'
    )
  end

  def dispatch_downstream(valuation)
    # Email пользователю — async через deliver_later (даже job в job ok).
    PropertyValuationMailer.valuation_completed(valuation).deliver_later if valuation.email.present?

    # CRM (пока stub — replaced когда подключим AmoCRM/Bitrix).
    create_crm_lead(valuation) if valuation.email.present?

    # Staff Telegram dispatch — HTML summary + PDF document. Inside the
    # job, не в controller'е, чтобы user requirement выполнить: TG приходит
    # только после готового отчёта со всеми числами.
    ExpressReportNotifier.notify(valuation)

    # Enrich existing LeadEvent anchor card (см. LeadAnnouncer.refresh!)
    # + send PDF as reply в тот же топик группы -1003779115845.
    # LeadEvent был создан Lead::Intake.call'ом из PropertyValuation
    # #push_to_work_bot при first save; anchor_message_id хранится там.
    push_to_lead_card(valuation)
  end

  def push_to_lead_card(valuation)
    lead = LeadEvent.find_by(lead_ref: valuation)
    if lead.nil? || lead.anchor_message_id.blank?
      Rails.logger.info("[PropertyValuationJob] no LeadEvent anchor для valuation=#{valuation.id} — skip card refresh")
      return
    end

    client = Telegram::Client.new
    Telegram::WorkBot::LeadAnnouncer.refresh!(lead, client: client)

    # PDF как reply к anchor — staff видит link в карточке + сразу PDF.
    pdf_bytes = PdfGeneratorService.new(valuation).call
    io = StringIO.new(pdf_bytes)
    client.send_document(
      { io: io, filename: "valuation-#{valuation.report_number || valuation.token}.pdf",
        content_type: 'application/pdf' },
      chat_id: Telegram::TopicRegistry.chat_id,
      caption: "📐 Экспресс-оценка #{valuation.report_label}",
      parse_mode: 'HTML',
      reply_to_message_id: lead.anchor_message_id,
      message_thread_id: Telegram::TopicRegistry.thread_id(lead.anchor_topic_key)
    )
  rescue StandardError => e
    Rails.logger.warn("[PropertyValuationJob] push_to_lead_card failed for #{valuation.id}: #{e.class} #{e.message.to_s.truncate(160)}")
  end

  def create_crm_lead(valuation)
    # Mirrors PropertyValuationsController#create_crm_lead — пока stub,
    # реальная интеграция AmoCRM/Bitrix добавится отдельно. Логгируем для
    # отслеживания funnel.
    Rails.logger.info "[PropertyValuationJob] CRM lead для valuation ##{valuation.id} (#{valuation.email})"
  rescue StandardError => e
    Rails.logger.error "[PropertyValuationJob] CRM lead failed: #{e.message}"
  end
end
