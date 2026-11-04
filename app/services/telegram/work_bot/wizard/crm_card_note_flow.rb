# frozen_string_literal: true

module Telegram
  module WorkBot
    module Wizard
      # «Добавить заметку» — как идёт работа с клиентом. Один шаг и без
      # подтверждения: заметка ничего не переписывает и ничего не запускает,
      # а лишний вопрос на каждую строчку отучит ими пользоваться.
      class CrmCardNoteFlow < Flow
        include CrmCardSupport

        flow 'crm_note', 'Заметка по карточке'

        def steps
          [Flow::Step.new(id: 'note', kind: :input,
                          prompt: "Что нового по карточке ##{ctx['card']}?",
                          hint: 'Созвонились, о чём договорились, что дальше. ' \
                                'Добавится к прежним записям — старое не перепишется.')]
        end

        def gate
          return '⚠️ Карточка не найдена.' unless card
          return "🚫 #{escape_html(permissions.denial)}" if permissions.denial
          unless card.responsible&.id == tg_user.id || permissions.can?(:moderate)
            return '🚫 Заметку по карточке пишет тот, кто ведёт клиента.'
          end

          nil
        end

        def accept(step, value, manual: false)
          return [value, nil] unless step.id == 'note'

          text = value.to_s.strip
          return [nil, "Слишком коротко: нужно от #{::CrmCards::Notes::MIN} символов."] if
            text.length < ::CrmCards::Notes::MIN
          return [nil, "Слишком длинно: #{text.length} симв., влезает #{::CrmCards::Notes::MAX}."] if
            text.length > ::CrmCards::Notes::MAX

          [text, nil]
        end

        def finish
          return { text: '⚠️ Карточка не найдена — заметка не сохранена.' } unless card

          result = ::CrmCards::Notes.add!(card, actor: tg_user, text: ctx['note'])
          return { text: "⚠️ #{escape_html(result.error)}" } unless result.ok?

          ::CrmCards::CardView.render(card.reload, viewer: tg_user)
        end
      end
    end
  end
end
