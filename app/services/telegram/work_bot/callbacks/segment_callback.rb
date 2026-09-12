# frozen_string_literal: true

module Telegram
  module WorkBot
    module Callbacks
      # BOTTLENECK — кнопка сегмента под карточкой лида.
      # callback_data: "segment:<lead_event_id>:<value>", value ∈ LeadEvent::SEGMENTS.
      #
      # Не manager_only: сегмент выясняет тот, кто ведёт переписку, то есть
      # assignee. Проверку делаем сами, а не макросом — manager_only в
      # Callbacks::Base смотрит is_manager? и отсекает директора без флага
      # (в Commands::Base тот же гейт уже починен на manager_or_director?).
      class SegmentCallback < Base
        def handle
          value = @args[1].to_s
          return ack("⚠️ Неизвестный сегмент: #{value}", alert: true) unless LeadEvent::SEGMENTS.include?(value)

          lead = lead_event
          return ack('🚫 Сегмент ставит assignee лида или руководитель', alert: true) unless authorized?(lead)
          return ack("ℹ️ Уже #{lead.segment_label}") if lead.segment == value

          lead.with_lock do
            lead.reload
            history = lead.append_history(key: 'segment_history',
                                          entry: { 'at' => Time.current.iso8601, 'from' => lead.segment,
                                                   'to' => value, 'by' => actor_mention })
            lead.update!(segment: value, metadata: lead.metadata.merge('segment_history' => history))
          end
          refresh_card(lead)
          ack("✅ #{lead.segment_label}")
        end

        private

        def authorized?(lead)
          return false if tg_user.nil?

          lead.assigned_to_id == tg_user.id || tg_user.manager_or_director?
        end

        def refresh_card(lead)
          return if lead.anchor_message_id.blank?

          text = LeadAnnouncer.new(lead, client: client).format_card_text
          client.edit_message_text(text, chat_id: lead.tg_chat_id, message_id: lead.anchor_message_id,
                                         parse_mode: 'HTML',
                                         reply_markup: LeadAnnouncer.new(lead, client: client).keyboard_for_card)
        rescue Telegram::Client::Error => e
          Rails.logger.warn("[SegmentCallback] card refresh failed: #{e.message}")
        end
      end
    end
  end
end
