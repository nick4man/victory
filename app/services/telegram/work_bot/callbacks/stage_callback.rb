# frozen_string_literal: true

module Telegram
  module WorkBot
    module Callbacks
      # BOTTLENECK — «единственное новое действие, которое ложится на людей» —
      # движение лида по стадиям — должно быть одним нажатием, иначе базовая
      # линия не соберётся. callback_data: "stage:<lead_event_id>:show|contract".
      # Только две кнопки: закрытие (/close) и откат (/unstage) остаются текстом —
      # это редкие и осознанные действия.
      class StageCallback < Base
        ALLOWED = ['show', 'contract'].freeze

        def handle
          stage = @args[1].to_s
          return ack("⚠️ Кнопкой доступно: #{ALLOWED.join(', ')}", alert: true) unless ALLOWED.include?(stage)

          lead = lead_event
          return ack('🚫 Стадию меняет assignee или руководитель', alert: true) unless authorized?(lead)
          return ack("ℹ️ Лид уже в стадии #{stage}") if lead.current_stage == stage

          result = LeadStageTransition.new(lead, stage, actor: tg_user, client: client).call
          return ack("⚠️ #{result.message}", alert: true) unless result.success?

          nudge_segment(lead.reload) if stage == 'show' && lead.segment.blank?
          propose_conductor(lead) if stage == 'show' && ShowRouting.enabled? && lead.segment.present?
          ack("#{result.prev_stage} → #{result.new_stage} ✅")
        end

        private

        def authorized?(lead)
          return false if tg_user.nil?

          lead.assigned_to_id == tg_user.id || tg_user.manager_or_director?
        end

        def nudge_segment(lead)
          reply_in_topic(SegmentKeyboard.prompt_text, reply_markup: SegmentKeyboard.for(lead))
        rescue Telegram::Client::Error => e
          Rails.logger.warn("[StageCallback] segment nudge failed: #{e.message}")
        end

        # BOTTLENECK — фильтр «кто едет». Только при включённом флаге и известном сегменте.
        def propose_conductor(lead)
          rec = ShowRouting.recommend(lead)
          reply_in_topic(ShowRouting.prompt_text(lead, rec), reply_markup: ShowRouting.keyboard(lead))
        rescue Telegram::Client::Error => e
          Rails.logger.warn("[StageCallback] routing prompt failed: #{e.message}")
        end
      end
    end
  end
end
