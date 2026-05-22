# frozen_string_literal: true

module Telegram
  module WorkBot
    module Commands
      # `/note <текст>` reply на якорную карточку — добавляет публичную ноту в
      # Topnlab CRM через set_note + сохраняет копию в LeadEvent.metadata['notes'].
      # Если у лида нет crm_id (no_crm-режим) — нота остаётся только локально.
      class Note < Base
        def handle
          # Phase 15 — resolve_lead! сначала consume lead_id если в DM.
          lead = resolve_lead!
          return reply(lead_not_found_hint('note <текст>')) unless lead

          text = @args.to_s.strip
          return reply('Формат: <code>/note &lt;текст&gt;</code> (reply) ИЛИ <code>/note &lt;lead_id&gt; &lt;текст&gt;</code> (DM).') if text.blank?

          return reply("🚫 Заметку добавляет только assignee (#{lead.assigned_to&.mention || 'не назначен'}) или manager.") unless assignee_or_manager?(lead)

          push_to_crm(lead, text)
          persist_to_metadata(lead, text)

          reply("Лид ##{lead.id}: записал в CRM ✅")
        end

        private

        def push_to_crm(lead, text)
          crm_id = lead.lead_ref.try(:crm_id)
          return if crm_id.blank?

          Topnlab::Client.new.set_note(
            id: crm_id.to_i,
            type: 'order',
            note: "#{tg_user.mention}: #{text}",
            user_id: tg_user.topnlab_user_id || ENV.fetch('TOPNLAB_FALLBACK_USER_ID', nil)
          )
        rescue StandardError => e
          Rails.logger.warn("[Commands::Note] set_note failed: #{e.class}: #{e.message}")
        end

        def persist_to_metadata(lead, text)
          # Phase 12 Iter 39 — cap notes at HISTORY_DEFAULT_CAPS['notes'] (50)
          # через LeadEvent#append_history. Anti-bloat при долгоживущих лидах.
          notes = lead.append_history(
            key: 'notes',
            entry: {
              'at' => Time.current.iso8601,
              'by' => tg_user.tg_username,
              'text' => text.to_s[0, 1000]
            }
          )
          lead.update!(metadata: lead.metadata.merge('notes' => notes))
        end
      end
    end
  end
end
