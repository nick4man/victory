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
        unless @assignee.linked_to_crm?
          msg = "#{@assignee.mention} не привязан к CRM (нет email). " \
                'Попроси агента написать /whoami email@victory.ru в DM боту.'
          return Result.new(false, msg)
        end

        push_to_crm
        @lead.update!(assigned_to: @assignee, assigned_at: Time.current)
        update_anchor_card!
        notify_assignee

        Result.new(true, nil)
      end

      private

      def push_to_crm
        crm_id = @lead.lead_ref.try(:crm_id)
        return if crm_id.blank?

        Topnlab::Client.new.transfer_client(order_id: crm_id.to_i, email: @assignee.email)
      rescue Topnlab::Client::Error => e
        # Best-effort: CRM может временно недоступен. В TG-чате назначение уже произошло.
        Rails.logger.warn("[LeadAssignment] transfer_client failed: #{e.class}: #{e.message}")
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
