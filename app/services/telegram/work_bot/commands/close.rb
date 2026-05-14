# frozen_string_literal: true

module Telegram
  module WorkBot
    module Commands
      # `/close выиграно` / `/close проиграно причина:цена` — закрывает лид.
      # Эффективно делает то же, что `/stage выиграно`, плюс парсит causes и
      # пишет причину в LeadEvent.metadata['close_reason'] + Topnlab note.
      #
      # Manager-only: проигранный лид требует подтверждения руководителя
      # (предотвращает быстрое закрытие агентом без эскалации).
      class Close < Base
        manager_only

        OUTCOME_MAP = {
          'выиграно' => 'closed_won',
          'победа' => 'closed_won',
          'won' => 'closed_won',
          'проиграно' => 'closed_lost',
          'отказ' => 'closed_lost',
          'lost' => 'closed_lost'
        }.freeze

        def handle
          outcome_key, reason = parse_args
          new_stage = OUTCOME_MAP[outcome_key.to_s.downcase]
          unless new_stage
            return reply('Формат: <code>/close выиграно</code> или <code>/close проиграно причина:цена</code>')
          end

          lead = find_lead_via_reply
          return reply('⚠️ Команда должна быть reply на якорную карточку лида.') unless lead

          apply_close!(lead, new_stage, reason)
          update_anchor_card!(lead)
          push_close_note(lead, new_stage, reason)

          icon = new_stage == 'closed_won' ? '✅' : '❌'
          msg  = "#{icon} Закрыто: <b>#{new_stage}</b>"
          msg += " (#{reason})" if reason.present?
          reply(msg)
        end

        private

        def parse_args
          parts = args.to_s.strip.split(/\s+/, 2)
          [parts[0], parts[1].to_s.sub(/\A(причина|reason)\s*:\s*/i, '').presence]
        end

        def find_lead_via_reply
          reply_to = message['reply_to_message']
          return nil unless reply_to

          LeadEvent.find_by(anchor_message_id: reply_to['message_id'])
        end

        def apply_close!(lead, new_stage, reason)
          meta = lead.metadata.merge('close_reason' => reason).compact
          lead.update!(current_stage: new_stage, closed_at: Time.current, metadata: meta)
        end

        def update_anchor_card!(lead)
          return if lead.anchor_message_id.blank?

          text = Telegram::WorkBot::LeadAnnouncer.new(lead, client: client).format_card_text
          client.edit_message_text(
            text,
            chat_id: lead.tg_chat_id,
            message_id: lead.anchor_message_id,
            parse_mode: 'HTML'
          )
        rescue StandardError => e
          Rails.logger.warn("[Commands::Close] edit_message_text failed: #{e.message}")
        end

        def push_close_note(lead, new_stage, reason)
          crm_id = lead.lead_ref.try(:crm_id)
          return if crm_id.blank?

          icon = new_stage == 'closed_won' ? '✅' : '❌'
          note = "#{icon} Закрыто (#{new_stage}) #{tg_user.mention}"
          note += " · причина: #{reason}" if reason.present?

          Topnlab::Client.new.set_note(
            id: crm_id.to_i,
            type: 'order',
            note: note,
            user_id: tg_user.topnlab_user_id || ENV.fetch('TOPNLAB_FALLBACK_USER_ID', nil)
          )
        rescue StandardError => e
          Rails.logger.warn("[Commands::Close] set_note failed: #{e.class}: #{e.message}")
        end
      end
    end
  end
end
