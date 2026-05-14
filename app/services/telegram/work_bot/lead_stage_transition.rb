# frozen_string_literal: true

module Telegram
  module WorkBot
    # Извлечённая логика смены стадии лида — переиспользуется командами `/stage`,
    # `/close` и автоматическими triggers (например, ReactionHandler ставит 👍 →
    # first_contact, SLA-watchdog потенциально может закрыть «брошенный» лид).
    #
    # Делает:
    #   1. Обновляет `LeadEvent.current_stage` + side-effect timestamps
    #      (first_contact_at для 'first_contact', closed_at для 'closed_*')
    #   2. Перерисовывает якорную карточку через `edit_message_text` (меняется эмодзи)
    #   3. Постит тизер в #СДЕЛКА при contract/deal (через DealMirror)
    #   4. Пробрасывает stage_id в Topnlab CRM через `transfer_client`, если в
    #      `StagesCache.id_for(new_stage)` есть mapping (иначе skip, локально-only)
    #
    # Идемпотентность: повторный вызов на уже-current стадии возвращает
    # `Result(false, "already at <stage>")`.
    class LeadStageTransition
      Result = Struct.new(:success, :prev_stage, :new_stage, :message) do
        def success?
          success
        end
      end

      VALID_STAGES = ['new', 'first_contact', 'show', 'contract', 'deal', 'closed_won', 'closed_lost'].freeze

      def initialize(lead_event, new_stage, actor:, client: Telegram::Client.new)
        @lead   = lead_event
        @new    = new_stage.to_s
        @actor  = actor
        @client = client
      end

      def call
        unless VALID_STAGES.include?(@new)
          return Result.new(false, @lead.current_stage, @new,
                            "Неизвестная стадия: #{@new}")
        end
        return Result.new(false, @lead.current_stage, @new, "already at #{@new}") if @lead.current_stage == @new

        prev = @lead.current_stage
        apply_local!
        update_anchor_card!
        push_stage_to_crm(prev)
        maybe_mirror_to_deal

        Result.new(true, prev, @new, nil)
      end

      private

      def apply_local!
        attrs = { current_stage: @new }
        attrs[:first_contact_at] = Time.current if @new == 'first_contact' && @lead.first_contact_at.nil?
        attrs[:closed_at]        = Time.current if @new.start_with?('closed_')
        @lead.update!(attrs)
      end

      def update_anchor_card!
        return if @lead.anchor_message_id.blank?

        text = LeadAnnouncer.new(@lead, client: @client).format_card_text
        @client.edit_message_text(
          text,
          chat_id: @lead.tg_chat_id,
          message_id: @lead.anchor_message_id,
          parse_mode: 'HTML'
        )
      rescue StandardError => e
        Rails.logger.warn("[LeadStageTransition] edit_message_text failed: #{e.class}: #{e.message}")
      end

      def push_stage_to_crm(_prev)
        stage_id = Topnlab::StagesCache.id_for(@new)
        return if stage_id.blank? # map ещё не заполнен — Phase 2 поведение (skip CRM stage)

        crm_id = @lead.lead_ref.try(:crm_id)
        return if crm_id.blank?

        email = @lead.assigned_to&.email
        return if email.blank? # transfer_client требует email — без назначенного агента не дёргаем

        Topnlab::Client.new.transfer_client(order_id: crm_id.to_i, email: email, stage_id: stage_id)
      rescue Topnlab::Client::Error => e
        Rails.logger.warn("[LeadStageTransition] transfer_client failed: #{e.message}")
      end

      def maybe_mirror_to_deal
        return unless ['contract', 'deal'].include?(@new)

        DealMirror.new(@lead, client: @client).post
      end
    end
  end
end
