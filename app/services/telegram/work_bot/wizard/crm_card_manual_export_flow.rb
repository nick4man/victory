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
          # Отказ до ввода номера, а не после: иначе сотрудник наберёт номер,
          # подтвердит — и только тогда узнает, что вносить было рано.
          return "⏳ Выгрузку карточки ##{card.id} ещё не разрешил руководитель." if card.released_at.blank?

          nil
        end

        def accept(step, value, manual: false)
          return [value, nil] unless step.id == 'crm_id'

          digits = value.to_s.strip
          return [nil, 'Номер карточки — только цифры, без пробелов и букв.'] unless digits.match?(/\A\d{1,12}\z/)

          taken = number_taken_by(digits)
          taken ? [nil, taken] : [digits, nil]
        end

        def finish
          return { text: '⚠️ Карточка не найдена — ничего не отмечено.' } unless card
          # Повторная проверка: между вводом и подтверждением номер мог занять другой.
          taken = number_taken_by(ctx['crm_id'])
          return { text: "⚠️ #{taken}" } if taken

          result = workflow.record_export!(card, crm_id: ctx['crm_id'], mode: 'manual', actor: tg_user)
          return { text: "⚠️ #{escape_html(result.error)}" } unless result.ok?

          { text: "🟢 Объект ##{card.id} отмечен как внесённый в CRM: #{escape_html(result.card.crm_id)}." }
        end

        private

        # «Выгружен» — статус окончательный: опечатку или номер чужого объекта
        # потом в боте не исправить, поэтому занятый номер не принимаем.
        def number_taken_by(digits)
          # Только карточки своего бота: номер из песочницы не должен запирать
          # настоящий объект, а песочница — узнавать о настоящих номерах.
          other = ::CrmCard.in_current_bot.kind_object.where(crm_id: digits.to_s).where.not(id: card&.id).first
          other && "Номер #{digits} уже отмечен у объекта ##{other.id} — проверь цифры в адресе карточки Topnlab."
        end
      end
    end
  end
end
