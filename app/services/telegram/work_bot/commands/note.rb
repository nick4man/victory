# frozen_string_literal: true

module Telegram
  module WorkBot
    module Commands
      # `/note <текст>` reply на якорную карточку — добавляет публичную ноту в
      # Topnlab CRM через set_note + сохраняет копию в LeadEvent.metadata['notes'].
      # Если у лида нет crm_id (no_crm-режим) — нота остаётся только локально.
      class Note < Base
        def handle
          text = args.to_s.strip
          return reply('Формат: <code>/note &lt;текст&gt;</code> (reply на якорную карточку).') if text.blank?

          lead = find_lead_via_reply
          return reply('⚠️ Команда должна быть reply на якорную карточку лида.') unless lead

          push_to_crm(lead, text)
          persist_to_metadata(lead, text)

          reply('Записал в CRM ✅')
        end

        private

        def find_lead_via_reply
          reply_to = message['reply_to_message']
          return nil unless reply_to

          LeadEvent.find_by(anchor_message_id: reply_to['message_id'])
        end

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
          notes = lead.metadata['notes'] || []
          notes << {
            'at' => Time.current.iso8601,
            'by' => tg_user.tg_username,
            'text' => text.to_s[0, 1000]
          }
          lead.update!(metadata: lead.metadata.merge('notes' => notes))
        end
      end
    end
  end
end
