# frozen_string_literal: true

module Telegram
  module WorkBot
    module Wizard
      # Мастер «Новый объект в CRM». Спрашивает обязательное и условно
      # обязательное (комнаты для квартиры, номер для агентского договора);
      # прочее — через «Изменить поле», чтобы заводить объект по телефону
      # не приходилось через шестнадцать вопросов.
      #
      # До шлюза к внутреннему API объект в CRM вносится вручную после
      # одобрения (CrmCardManualExportFlow).
      class CrmObjectCardFlow < Flow
        include CrmCardSupport

        flow 'crm_object', 'Новый объект в CRM'

        def steps
          [paste_step('object')] + ::CrmCards::Schema.for('object').map { |field| field_step(field) } +
            [Flow::Step.new(id: 'confirm', kind: :confirm,
                            prompt: 'Сохранить карточку объекта? Дальше — машинная проверка.',
                            confirm_label: '💾 Сохранить и проверить')]
        end

        def skip?(step)
          field = ::CrmCards::Schema.field('object', step.id)
          return false if field.nil?

          _, error = ::CrmCards::FieldValue.normalize(field, pasted_values[field.key])
          return true if error.nil? && pasted_values[field.key].present?
          return false if field.required

          !::CrmCards::Checker.conditionally_required(answers).include?(field.key)
        end

        def gate
          return "🚫 #{escape_html(permissions.denial)}" if permissions.denial
          return '🚫 Твоей должности в CRM не выдано право заводить объекты.' unless permissions.can?(:create_object)

          nil
        end

        def accept(step, value, manual: false)
          return accept_paste('object', value) if step.id == 'paste'

          field = ::CrmCards::Schema.field('object', step.id)
          field ? accept_field(field, value) : [value, nil]
        end

        def finish
          result_view(workflow.create_object_card!(actor: tg_user, values: answers))
        end

        private

        def answers
          pasted_values.merge(::CrmCards::Schema.for('object').to_h { |f| [f.key, ctx[f.key]] }.compact)
        end
      end
    end
  end
end
