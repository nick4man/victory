# frozen_string_literal: true

module Telegram
  module WorkBot
    # Закрытие лида исходом: причина в metadata, переход стадии, заметка в
    # Topnlab. Общий путь для `/close` и мастера «Закрытие лида».
    class LeadClosure
      OUTCOMES = ['closed_won', 'closed_lost'].freeze

      def initialize(lead, new_stage, actor:, reason: nil, client: Telegram::Client.new)
        raise ArgumentError, "unknown outcome #{new_stage.inspect}" unless OUTCOMES.include?(new_stage)

        @lead = lead
        @new_stage = new_stage
        @actor = actor
        @reason = reason.presence
        @client = client
      end

      # @return [LeadStageTransition::Result]
      def call
        # Причину пишем до перехода — карточка перерисуется уже с ней.
        @lead.update!(metadata: @lead.metadata.merge('close_reason' => @reason)) if @reason

        result = LeadStageTransition.new(@lead, @new_stage, actor: @actor, client: @client).call
        push_close_note if result.success?
        result
      end

      private

      def push_close_note
        crm_id = @lead.lead_ref.try(:crm_id)
        return if crm_id.blank?

        icon = @new_stage == 'closed_won' ? '✅' : '❌'
        note = "#{icon} Закрыто (#{@new_stage}) #{@actor.mention}"
        note += " · причина: #{@reason}" if @reason

        Topnlab::Client.new.set_note(
          id: crm_id.to_i,
          type: 'order',
          note: note,
          user_id: @actor.topnlab_user_id || ENV.fetch('TOPNLAB_FALLBACK_USER_ID', nil)
        )
      rescue StandardError => e
        Rails.logger.warn("[LeadClosure] set_note failed: #{e.class}: #{e.message}")
      end
    end
  end
end
