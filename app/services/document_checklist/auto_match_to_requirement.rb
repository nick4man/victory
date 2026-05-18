# frozen_string_literal: true

module DocumentChecklist
  # Phase 4G — Auto-match A6 ClientDocument к DocumentRequirement.
  #
  # Триггер: DocumentIntake::ParserJob после OCR + notify_staff.
  # Action: find target DocumentRequirement по (inquiry|property → lead_event,
  # document_kind → DR.kind), и при достаточной OCR confidence — auto-mark
  # status='received' + link received_via_client_document_id.
  #
  # Mapping ClientDocument.document_kind → DocumentRequirement.kind:
  #   • passport → passport_main (primary + DEPENDS_ON cascade triggers
  #     passport_registration in Builder; для now просто primary match)
  #   • inn → inn
  #   • egrn → egrn_excerpt
  #   • contract → contract_sale
  #   • other → no match (skip)
  #
  # Confidence routing:
  #   • >= 0.7  → auto-link + status='received' + DM agent: «✅ автопривязан»
  #   • <  0.7  → flagged for manual: DM agent с suggestion «❓ Похоже на X»
  #
  # Notes:
  #   • Search scope: DR.status IN [not_requested, requested] — НЕ override
  #     verified/approved (agent явно reviewed их раньше)
  #   • Если несколько кандидатов lead_events (inquiry connected to many) —
  #     take most recent open (LeadEvent.assigned_at IS NOT NULL ORDER BY
  #     assigned_at DESC) — most likely active deal
  #   • Soft-fail: любая ошибка → Result(:error) без блокировки ParserJob
  class AutoMatchToRequirement
    CONFIDENCE_AUTO_LINK = 0.7

    KIND_MAP = {
      'passport' => 'passport_main',
      'inn'      => 'inn',
      'egrn'     => 'egrn_excerpt',
      'contract' => 'contract_sale'
      # 'other' — skip (no DR kind match)
    }.freeze

    Result = Struct.new(:status, :requirement, :lead_event, :reason,
                        keyword_init: true) do
      def success?
        status == :auto_linked
      end
    end

    def self.call(...)
      new(...).call
    end

    def initialize(client_document:)
      @doc = client_document
    end

    def call
      target_kind = KIND_MAP[@doc.document_kind.to_s]
      return skip('no DR kind mapping for document_kind') if target_kind.blank?

      lead = resolve_lead_event
      return skip('no associated LeadEvent') if lead.nil?

      requirement = ::DocumentRequirement.where(lead_event_id: lead.id, kind: target_kind)
                                         .where(status: %w[not_requested requested])
                                         .first
      return skip("no open DR(kind=#{target_kind}) on lead##{lead.id}") if requirement.nil?

      confidence = extract_confidence
      if confidence < CONFIDENCE_AUTO_LINK
        notify_agent_for_review(requirement, lead, confidence)
        return Result.new(status: :flagged_for_review,
                          requirement: requirement, lead_event: lead,
                          reason: "confidence #{confidence.round(2)} < #{CONFIDENCE_AUTO_LINK}")
      end

      apply_match!(requirement, confidence)
      notify_agent_auto_linked(requirement, lead, confidence)

      Result.new(status: :auto_linked, requirement: requirement,
                 lead_event: lead, reason: nil)
    rescue StandardError => e
      Rails.logger.error("[AutoMatchToRequirement] #{e.class}: #{e.message}\n#{e.backtrace.first(3).join("\n")}")
      Result.new(status: :error, requirement: nil, lead_event: nil, reason: e.message)
    end

    private

    # Прохождение lead_ref → LeadEvent. ClientDocument's inquiry/property
    # → LeadEvent через polymorphic lead_ref.
    def resolve_lead_event
      if @doc.inquiry_id
        # LeadEvent с lead_ref = этот Inquiry, наиболее свежий
        ::LeadEvent.where(lead_ref_type: 'Inquiry', lead_ref_id: @doc.inquiry_id)
                   .order(created_at: :desc).first
      elsif @doc.property_id
        # Через Inquiry.property_id матч — наиболее свежий открытый
        recent_inquiry = ::Inquiry.where(property_id: @doc.property_id)
                                  .where.not(status: %w[spam cancelled])
                                  .order(created_at: :desc).first
        return nil unless recent_inquiry

        ::LeadEvent.where(lead_ref_type: 'Inquiry', lead_ref_id: recent_inquiry.id)
                   .order(created_at: :desc).first
      end
    end

    def extract_confidence
      pd = @doc.parsed_data || {}
      # Handle both string + symbol keys
      raw = pd['confidence'] || pd[:confidence]
      raw.to_f.clamp(0.0, 1.0)
    end

    def apply_match!(requirement, confidence)
      # Используем lifecycle helper, дополнительно меta для traceability.
      requirement.with_lock do
        requirement.reload
        # Idempotency: если кто-то уже отметил received — skip
        next if %w[received verified approved].include?(requirement.status)

        requirement.update!(
          status: 'received',
          received_at: Time.current,
          received_via_client_document_id: @doc.id,
          metadata: requirement.metadata.merge(
            'auto_matched' => true,
            'auto_match_confidence' => confidence.round(3),
            'auto_match_at' => Time.current.iso8601,
            'auto_match_via_client_document_id' => @doc.id
          )
        )
      end
    end

    def notify_agent_auto_linked(requirement, lead, confidence)
      tu = lead.assigned_to
      return if tu.nil?

      conf_pct = (confidence * 100).round
      text = "✅ <b>Документ автопривязан</b>\n" \
             "Лид: ##{lead.id} (#{lead.metadata['name'] || 'без имени'})\n" \
             "Документ: #{requirement.ru_label}\n" \
             "Confidence OCR: #{conf_pct}%\n" \
             "ClientDocument: ##{@doc.id}\n\n" \
             "<i>Если не тот документ — отмени: <code>/doc #{kind_alias(requirement.kind)}-</code></i>"

      send_dm(tu, text)
    end

    def notify_agent_for_review(requirement, lead, confidence)
      tu = lead.assigned_to
      return if tu.nil?

      conf_pct = (confidence * 100).round
      text = "❓ <b>Документ требует ручной привязки</b>\n" \
             "Лид: ##{lead.id} (#{lead.metadata['name'] || 'без имени'})\n" \
             "Предположительно: #{requirement.ru_label}\n" \
             "Confidence OCR: #{conf_pct}% (порог #{(CONFIDENCE_AUTO_LINK * 100).to_i}%)\n" \
             "ClientDocument: ##{@doc.id}\n\n" \
             "<i>Привязать: <code>/doc #{kind_alias(requirement.kind)}+</code>\n" \
             "Открыть: /admin/client_documents/#{@doc.id}</i>"

      send_dm(tu, text)
    end

    def send_dm(tg_user, text)
      chat_id = tg_user.dm_chat_id || tg_user.tg_user_id
      return if chat_id.blank?

      ::Telegram::Client.new.send_message(text, chat_id: chat_id, parse_mode: 'HTML')
    rescue ::Telegram::Client::Error => e
      Rails.logger.warn("[AutoMatchToRequirement] DM failed: #{e.message}")
    end

    # Reverse lookup KIND_ALIASES → first matching short form.
    def kind_alias(kind)
      ::DocumentRequirement::KIND_ALIASES.find { |_alias, k| k == kind }&.first || kind
    end

    def skip(reason)
      Rails.logger.info("[AutoMatchToRequirement] skip doc##{@doc.id}: #{reason}")
      Result.new(status: :skipped, requirement: nil, lead_event: nil, reason: reason)
    end
  end
end
