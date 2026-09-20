# frozen_string_literal: true

module Telegram
  module WorkBot
    module Wizard
      # Мастер «Изменить поле карточки CRM»: поле → новое значение →
      # подтверждение. Один мастер на доработку автором и на правку
      # модератором во время модерации — кто может править, решает Workflow.
      class CrmCardEditFlow < Flow
        include CrmCardSupport

        flow 'crm_edit', 'Изменить поле карточки CRM'

        def steps
          return [] unless card

          list = [Flow::Step.new(id: 'field', kind: :choice, per_row: 1,
                                 prompt: "Какое поле карточки ##{card.id} изменить?",
                                 options: schema.map { |f| [field_button(f), f.key] })]
          return list unless chosen

          list << field_step(chosen, id: 'value', prompt: "#{chosen.label} — новое значение?",
                                     clearable: !chosen.required)
          list << Flow::Step.new(id: 'confirm', kind: :confirm, prompt: confirm_prompt,
                                 confirm_label: published? ? '✏️ Отправить на согласование' : '💾 Сохранить')
        end

        def gate
          return '⚠️ Карточка не найдена.' unless card
          return "🚫 #{escape_html(permissions.denial)}" if permissions.denial
          return nil if published? && participant?
          return nil if workflow.can_edit?(card, tg_user, permissions)

          "🚫 #{escape_html(workflow.edit_denial(card, permissions))}"
        end

        # Карточка в CRM — поле меняется не сразу, а через модерацию: там уже
        # запись в боевой базе, и правка «телефон не тот» должна быть кем-то
        # согласована. Ход работы дописывается заметками и без модерации.
        def published? = card.status_exported?

        def participant? = card.responsible&.id == tg_user.id || permissions.can?(:moderate)

        def accept(step, value, manual: false)
          case step.id
          when 'field' then schema.any? { |f| f.key == value } ? [value, nil] : [nil, 'Такого поля нет — выбери кнопкой.']
          when 'value' then accept_field(chosen, value)
          else [value, nil]
          end
        end

        def finish
          return { text: '⚠️ Карточка не найдена — ничего не изменено.' } unless card && chosen

          value = ctx['value'] == CLEAR ? nil : ctx['value']
          return request_change(value) if published?

          result_view(workflow.update_fields!(card, { chosen.key => value }, actor: tg_user))
        end

        def request_change(value)
          result = ::CrmCards::ChangeRequests
                   .new(notifier: ::CrmCards::Notifier.new(client: client))
                   .open!(card, actor: tg_user, field: chosen.key, value: value)
          return { text: "⚠️ #{escape_html(result.error)}" } unless result.ok?

          { text: "✏️ Заявка на правку поля «#{escape_html(chosen.label)}» ушла модератору. " \
                  'Пока он не решит, в карточке остаётся прежнее значение.' }
        end

        private

        def schema
          ::CrmCards::Schema.for(card.kind)
        end

        def chosen
          return nil unless card && ctx['field'].present?

          ::CrmCards::Schema.field(card.kind, ctx['field'])
        end

        # Текст кнопки — не HTML, экранировать не нужно.
        def field_button(field)
          value = card.payload[field.key]
          shown = value.nil? ? '—' : ::CrmCards::CardView.plain_value(field, value)
          "#{field.label}: #{shown}".truncate(60)
        end

        def confirm_prompt
          return '' unless chosen && ctx.key?('value')

          shown = ctx['value'] == CLEAR ? 'очистить' : ::CrmCards::CardView.plain_value(chosen, ctx['value'])
          if published?
            return "Отправить на согласование «#{escape_html(chosen.label)}: #{escape_html(shown)}»?\n" \
                   "Карточка ##{card.id} уже в CRM — поле изменится после решения модератора."
          end

          "Сохранить «#{escape_html(chosen.label)}: #{escape_html(shown)}»?"
        end
      end
    end
  end
end
