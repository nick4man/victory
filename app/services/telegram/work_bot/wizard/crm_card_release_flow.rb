# frozen_string_literal: true

module Telegram
  module WorkBot
    module Wizard
      # Третья ступень конвейера: руководитель решает, уходит ли одобренная
      # карточка в CRM. Отдельно от одобрения намеренно — карточку проверяет
      # один человек, а отвечает за запись в боевую CRM другой.
      #
      # Через мастер, а не кнопкой: запись в CRM мы не умеем отменять, и
      # подтверждение называет номер карточки и ответственного — чтобы
      # случайное попадание по кнопке было видно до того, как оно сработает.
      class CrmCardReleaseFlow < Flow
        include CrmCardSupport

        flow 'crm_release', 'Разрешить выгрузку карточки в CRM'

        def steps
          [Flow::Step.new(id: 'confirm', kind: :confirm, prompt: confirm_prompt,
                          confirm_label: card&.kind_lead? ? '📤 Выгрузить' : '📤 Разрешить')]
        end

        def gate
          return '⚠️ Карточка не найдена.' unless card
          return "🚫 #{escape_html(permissions.denial)}" if permissions.denial
          return '🚫 Решение о выгрузке в CRM принимает руководитель.' unless permissions.can?(:export)
          unless card.status_approved?
            return "ℹ️ Карточка ##{card.id} не одобрена — #{::CrmCard::STATUS_LABELS[card.status]}."
          end
          return "ℹ️ Карточка ##{card.id} уже отправлена в CRM." if card.released_at.present?

          nil
        end

        def finish
          return { text: '⚠️ Карточка не найдена — ничего не выгружено.' } unless card

          result = workflow.release_for_export!(card, actor: tg_user)
          return { text: "⚠️ #{escape_html(result.error)}" } unless result.ok?

          done = if card.kind_lead?
                   'выгрузка запущена, итог придёт сообщением'
                 else
                   "внесёт в CRM вручную #{escape_html(card.responsible.mention)}"
                 end
          { text: "📤 Карточка ##{card.id}: #{done}." }
        end

        private

        # Называем номер карточки и ответственного: уведомление может сдвинуть
        # разметку чата под пальцем, и это единственное, что отделяет промах
        # от записи чужих данных в CRM.
        def confirm_prompt
          return '' unless card

          who = escape_html(card.responsible&.mention.to_s)
          approved_by = escape_html(card.reviewer&.mention.to_s)
          return "Разрешить внести объект по карточке ##{card.id} (#{who}) в CRM?\nОдобрил: #{approved_by}." if card.kind_object?

          "Выгрузить заявку по карточке ##{card.id} (#{who}) в CRM?\n" \
            "Одобрил: #{approved_by}. Отменить запись в CRM нельзя."
        end
      end
    end
  end
end
