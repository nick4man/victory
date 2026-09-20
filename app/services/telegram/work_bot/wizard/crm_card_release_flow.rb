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

        # :choice с одной кнопкой, а не :confirm: в значении кнопки уезжает
        # отпечаток карточки на момент показа. Нажатие возвращает его обратно,
        # и Workflow сверяет — выгрузится ровно то, что человек видел.
        def steps
          label = card&.kind_lead? ? '📤 Выгрузить' : '📤 Разрешить'
          [Flow::Step.new(id: 'confirm', kind: :choice, prompt: confirm_prompt,
                          options: [[label, card&.release_digest.to_s]], per_row: 1)]
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

          result = workflow.release_for_export!(card, actor: tg_user, expected: ctx['confirm'])
          return { text: "⚠️ #{escape_html(result.error)}" } unless result.ok?

          done = if card.kind_lead?
                   'отправляю в CRM, итог придёт сообщением'
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
          head = if card.kind_object?
                   "Разрешить внести объект по карточке ##{card.id} (#{who}) в CRM?\nОдобрил: #{approved_by}."
                 else
                   "Выгрузить заявку по карточке ##{card.id} (#{who}) в CRM?\n" \
                     "Одобрил: #{approved_by}. Отменить запись в CRM нельзя."
                 end
          [head, *warnings].join("\n")
        end

        # Что изменилось у лида, пока карточка ждала решения. Не запрет, а то,
        # чего руководитель может не знать: решение всё равно за ним.
        def warnings
          problems = ::CrmCards::Checker.call(card)
          return [] if problems.empty?

          ['', '⚠️ Сейчас по лиду есть замечания — реши, выгружать ли:'] +
            problems.map { |e| "• #{escape_html(e['message'])}" }
        end
      end
    end
  end
end
