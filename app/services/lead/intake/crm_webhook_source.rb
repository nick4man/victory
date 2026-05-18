# frozen_string_literal: true

module Lead
  class Intake
    # Phase 4E — Адаптер «новый order в Topnlab» (agent создал руками в CRM UI
    # минуя сайт/TG). Webhooks::TopnlabController вызывает после sync
    # of BuyerOrder для type='order' events.
    #
    # Payload:
    #   {
    #     id: <topnlab order_id>,
    #     type: 'order',
    #     event_id: <optional dedup key for replay buffer>
    #   }
    #
    # Logic:
    #   1. Find BuyerOrder.find_by(crm_id: id) — должен exist после sync
    #   2. Check Phase 4H ClientResolver — может быть existing Inquiry от
    #      того же клиента (phone/email match) → return existing (NO new lead)
    #   3. Иначе create Inquiry attribution_source='crm_webhook' с
    #      client_phone_e164/email_norm для будущей cross-channel attribution
    #
    # Returns [inquiry, metadata] или nil (skip — например когда order не
    # найден после sync OR matched existing).
    class CrmWebhookSource
      def call(payload)
        order_id = payload[:id] || payload['id']
        return skip('no order_id in payload') if order_id.blank?

        buyer_order = BuyerOrder.find_by(crm_id: order_id.to_i)
        return skip("BuyerOrder crm_id=#{order_id} not found — sync may not have completed") if buyer_order.nil?

        phone_normalized = Lead::Intake::ClientResolver.normalize_phone(
          extract_phone(buyer_order)
        )

        # Phase 4H — cross-channel dedup. Если клиент уже приходил через site
        # form / TG-DM — match по phone, append к существующему thread'у.
        resolved = Lead::Intake::ClientResolver.find(
          phone: phone_normalized,
          tg_user_id: nil, # CRM не знает TG identity клиента (только email/phone)
          email: nil
        )

        if resolved.matched?
          Rails.logger.info(
            "[Lead::Intake::CrmWebhookSource] cross-channel match: inquiry##{resolved.inquiry.id} " \
            "via #{resolved.match_strategy} — appending CRM context, no new LeadEvent"
          )
          append_crm_context!(resolved.inquiry, buyer_order)
          # Return nil → Intake.call will skip LeadEvent creation (existing
          # one остаётся в-сила).
          return nil
        end

        inquiry = create_inquiry_from_order(buyer_order, phone_normalized)
        [inquiry, build_metadata(buyer_order)]
      end

      private

      def extract_phone(buyer_order)
        # `client_phone_masked` хранит '+7 999 ***-**-67' — НЕ pristine.
        # Phase 4 не имеет full phone в нашей БД (DLP — full phone остаётся
        # в Topnlab). Возвращаем masked для normalize (digits-only) — даст
        # ограниченный E.164 но last-4 совпадут с full когда придёт через TG.
        # Better long-term: store hashed full-phone OR fetch on-demand.
        buyer_order.client_phone_masked
      end

      def create_inquiry_from_order(buyer_order, phone_normalized)
        Thread.current[:skip_workbot_push] = true

        message_lines = [
          "CRM order ##{buyer_order.crm_id}",
          buyer_order.description.to_s.presence,
          format_price_range(buyer_order),
          format_area_range(buyer_order),
          buyer_order.preferred_districts.presence&.then { |d| "Районы: #{Array(d).join(', ')}" }
        ].compact.join("\n")

        Inquiry.create!(
          inquiry_type: 'quick_inquiry',
          name: buyer_order.client_name.to_s.presence || "CRM order ##{buyer_order.crm_id}",
          phone: buyer_order.client_phone_masked, # PII в Topnlab; у нас masked
          email: nil,
          message: message_lines,
          source: 'crm_webhook',
          status: 'new',
          client_phone_e164: phone_normalized,
          attribution_source: 'crm_webhook'
        )
      ensure
        Thread.current[:skip_workbot_push] = false
      end

      def build_metadata(buyer_order)
        {
          'name' => buyer_order.client_name.presence || "CRM##{buyer_order.crm_id}",
          'summary' => buyer_order.description.to_s.truncate(500),
          'crm_id' => buyer_order.crm_id,
          'crm_stage' => buyer_order.stage_name,
          'crm_deal_type' => buyer_order.deal_type,
          'crm_realty_type' => buyer_order.realty_type,
          'budget' => format_price_range(buyer_order),
          'priority' => 'normal',
          'origin' => 'topnlab_webhook'
        }.compact
      end

      def format_price_range(bo)
        return nil if bo.price_min.blank? && bo.price_max.blank?

        parts = []
        parts << "от #{bo.price_min}" if bo.price_min.present?
        parts << "до #{bo.price_max}" if bo.price_max.present?
        parts.join(' ')
      end

      def format_area_range(bo)
        return nil if bo.area_min.blank? && bo.area_max.blank?

        parts = []
        parts << "от #{bo.area_min}м²" if bo.area_min.present?
        parts << "до #{bo.area_max}м²" if bo.area_max.present?
        parts.join(' ')
      end

      # Cross-channel CRM follow-up — клиент уже у нас, в Topnlab дополнили
      # детали. Append к anchor metadata['client_history'].
      def append_crm_context!(inquiry, buyer_order)
        lead = LeadEvent.where(lead_ref_type: 'Inquiry', lead_ref_id: inquiry.id)
                        .order(created_at: :desc).first
        return unless lead

        entry = {
          'at' => Time.current.iso8601,
          'channel' => 'crm_webhook',
          'crm_id' => buyer_order.crm_id,
          'crm_stage' => buyer_order.stage_name,
          'text' => "CRM order updated: stage=#{buyer_order.stage_name}"
        }
        history = lead.append_history(key: 'client_history', entry: entry)
        lead.update!(metadata: lead.metadata.merge('client_history' => history))
      rescue StandardError => e
        Rails.logger.warn("[CrmWebhookSource#append_crm_context!] #{e.class}: #{e.message}")
      end

      def skip(reason)
        Rails.logger.info("[Lead::Intake::CrmWebhookSource] skip: #{reason}")
        nil # Intake.call видит nil → skip LeadEvent creation
      end
    end
  end
end
