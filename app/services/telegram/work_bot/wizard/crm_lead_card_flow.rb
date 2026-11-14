# frozen_string_literal: true

module Telegram
  module WorkBot
    module Wizard
      # Мастер «Карточка заявки для CRM»: ответственный после разговора с
      # клиентом дозаполняет то, чего нет в лиде, и получает карточку с итогом
      # машинной проверки и кнопкой «На модерацию».
      #
      # Спрашивает только незаполненное обязательное: имя и телефон приходят
      # из лида, заполненное в черновике не повторяется. Необязательные поля —
      # через «Изменить поле». Последний шаг — подтверждение: мастер без
      # вопросов Engine не завершает, а для полного черновика так и было бы.
      class CrmLeadCardFlow < Flow
        include CrmCardSupport

        flow 'crm_lead', 'Карточка заявки для CRM'

        def steps
          ::CrmCards::Schema.for('lead').map { |field| field_step(field) } +
            [Flow::Step.new(id: 'confirm', kind: :confirm,
                            prompt: 'Сохранить карточку заявки? Дальше — машинная проверка.',
                            confirm_label: '💾 Сохранить и проверить')]
        end

        def skip?(step)
          field = ::CrmCards::Schema.field('lead', step.id)
          return false unless field
          return true unless field.required

          _, error = ::CrmCards::FieldValue.normalize(field, known_values[field.key])
          error.nil?
        end

        def gate
          return '⚠️ Карточку заявки открывают кнопкой «📋 Карточка CRM» под лидом.' unless lead
          return "ℹ️ Лид ##{lead.id} уже закрыт (#{lead.current_stage}) — карточку заводить нечего." if lead.closed?
          return "🚫 #{escape_html(permissions.denial)}" if permissions.denial
          return '🚫 Твоей должности в CRM не выдано право заводить заявки.' unless permissions.can?(:create_lead)

          unless lead.assigned_to_id == tg_user.id || permissions.can?(:moderate)
            responsible = lead.assigned_to&.mention || 'пока никто не назначен'
            return "🚫 Карточку заполняет ответственный по лиду: #{escape_html(responsible)}."
          end
          if existing && !::CrmCard::AUTHOR_EDITABLE.include?(existing.status)
            return "ℹ️ Карточка ##{existing.id} по этому лиду — #{::CrmCard::STATUS_LABELS[existing.status]}. " \
                   'Открой её через /cards.'
          end

          nil
        end

        def accept(step, value, manual: false)
          field = ::CrmCards::Schema.field('lead', step.id)
          field ? accept_field(field, value) : [value, nil]
        end

        def finish
          return { text: '⚠️ Лид не найден — карточка не сохранена.' } unless lead

          answers = ::CrmCards::Schema.for('lead').to_h { |f| [f.key, ctx[f.key]] }.compact
          result_view(workflow.upsert_lead_card!(lead: lead, actor: tg_user, values: known_values.merge(answers)))
        end

        private

        def lead
          return @lead if defined?(@lead)

          @lead = ctx['lead'].to_s.match?(/\A\d+\z/) ? ::LeadEvent.find_by(id: ctx['lead']) : nil
        end

        def existing
          return @existing if defined?(@existing)

          @existing = lead && ::CrmCard.kind_lead.find_by(lead_event_id: lead.id)
        end

        # Известное заранее: черновик поверх данных, пришедших с лидом.
        def known_values
          @known_values ||= prefill.merge(existing&.payload.to_h)
        end

        def prefill
          meta = lead&.metadata.to_h
          values = {}
          name = meta['name'].to_s.strip
          values['name'] = name if name.present? && name != 'Без имени'
          phone, error = ::CrmCards::FieldValue.phone(meta['phone'].to_s)
          values['phone'] = phone unless error
          external_id = lead&.property&.external_id.to_s
          values['realty_id'] = external_id.to_i if external_id.match?(/\A\d+\z/)
          values
        end
      end
    end
  end
end
