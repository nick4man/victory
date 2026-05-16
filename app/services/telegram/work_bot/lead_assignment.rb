# frozen_string_literal: true

module Telegram
  module WorkBot
    # Назначение лида агенту АН — общая логика для `/assign @username` (текстовая
    # команда) и `assign_to:<lead>:<user>` (inline callback из списка).
    #
    # Что делает:
    #   1. Валидирует что у assignee есть привязка к CRM (`linked_to_crm?`)
    #   2. Дёргает `Topnlab::Client#transfer_client` если у лида есть crm_id (best-effort)
    #   3. Обновляет `LeadEvent.assigned_to` + `assigned_at`
    #   4. Редактирует якорную карточку — добавляется строка «👤 Назначен: …»
    #   5. Шлёт DM назначенному агенту со ссылкой на якорь
    #
    # Возвращает Result-структуру со `success?` и `error_message`.
    class LeadAssignment
      Result = Struct.new(:success, :error_message) do
        def success?
          success
        end
      end

      def initialize(lead_event, assignee:, actor:, client: Telegram::Client.new)
        @lead     = lead_event
        @assignee = assignee
        @actor    = actor
        @client   = client
      end

      def call
        @lead.update!(assigned_to: @assignee, assigned_at: Time.current)
        push_to_crm                    # internally gated by linked_to_crm? + crm_id
        update_anchor_card!
        notify_assignee                # DM сотруднику всегда, независимо от CRM

        warn = @assignee.linked_to_crm? ? nil : 'без CRM sync (нет topnlab_user_id)'
        Result.new(true, warn)
      end

      private

      def push_to_crm
        return unless @assignee.linked_to_crm?

        crm_id = @lead.lead_ref.try(:crm_id)
        return if crm_id.blank?

        topnlab = Topnlab::Client.new
        begin
          topnlab.transfer_client(order_id: crm_id.to_i, email: @assignee.email)
        rescue Topnlab::Client::Error => e
          Rails.logger.warn("[LeadAssignment] transfer_client failed: #{e.class}: #{e.message}")
        end

        push_fc_fields!(topnlab, crm_id.to_i)
      end

      # Phase 3 — заполняем fc_* кастомные поля Topnlab при назначении.
      # Эти поля должны быть заранее созданы в Topnlab UI руководителем АН
      # (см. .claude/docs/topnlab/fc_fields_setup.md). Если поля нет — patch_entity
      # просто молча игнорирует unknown ключ, лид этим не страдает.
      def push_fc_fields!(topnlab, crm_id)
        fields = {
          fc_tg_assigned_user: @assignee.topnlab_user_id,
          fc_first_contact_due: 30.minutes.from_now.iso8601,
          fc_lead_source_tg: true,
          fc_tg_topic_key: @lead.anchor_topic_key,
          fc_tg_lead_event_id: @lead.id
        }.compact
        topnlab.patch_entity(id: crm_id, type: 'order', fields: fields)
      rescue StandardError => e
        Rails.logger.warn("[LeadAssignment] patch_entity fc_* failed: #{e.class}: #{e.message}")
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
        Rails.logger.warn("[LeadAssignment] edit_message_text failed: #{e.class}: #{e.message}")
      end

      def notify_assignee
        chat_id = @assignee.dm_chat_id || @assignee.tg_user_id
        return if chat_id.blank?

        title = Telegram::TopicRegistry.title(@lead.anchor_topic_key) || @lead.anchor_topic_key
        meta  = @lead.metadata || {}
        name  = meta['name'].to_s.presence || 'клиент'

        text = "🆕 Тебе назначен лид · <b>#{escape(name)}</b>\n" \
               "Топик: ##{escape(title)}\n" \
               "Передал: #{@actor.mention} в #{Formatters::DateFormat.fmt_dt(Time.current)}\n\n" \
               "<a href=\"#{@lead.anchor_url}\">Открыть карточку</a>"

        @client.send_message(text, chat_id: chat_id, parse_mode: 'HTML')
      rescue Telegram::Client::Error => e
        Rails.logger.warn("[LeadAssignment] DM to #{@assignee.mention} failed: #{e.message}")
      end

      def escape(text)
        text.to_s.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;')
      end
    end
  end
end
