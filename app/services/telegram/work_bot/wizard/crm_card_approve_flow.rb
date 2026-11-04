# frozen_string_literal: true

module Telegram
  module WorkBot
    module Wizard
      # Модератор одобряет карточку. Одобрение не отправляет её в CRM —
      # это отдельное решение руководителя (CrmCardReleaseFlow).
      class CrmCardApproveFlow < Flow
        include CrmCardSupport

        flow 'crm_approve', 'Одобрить карточку CRM'

        def steps
          [Flow::Step.new(id: 'confirm', kind: :confirm, prompt: confirm_prompt,
                          confirm_label: '✅ Одобрить')]
        end

        def gate
          moderator_gate
        end

        def finish
          return { text: '⚠️ Карточка не найдена — ничего не одобрено.' } unless card

          result = workflow.approve!(card, actor: tg_user)
          return { text: "⚠️ #{escape_html(result.error)}" } unless result.ok?

          { text: "✅ Карточка ##{card.id} одобрена: ждёт решения руководителя о выгрузке в CRM." }
        end

        private

        def confirm_prompt
          return '' unless card
          kind = card.kind_object? ? 'объект' : 'заявку'
          "Одобрить #{kind} по карточке ##{card.id} (#{escape_html(card.responsible&.mention.to_s)})?\n" \
            'Выгрузку в CRM после этого разрешает руководитель.'
        end
      end
    end
  end
end
