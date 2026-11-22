# frozen_string_literal: true

module Telegram
  module WorkBot
    module Wizard
      # Привязка номера заявки, найденного в CRM после сверки. Recovery из
      # неоднозначного исхода выгрузки (ревью PR #210, round 7): новый
      # importClient запрещён — модератор находит заявку глазами по телефону
      # и вводит её номер, Workflow#attach_export_number! доводит карточку до
      # «выгружена» без повторного вызова CRM.
      class CrmCardAttachFlow < Flow
        include CrmCardSupport

        flow 'crm_attach', 'Привязать номер заявки из CRM'

        def steps
          [
            Flow::Step.new(id: 'crm_id', kind: :input,
                           prompt: "Номер заявки в CRM по карточке ##{ctx['card']}?",
                           hint: 'Сверь заявку по телефону клиента в Topnlab и скопируй цифры ' \
                                 'из конца адресной строки. Повторной выгрузки не будет.'),
            Flow::Step.new(id: 'confirm', kind: :confirm,
                           prompt: "Записать заявку ##{escape_html(ctx['crm_id'].to_s)} в карточку ##{ctx['card']}?",
                           confirm_label: '✅ Привязать')
          ]
        end

        def gate
          return '⚠️ Карточка не найдена.' unless card
          return "🚫 #{escape_html(permissions.denial)}" if permissions.denial
          return '🚫 Привязку номера делает модератор.' unless permissions.can?(:moderate)
          return 'ℹ️ Привязка — только у заявок.' unless card.kind_lead?
          unless card.status_exporting? || card.status_export_failed?
            return "ℹ️ Привязывать нечего — #{::CrmCard::STATUS_LABELS[card.status]}."
          end
          # Досрочный отказ по правилам Workflow (released_at) держим в finish:
          # решение требует сверки с CRM, и узнавать об отказе после сверки
          # лучше, чем до неё.
          nil
        end

        def accept(step, value, manual: false)
          return [value, nil] unless step.id == 'crm_id'

          digits = value.to_s.strip
          return [nil, 'Номер заявки — только цифры, без пробелов и букв.'] unless digits.match?(/\A\d{1,12}\z/)

          [digits, nil]
        end

        def finish
          return { text: '⚠️ Карточка не найдена — номер не привязан.' } unless card

          result = workflow.attach_export_number!(card, crm_id: ctx['crm_id'], actor: tg_user)
          return { text: "⚠️ #{escape_html(result.error)}" } unless result.ok?

          ::CrmCards::CardView.render(result.card.reload, viewer: tg_user)
        end
      end
    end
  end
end
