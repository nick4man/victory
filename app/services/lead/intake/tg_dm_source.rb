# frozen_string_literal: true

module Lead
  class Intake
    # Phase 4D — Адаптер «клиент пишет боту в личку» (TG-DM intake).
    #
    # Триггер: client_bot/text_intake_processor.rb после IntentClassifier
    # пропустил message (inquiry/question/appointment). Payload:
    #   {
    #     text: String,
    #     tg_user_id: Integer,
    #     tg_username: String?,
    #     first_name: String?,
    #     last_name: String?,
    #     dm_chat_id: Integer,
    #     intent: String,         # 'inquiry'/'question'/'appointment'
    #     intent_confidence: Float,
    #     intent_reasoning: String?
    #   }
    #
    # Возвращает [inquiry, metadata] либо nil (skip — например для returning
    # client в Phase 4H будем threading в existing anchor).
    class TgDmSource
      def call(payload)
        # Phase 4H — Cross-channel client resolver. Match priority:
        #   phone E.164 > tg_user_id > email norm (см. ClientResolver).
        # Client может прийти с site form → теперь же написать в TG —
        # match по phone обнаружит existing site-form Inquiry, append
        # к existing thread без duplicate LeadEvent.
        resolved = Lead::Intake::ClientResolver.find(
          phone: payload[:phone],
          tg_user_id: payload[:tg_user_id],
          email: payload[:email]
        )

        if resolved.matched?
          inquiry = resolved.inquiry
          Rails.logger.info(
            "[Lead::Intake::TgDmSource] cross-channel match: inquiry##{inquiry.id} " \
            "via #{resolved.match_strategy} (conf=#{resolved.confidence}). " \
            'Threading to existing LeadEvent.'
          )
          append_to_anchor_history!(inquiry, payload, resolved)
          return [inquiry, build_metadata(payload, returning_client: true,
                                                  match_strategy: resolved.match_strategy,
                                                  match_confidence: resolved.confidence)]
        end

        inquiry = create_inquiry(payload)
        [inquiry, build_metadata(payload, returning_client: false)]
      end

      private

      # Phase 4H — Append message to anchor card's metadata['client_history'].
      # Agent видит continuous conversation thread в одной карточке вместо
      # series of new LeadEvents. Cap via LeadEvent#append_history (HISTORY
      # _DEFAULT_CAPS, Phase 12 Iter 39 — соответствующий key добавляется
      # с дефолтным cap=50 если не зарегистрирован).
      def append_to_anchor_history!(inquiry, payload, resolved)
        lead = LeadEvent.where(lead_ref_type: 'Inquiry', lead_ref_id: inquiry.id)
                        .order(created_at: :desc).first
        return unless lead

        entry = {
          'at' => Time.current.iso8601,
          'channel' => 'tg_dm',
          'match_strategy' => resolved.match_strategy,
          'match_confidence' => resolved.confidence,
          'text' => payload[:text].to_s[0, 500],
          'intent' => payload[:intent]
        }
        history = lead.append_history(key: 'client_history', entry: entry)
        lead.update!(metadata: lead.metadata.merge('client_history' => history))

        notify_assignee_of_followup(lead, entry)
      rescue StandardError => e
        Rails.logger.warn("[TgDmSource#append_to_anchor_history!] #{e.class}: #{e.message}")
      end

      def notify_assignee_of_followup(lead, entry)
        assignee = lead.assigned_to
        return unless assignee

        chat_id = assignee.dm_chat_id || assignee.tg_user_id
        return if chat_id.blank?

        text = "💬 <b>Сообщение от клиента</b> по лиду ##{lead.id}\n" \
               "<i>#{escape_html(entry['text'].to_s.truncate(300))}</i>\n\n" \
               "Контекст: канал #{entry['channel']}, intent=#{entry['intent']}, " \
               "match=#{entry['match_strategy']}"

        Telegram::Client.new.send_message(text, chat_id: chat_id, parse_mode: 'HTML')
      rescue Telegram::Client::Error => e
        Rails.logger.warn("[TgDmSource#notify_assignee_of_followup] #{e.message}")
      end

      def escape_html(text)
        text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
      end

      # Recursion guard like SiteSource: after_create_commit Inquiry triggers
      # Lead::Intake.call(...) — без guard would cycle.
      def create_inquiry(payload)
        Thread.current[:skip_workbot_push] = true

        Inquiry.create!(
          inquiry_type: infer_inquiry_type(payload[:intent]),
          name: build_name(payload),
          phone: payload[:phone], # nil ОК — qualification step later
          email: payload[:email],
          message: payload[:text].to_s[0, 5_000],
          source: 'tg_dm',
          status: 'new',
          client_tg_user_id: payload[:tg_user_id],
          client_phone_e164: Lead::Intake::ClientResolver.normalize_phone(payload[:phone]),
          client_email_norm: Lead::Intake::ClientResolver.normalize_email(payload[:email]),
          attribution_source: 'tg_dm'
        )
      ensure
        Thread.current[:skip_workbot_push] = false
      end

      # Map IntentClassifier intent → Inquiry.inquiry_type enum.
      def infer_inquiry_type(intent)
        case intent.to_s
        when 'appointment'      then 'viewing'
        when 'question'         then 'consultation'
        else                         'quick_inquiry'
        end
      end

      def build_name(payload)
        return [payload[:first_name], payload[:last_name]].compact.join(' ').strip.presence ||
               "@#{payload[:tg_username]}".presence ||
               "tg:#{payload[:tg_user_id]}"
      end

      def build_metadata(payload, returning_client:, match_strategy: nil, match_confidence: nil)
        {
          'name' => build_name(payload),
          'summary' => payload[:text].to_s[0, 1_000],
          'tg_user_id' => payload[:tg_user_id],
          'tg_username' => payload[:tg_username],
          'dm_chat_id' => payload[:dm_chat_id],
          'intent' => payload[:intent],
          'intent_confidence' => payload[:intent_confidence],
          'intent_reasoning' => payload[:intent_reasoning],
          'returning_client' => returning_client,
          'match_strategy' => match_strategy,
          'match_confidence' => match_confidence,
          'priority' => returning_client ? 'high' : 'normal'
        }.compact
      end
    end
  end
end
