# frozen_string_literal: true

module DocumentChecklist
  # Phase 4F — Sends document-reminder DM per SlaAssessor tier.
  #
  # Tier dispatch:
  #   1 (client_gentle):    DM client (Inquiry.client_tg_user_id)
  #   2 (manager_dm):       DM assigned agent + CC manager (assignee → lead.assigned_to)
  #   3 (director_cascade): CriticalRecipients (Phase 11 Iter 25 cascade)
  #
  # AlertThrottle key: per (lead_id, dr_id, tier) — fail-safe re-window
  # на случай если SlaAssessor rewindow gets gamed by clock changes.
  #
  # Post-send: increment reminder_count + set last_reminder_at + metadata
  # ['last_reminder_tier'] = tier.
  #
  # Soft-fail на любую TG error → logs warn, не блокирует.
  class ReminderSender
    Result = Struct.new(:sent, :tier, :recipients_count, :error, keyword_init: true) do
      def success?
        sent && error.nil?
      end
    end

    def self.call(...)
      new(...).call
    end

    def initialize(requirement:, tier:, tg_client: ::Telegram::Client.new)
      @dr = requirement
      @tier = tier
      @tg_client = tg_client
    end

    def call
      throttle_key = "doc_reminder:#{lead.id}:#{@dr.id}:tier#{@tier}"
      return Result.new(sent: false, tier: @tier, error: 'throttled') unless throttle_allow?(throttle_key)

      recipients_count = case @tier
                         when 1 then send_tier1_client_gentle
                         when 2 then send_tier2_manager_dm
                         when 3 then send_tier3_director_cascade
                         else 0
                         end

      mark_sent! if recipients_count.positive?
      Result.new(sent: recipients_count.positive?, tier: @tier,
                 recipients_count: recipients_count, error: nil)
    rescue StandardError => e
      Rails.logger.error("[ReminderSender] dr##{@dr.id} tier=#{@tier}: #{e.class}: #{e.message}")
      Result.new(sent: false, tier: @tier, error: e.message)
    end

    private

    # === Tier 1: gentle reminder to client ===
    def send_tier1_client_gentle
      client_chat_id = client_dm_chat_id
      return 0 if client_chat_id.blank?

      text = "👋 Здравствуйте!\n" \
             "Напоминаю — для оформления сделки нужен <b>#{@dr.ru_label}</b>.\n" \
             "Если уже отправляли — извините за беспокойство. Если нет — пришлите фото или скан.\n\n" \
             "<i>С уважением, АН «Виктори».</i>"

      send_dm(client_chat_id, text)
      1
    end

    # === Tier 2: firm reminder to assigned agent + lead's manager ===
    def send_tier2_manager_dm
      sent_count = 0

      # Direct agent reminder
      if assignee
        chat_id = assignee.dm_chat_id || assignee.tg_user_id
        text = "⚠️ <b>Просрочка документа</b>\n" \
               "Лид ##{lead.id} (#{lead_name}), документ: <b>#{@dr.ru_label}</b>\n" \
               "Запрошен #{requested_ago_str} назад (SLA × #{overdue_factor_str}).\n\n" \
               "<i>Свяжись с клиентом и подтолкни. Или /doc #{kind_alias}- если уже не актуально.</i>"
        send_dm(chat_id, text) && sent_count += 1
      end

      sent_count
    end

    # === Tier 3: cascade alert через CriticalRecipients ===
    def send_tier3_director_cascade
      cascade = ::Telegram::CriticalRecipients.resolve
      tier_note = cascade.fallback? ? "\n<i>(routed to #{cascade.tier} tier — directors недоступны)</i>" : ''

      text = "🚨 <b>Критическая просрочка документа</b>\n" \
             "Лид ##{lead.id} (#{lead_name}), документ: <b>#{@dr.ru_label}</b>\n" \
             "Просрочка <b>×#{overdue_factor_str}</b> от SLA (#{requested_ago_str} с запроса).\n" \
             "Assignee: #{assignee&.mention || '(не назначен)'}\n\n" \
             "<i>Не реагирует на reminders. Требует вмешательства.</i>#{tier_note}"

      sent_count = 0
      cascade.each do |recipient|
        chat_id = recipient.dm_chat_id || recipient.tg_user_id
        next if chat_id.blank?

        send_dm(chat_id, text) && sent_count += 1
      end
      sent_count
    end

    def mark_sent!
      @dr.with_lock do
        @dr.update_columns( # rubocop:disable Rails/SkipsModelValidations
          last_reminder_at: Time.current,
          reminder_count: @dr.reminder_count + 1,
          metadata: @dr.metadata.merge(
            'last_reminder_tier' => @tier,
            'last_reminder_factor' => @dr.overdue_factor&.round(3)
          )
        )
      end
    end

    def send_dm(chat_id, text)
      @tg_client.send_message(text, chat_id: chat_id, parse_mode: 'HTML')
      true
    rescue ::Telegram::Client::Error => e
      Rails.logger.warn("[ReminderSender] DM to #{chat_id} failed: #{e.message}")
      false
    end

    def throttle_allow?(key)
      ::Telegram::AlertThrottle.allow?(key: key)
    end

    # === Helpers ===

    def lead
      @lead ||= @dr.lead_event
    end

    def assignee
      lead&.assigned_to
    end

    def lead_name
      (lead&.metadata || {})['name'] || 'клиент'
    end

    # Inquiry.client_tg_user_id doubles as DM chat_id для private (TG: chat.id = from.id).
    def client_dm_chat_id
      inquiry = lead&.lead_ref
      return nil unless inquiry.is_a?(Inquiry)

      inquiry.client_tg_user_id
    end

    def requested_ago_str
      return '?' if @dr.requested_at.blank?

      seconds = (Time.current - @dr.requested_at).to_i
      return "#{(seconds / 3600.0).round(1)}ч" if seconds < 86_400

      "#{(seconds / 86_400.0).round(1)}д"
    end

    def overdue_factor_str
      f = @dr.overdue_factor
      f ? f.round(2).to_s : '?'
    end

    def kind_alias
      ::DocumentRequirement::KIND_ALIASES.find { |_alias, k| k == @dr.kind }&.first || @dr.kind
    end
  end
end
