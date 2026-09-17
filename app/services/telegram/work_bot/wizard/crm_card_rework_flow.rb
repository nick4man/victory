# frozen_string_literal: true

module Telegram
  module WorkBot
    module Wizard
      # Модератор возвращает карточку на доработку. Комментарий обязателен:
      # возврат без объяснения автор может только угадывать.
      class CrmCardReworkFlow < Flow
        include CrmCardSupport

        flow 'crm_rework', 'Вернуть карточку CRM на доработку'

        COMMENT_MIN = 5
        COMMENT_MAX = 500

        def steps
          [
            Flow::Step.new(id: 'comment', kind: :input, prompt: "Что доработать в карточке ##{ctx['card']}?",
                           hint: 'Автор увидит это дословно. Конкретно: «нет бюджета», «телефон не отвечает».'),
            Flow::Step.new(id: 'confirm', kind: :confirm, prompt: 'Вернуть карточку автору на доработку?',
                           confirm_label: '↩️ Вернуть')
          ]
        end

        def gate
          moderator_gate
        end

        def accept(step, value, manual: false)
          return [value, nil] unless step.id == 'comment'

          text = value.to_s.strip
          return [nil, "Слишком коротко: нужно от #{COMMENT_MIN} символов."] if text.length < COMMENT_MIN
          return [nil, "Слишком длинно: #{text.length} симв., влезает #{COMMENT_MAX}."] if text.length > COMMENT_MAX

          [text, nil]
        end

        def finish
          return { text: '⚠️ Карточка не найдена — ничего не возвращено.' } unless card

          result = workflow.return_for_rework!(card, actor: tg_user, comment: ctx['comment'])
          return { text: "⚠️ #{escape_html(result.error)}" } unless result.ok?

          { text: "↩️ Карточка ##{card.id} возвращена: #{escape_html(card.responsible.mention)} получил комментарий." }
        end
      end
    end
  end
end
