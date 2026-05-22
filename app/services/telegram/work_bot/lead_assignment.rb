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
        # Phase 13 Iter 44 — wrap всю операцию в @lead.with_lock чтобы
        # два manager'а параллельно (один /assign в группе, другой inline
        # picker в той же секунде) не fire'или transfer_client дважды и
        # не race'или friends на assigned_to / assigned_at.
        #
        # Lock держится через TG calls (~200-500ms) — trade-off correctness
        # > latency. Если станет узким — narrow lock как Phase 9 Iter 13.
        result = nil
        @lead.with_lock do
          @lead.reload

          # Phase 13 Iter 42 — reject reassignment on closed lead (after reload).
          if @lead.current_stage.to_s.start_with?('closed_')
            result = Result.new(false, "Лид уже закрыт (#{@lead.current_stage}). " \
                                       'Возврат — ручной через manager в Topnlab.')
            next # exit with_lock block
          end

          # Phase 11 Iter 22 — capture previous assignee для notification.
          # После reload — это уже актуальное состояние внутри лока.
          prev_assignee = @lead.assigned_to

          # Phase 13 Iter 44 — idempotency: если другой race-winner уже
          # назначил на того же agent, пропускаем mutation + side effects.
          if prev_assignee && prev_assignee.id == @assignee.id
            result = Result.new(true, 'уже назначен (race-winner отработал первым)')
            next
          end

          # Iter 59 — фиксируем originator: FK assigned_by_id для query-индексов
          # + metadata['assign_history'] для аудит-трейла (belt-and-suspenders).
          assign_history_entry = {
            'at' => Time.current.iso8601,
            'by' => @actor.id,
            'by_mention' => @actor.mention,
            'to' => @assignee.id,
            'to_mention' => @assignee.mention,
            'from' => prev_assignee&.mention
          }.compact
          assign_history = @lead.append_history(key: 'assign_history', entry: assign_history_entry, cap: 20)

          @lead.update!(
            assigned_to: @assignee,
            assigned_at: Time.current,
            assigned_by: @actor,
            metadata: @lead.metadata.merge('assign_history' => assign_history)
          )
          push_to_crm                    # internally gated by linked_to_crm? + crm_id
          update_anchor_card!
          notify_assignee                # DM new сотруднику всегда
          notify_previous_assignee(prev_assignee) if prev_assignee && prev_assignee.id != @assignee.id

          warn = @assignee.linked_to_crm? ? nil : 'без CRM sync (нет topnlab_user_id)'
          result = Result.new(true, warn)
        end
        result
      end

      private

      def push_to_crm
        return unless @assignee.linked_to_crm?

        crm_id = @lead.lead_ref.try(:crm_id)
        return if crm_id.blank?

        topnlab = Topnlab::Client.new
        success = with_retry('transfer_client') do
          topnlab.transfer_client(order_id: crm_id.to_i, email: @assignee.email)
        end
        success &&= with_retry('patch_entity_fc') do
          push_fc_fields!(topnlab, crm_id.to_i)
        end

        mark_crm_sync_status!(success: success)
      end

      # Phase 9 Iter 7 — 3-attempt retry с exponential backoff (1s, 2s, 4s).
      # Возвращает true на success, false если все попытки upali. Last error
      # сохраняется в @lead.crm_sync_last_error.
      def with_retry(op_name, max_attempts: 3)
        attempts = 0
        last_error = nil
        begin
          attempts += 1
          yield
          true
        rescue StandardError => e
          last_error = "#{op_name}: #{e.class}: #{e.message.to_s.truncate(160)}"
          Rails.logger.warn("[LeadAssignment##{op_name} attempt=#{attempts}/#{max_attempts}] #{e.message}")
          if attempts < max_attempts
            sleep(2**(attempts - 1)) # 1, 2, 4 seconds
            retry
          end
          @lead.assign_attributes(crm_sync_last_error: last_error)
          # Phase 13 Iter 47 — append к metadata['crm_sync_errors'] (history,
          # last 5 через HISTORY_DEFAULT_CAPS). До этого фикса
          # crm_sync_last_error overwrite'ил, теряя pattern (транзиентный
          # таймаут vs persistent invalid email).
          history = @lead.append_history(
            key: 'crm_sync_errors',
            entry: {
              'at' => Time.current.iso8601,
              'op' => op_name,
              'error' => last_error.to_s.truncate(200),
              'attempts' => attempts
            }
          )
          @lead.assign_attributes(metadata: @lead.metadata.merge('crm_sync_errors' => history))
          false
        end
      end

      def mark_crm_sync_status!(success:)
        return unless @lead.respond_to?(:crm_sync_failed)

        if success
          @lead.update_columns(crm_sync_failed: false, crm_sync_last_error: nil) # rubocop:disable Rails/SkipsModelValidations
        else
          # Phase 9 Iter 7 — persist last error из in-memory assign_attributes
          @lead.update_columns( # rubocop:disable Rails/SkipsModelValidations
            crm_sync_failed: true,
            crm_sync_last_error: @lead.crm_sync_last_error.presence
          )
          notify_crm_failure!
        end
      end

      # Phase 11 Iter 22 — DM previous assignee при reassignment.
      def notify_previous_assignee(prev)
        chat_id = prev.dm_chat_id || prev.tg_user_id
        return if chat_id.blank?

        title = Telegram::TopicRegistry.title(@lead.anchor_topic_key) || @lead.anchor_topic_key
        meta  = @lead.metadata || {}
        name  = meta['name'].to_s.presence || 'клиент'

        text = "🔄 <b>Лид передан</b> · #{escape(name)}\n" \
               "Топик: ##{escape(title)}\n" \
               "Новый ответственный: #{@assignee.mention}\n" \
               "Передал: #{@actor.mention} в #{Formatters::DateFormat.fmt_dt(Time.current)}"

        @client.send_message(text, chat_id: chat_id, parse_mode: 'HTML')
      rescue Telegram::Client::Error => e
        Rails.logger.warn("[LeadAssignment] DM previous #{prev.mention} failed: #{e.message}")
      end

      def notify_crm_failure!
        # Phase 11 Iter 25 — cascade fallback через CriticalRecipients.
        # Если directors неактивны → admins → managers (не теряем alert).
        # Phase 13 Iter 47 — show error history (last 3) для pattern detection.
        history_block = crm_error_history_block

        # Phase 13 Iter 49 — surface tier-info на fallback (manager получает
        # director-level alert).
        cascade = Telegram::CriticalRecipients.resolve
        tier_note = cascade.fallback? ? "\n<i>(routed to #{cascade.tier} tier — directors недоступны)</i>" : ''

        cascade.each do |recipient|
          chat_id = recipient.dm_chat_id || recipient.tg_user_id
          next if chat_id.blank?

          text = "⚠️ <b>CRM sync failed</b> на лиде ##{@lead.id}\n" \
                 "Assignee: #{@assignee.mention}\n" \
                 "Error: <code>#{@lead.crm_sync_last_error.to_s[0, 200]}</code>\n" \
                 "#{history_block}\n" \
                 "<i>Назначение проведено локально. Topnlab CRM требует ручной sync.</i>#{tier_note}"
          @client.send_message(text, chat_id: chat_id, parse_mode: 'HTML')
        rescue Telegram::Client::Error => e
          Rails.logger.warn("[LeadAssignment] notify_crm_failure DM failed: #{e.message}")
        end
      end

      # Phase 13 Iter 47 — собирает последние 3 CRM-sync errors из metadata
      # для visible pattern detection в alert DM. Если history пустая —
      # возвращает '' (no decoration).
      def crm_error_history_block
        history = Array(@lead.reload.metadata['crm_sync_errors']).last(3)
        return '' if history.empty?

        lines = history.map.with_index do |e, i|
          ts = (Time.zone.parse(e['at'].to_s).strftime('%d.%m %H:%M') rescue 'unknown')
          "  #{i + 1}. [#{ts}] #{e['op']}: #{e['error'].to_s.truncate(80)}"
        end
        "Последние ошибки:\n#{lines.join("\n")}\n"
      rescue StandardError => err
        Rails.logger.warn("[LeadAssignment#crm_error_history_block] #{err.message}")
        ''
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
        # Phase 9 Iter 7 — raise instead of silent rescue (used in with_retry above).
        # Caller (push_to_crm) handles retry + status tracking.
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
               "Передал: #{@actor.mention} в #{Formatters::DateFormat.fmt_dt(Time.current)}"

        link = @lead.anchor_url
        text += "\n\n<a href=\"#{link}\">Открыть карточку</a>" if link.present?

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
