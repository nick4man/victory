# frozen_string_literal: true

module Telegram
  module WorkBot
    module Wizard
      # Модератор одобряет карточку. Подтверждение — отдельным шагом: для
      # заявки это запись в боевую CRM, которую мы не умеем отменять.
      class CrmCardApproveFlow < Flow
        include CrmCardSupport

        flow 'crm_approve', 'Одобрить карточку CRM'

        def steps
          [Flow::Step.new(id: 'confirm', kind: :confirm, prompt: confirm_prompt,
                          confirm_label: card&.kind_lead? ? '✅ Одобрить и выгрузить' : '✅ Одобрить')]
        end

        def gate
          moderator_gate
        end

        def finish
          return { text: '⚠️ Карточка не найдена — ничего не одобрено.' } unless card

          result = workflow.approve!(card, actor: tg_user)
          return { text: "⚠️ #{escape_html(result.error)}" } unless result.ok?

          done = if card.kind_lead?
                   'выгрузка в CRM запущена, итог придёт сообщением'
                 else
                   "объект внесёт в CRM вручную #{escape_html(card.responsible.mention)}"
                 end
          { text: "✅ Карточка ##{card.id} одобрена: #{done}." }
        end

        private

        def confirm_prompt
          return '' unless card
          return "Одобрить объект ##{card.id}?\nВ CRM его внесёт вручную #{escape_html(card.responsible.mention)}." if card.kind_object?

          "Одобрить заявку ##{card.id} и выгрузить в CRM?\nОтветственным в CRM станет #{escape_html(card.responsible.mention)}."
        end
      end
    end
  end
end
