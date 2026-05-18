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
        # Phase 4H stub — returning client detection. В Phase 4H будет
        # full match priority phone > tg_user_id > email + reply to existing
        # anchor. Сейчас: тонкий dedupe по tg_user_id за 90d (если уже есть
        # active Inquiry — skip, don't create dup).
        returning = find_recent_inquiry_by_tg(payload[:tg_user_id])
        if returning
          Rails.logger.info(
            "[Lead::Intake::TgDmSource] returning client tg_user_id=#{payload[:tg_user_id]}; " \
            "existing inquiry##{returning.id} (#{returning.created_at}). Skip create — Phase 4H будет threading."
          )
          # Return existing inquiry; caller (Intake.call) won't create LeadEvent
          # потому что check existing LeadEvent for this lead_ref.
          return [returning, build_metadata(payload, returning_client: true)]
        end

        inquiry = create_inquiry(payload)
        [inquiry, build_metadata(payload, returning_client: false)]
      end

      private

      # Returning-client lookup: tg_user_id match за 90d, not closed/spam.
      # Phase 4H будет full match priority (phone > tg_user_id > email).
      def find_recent_inquiry_by_tg(tg_user_id)
        return nil if tg_user_id.blank?

        Inquiry.where(client_tg_user_id: tg_user_id)
               .where('created_at > ?', 90.days.ago)
               .where.not(status: ['spam', 'cancelled'])
               .order(created_at: :desc)
               .first
      end

      # Recursion guard like SiteSource: after_create_commit Inquiry triggers
      # Lead::Intake.call(...) — без guard would cycle.
      def create_inquiry(payload)
        Thread.current[:skip_workbot_push] = true

        Inquiry.create!(
          inquiry_type: infer_inquiry_type(payload[:intent]),
          name: build_name(payload),
          phone: nil, # клиент пока не дал — будет qualified later
          email: nil,
          message: payload[:text].to_s[0, 5_000],
          source: 'tg_dm',
          status: 'new',
          client_tg_user_id: payload[:tg_user_id],
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

      def build_metadata(payload, returning_client:)
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
          'priority' => returning_client ? 'high' : 'normal'
        }.compact
      end
    end
  end
end
