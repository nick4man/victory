# frozen_string_literal: true

module Telegram
  module WorkBot
    module Wizard
      # Шаг «по какому лиду» для мастеров, работающих с LeadEvent.
      #
      # В группе лид приходит с кнопкой на карточке (lead_id в callback_data),
      # и шаг пропускается. В личке reply-на-якорь нет, поэтому лид выбирается
      # списком последних открытых, а ручной ввод номера — запасной путь с
      # проверкой существования.
      module LeadPicking
        RECENT_LIMIT = 5

        def lead_step
          Flow::Step.new(
            id: 'lead', kind: :choice, per_row: 1,
            prompt: recent_leads.any? ? 'По какому лиду?' : 'По какому лиду? Открытых лидов в списке нет.',
            hint: 'Номер лида виден в карточке: «лид #87».',
            options: recent_leads.map { |l| [lead_label(l), l.id.to_s] },
            manual: '⌨️ Ввести номер лида',
            manual_prompt: 'Напиши номер лида цифрами.'
          )
        end

        def lead
          return @lead if defined?(@lead)

          @lead = ctx['lead'].present? ? ::LeadEvent.find_by(id: ctx['lead']) : nil
        end

        # @return [Array(String, String|nil)]
        def accept_lead(value)
          raw = value.to_s.strip.delete_prefix('#')
          return [nil, "Номер лида — целое число. Получено: «#{escape_html(raw)}»."] unless raw.match?(/\A\d+\z/)

          found = ::LeadEvent.find_by(id: raw.to_i)
          return [nil, "Лид ##{raw} не найден. Проверь номер или выбери из списка."] unless found
          return [nil, "Лид ##{raw} уже закрыт (#{found.current_stage})."] unless found.open?

          [found.id.to_s, nil]
        end

        # Отказ до первого вопроса, если лид пришёл с карточки, но не годится.
        def lead_gate
          return nil if ctx['lead'].blank?
          return "⚠️ Лид ##{escape_html(ctx['lead'])} не найден." unless lead
          return "ℹ️ Лид ##{lead.id} уже закрыт (#{lead.current_stage})." unless lead.open?

          nil
        end

        private

        def recent_leads
          @recent_leads ||= begin
            scope = ::LeadEvent.open.order(updated_at: :desc)
            scope = scope.for_agent(tg_user) unless manager?
            scope.limit(RECENT_LIMIT).to_a
          end
        end

        def lead_label(lead)
          meta = lead.metadata || {}
          parts = ["##{lead.id}"]
          parts << meta['name'].to_s.split.first if meta['name'].present?
          about = meta['summary'].presence || lead.lead_ref.try(:title)
          parts << about.to_s.squish.truncate(40) if about.present?
          parts.join(' · ')
        end
      end
    end
  end
end
