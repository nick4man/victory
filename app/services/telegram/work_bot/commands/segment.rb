# frozen_string_literal: true

module Telegram
  module WorkBot
    module Commands
      # BOTTLENECK — `/segment <значение>` reply на карточку или `/segment <lead_id> <значение>` в DM.
      # Дублёр кнопок SegmentKeyboard для тех, кому привычнее текст.
      # Без значения — присылает клавиатуру.
      class Segment < Base
        SEGMENT_MAP = {
          'наличные'            => 'cash',
          'нал'                 => 'cash',
          'кэш'                 => 'cash',
          'ипотека одобрена'    => 'mortgage_approved',
          'ипотека+'            => 'mortgage_approved',
          'одобрена'            => 'mortgage_approved',
          'ипотека не одобрена' => 'mortgage_pending',
          'ипотека?'            => 'mortgage_pending',
          'ипотека'             => 'mortgage_pending',
          'альтернатива'        => 'alternative',
          'альт'                => 'alternative',
          'холодный'            => 'cold',
          'холод'               => 'cold'
        }.freeze

        def handle
          lead = resolve_lead!
          return reply(lead_not_found_hint('segment наличные')) unless lead

          word = @args.to_s.strip.downcase
          if word.blank?
            return reply("#{SegmentKeyboard.prompt_text}\nСейчас: #{lead.segment_label}",
                         reply_markup: SegmentKeyboard.for(lead))
          end

          value = SEGMENT_MAP[word]
          return reply("Не понял сегмент. Доступно: <code>#{SEGMENT_MAP.keys.join(', ')}</code>") unless value
          return reply("🚫 Сегмент ставит assignee (#{lead.assigned_to&.mention || 'не назначен'}) или руководитель.") unless assignee_or_manager?(lead)

          lead.apply_segment!(value, by: tg_user.mention)
          LeadAnnouncer.refresh!(lead, client: client)
          reply("Лид ##{lead.id}: #{lead.segment_label} ✅")
        end
      end
    end
  end
end
