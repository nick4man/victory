# frozen_string_literal: true

module Telegram
  module WorkBot
    module Callbacks
      # Клик [🚫 Спам] под якорной карточкой — пометить лид как спам.
      # callback_data: "spam:<lead_event_id>"
      #
      # Эффект:
      #   1. В CRM: patch_entity(fc_is_spam: true) + set_note "spam reported by @user"
      #   2. Удаляет якорную карточку (своё сообщение бота — без admin-прав)
      #   3. Удаляет dispatcher_message_id, если он отличается от anchor (защита
      #      от двойного удаления когда лид ещё в #ДИСПЕТЧЕРСКОЙ)
      #   4. Удаляет deal_mirror_message_id, если есть зеркало в #СДЕЛКА
      #   5. LeadEvent.update!(current_stage: 'closed_lost', closed_at: now)
      #
      # Manager-only — деструктивная операция.
      class SpamCallback < Base
        manager_only

        def handle
          lead = lead_event
          tag_in_crm(lead)
          delete_anchor_messages(lead)
          lead.update!(
            current_stage: 'closed_lost',
            closed_at: Time.current,
            metadata: lead.metadata.merge('spam_marked_by' => actor_mention,
                                          'spam_marked_at' => Time.current.iso8601)
          )

          ack('🚫 Помечено как спам')
        end

        private

        def tag_in_crm(lead)
          crm_id = lead.lead_ref.try(:crm_id)
          return if crm_id.blank?

          topnlab = Topnlab::Client.new
          begin
            topnlab.patch_entity(id: crm_id.to_i, type: 'order', fields: { fc_is_spam: true })
          rescue StandardError => e
            Rails.logger.warn("[SpamCallback] patch_entity failed: #{e.class}: #{e.message}")
          end

          begin
            topnlab.set_note(
              id: crm_id.to_i,
              type: 'order',
              note: "🚫 Спам по сообщению #{actor_mention} (#{Formatters::DateFormat.fmt_dt(Time.current)})",
              user_id: tg_user.topnlab_user_id || ENV.fetch('TOPNLAB_FALLBACK_USER_ID', nil)
            )
          rescue StandardError => e
            Rails.logger.warn("[SpamCallback] set_note failed: #{e.class}: #{e.message}")
          end
        end

        def delete_anchor_messages(lead)
          # Уникальные message_ids к удалению — anchor, dispatcher, deal_mirror.
          # Если anchor == dispatcher (лид всё ещё в General-топике) — Set убирает дубль.
          ids = [lead.anchor_message_id, lead.dispatcher_message_id, lead.deal_mirror_message_id].compact.uniq
          ids.each do |mid|
            client.delete_message(chat_id: lead.tg_chat_id, message_id: mid)
          rescue Telegram::Client::Error => e
            Rails.logger.warn("[SpamCallback] delete_message(#{mid}) failed (ok if idempotent): #{e.message}")
          end
        end
      end
    end
  end
end
