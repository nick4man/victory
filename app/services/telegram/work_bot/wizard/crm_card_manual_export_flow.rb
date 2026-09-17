# frozen_string_literal: true

module Telegram
  module WorkBot
    module Wizard
      # «Объект внесён в CRM»: автор (или модератор) вносит одобренный объект
      # в интерфейсе Topnlab и вводит здесь номер карточки. Без номера объект
      # остаётся «одобрен» и виден в /cards — «забыли внести» не теряется.
      class CrmCardManualExportFlow < Flow
        include CrmCardSupport

        flow 'crm_manual', 'Объект внесён в CRM'

        def steps
          [
            Flow::Step.new(id: 'crm_id', kind: :input, prompt: "Номер карточки объекта ##{ctx['card']} в CRM?",
                           hint: 'Цифры из адреса карточки в Topnlab: …/object-card/<номер>.'),
            Flow::Step.new(id: 'confirm', kind: :confirm,
                           prompt: "Объект ##{ctx['card']} внесён в CRM под номером #{escape_html(ctx['crm_id'])}?",
                           confirm_label: '✅ Подтвердить')
          ]
        end

        def gate
          return '⚠️ Карточка не найдена.' unless card
          return "🚫 #{escape_html(permissions.denial)}" if permissions.denial
          unless card.responsible&.id == tg_user.id || permissions.can?(:moderate)
            return '🚫 Отметить внесение в CRM может автор карточки или модератор.'
          end
          unless card.kind_object? && card.status_approved?
            return "ℹ️ Карточка ##{card.id} не ждёт ручного внесения — #{::CrmCard::STATUS_LABELS[card.status]}."
          end

          nil
        end

        def accept(step, value, manual: false)
          return [value, nil] unless step.id == 'crm_id'

          digits = value.to_s.strip
          digits.match?(/\A\d{1,12}\z/) ? [digits, nil] : [nil, 'Номер карточки — только цифры, без пробелов и букв.']
        end

        def finish
          return { text: '⚠️ Карточка не найдена — ничего не отмечено.' } unless card

          result = workflow.record_export!(card, crm_id: ctx['crm_id'], mode: 'manual', actor: tg_user)
          return { text: "⚠️ #{escape_html(result.error)}" } unless result.ok?

          { text: "🟢 Объект ##{card.id} отмечен как внесённый в CRM: #{escape_html(result.card.crm_id)}." }
        end
      end
    end
  end
end
