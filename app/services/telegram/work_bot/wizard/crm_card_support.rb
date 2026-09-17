# frozen_string_literal: true

module Telegram
  module WorkBot
    module Wizard
      # Общее для мастеров карточек CRM: шаг-вопрос на поле схемы, проверка
      # ввода через CrmCards::FieldValue, поиск карточки из callback_data.
      #
      # Права — только CrmCards::Permissions (из CRM), не роль в боте: поэтому
      # мастера карточек не объявляют manager_only, а отказывают в gate.
      module CrmCardSupport
        # Значение кнопки «Очистить» в мастере правки. Только кнопкой: текстом
        # его не ввести, поэтому в данные карточки он не протекает.
        CLEAR = '__clear__'

        def permissions
          @permissions ||= ::CrmCards::Permissions.for(tg_user)
        end

        def workflow
          @workflow ||= ::CrmCards::Workflow.new(notifier: ::CrmCards::Notifier.new(client: client))
        end

        def card
          return @card if defined?(@card)

          @card = ctx['card'].to_s.match?(/\A\d+\z/) ? ::CrmCard.find_by(id: ctx['card']) : nil
        end

        # Варианты — кнопками, остальное — текстом. clearable — только в правке:
        # в мастере заполнения «очистить» пустое поле бессмысленно.
        def field_step(field, id: field.key, prompt: nil, clearable: false)
          prompt ||= "#{field.label}?"
          if field.type == :choice
            Flow::Step.new(id: id, kind: :choice, per_row: 2, prompt: prompt, hint: field.hint, options: field.options)
          else
            quick = clearable ? [['🗑 Очистить', CLEAR]] : nil
            Flow::Step.new(id: id, kind: :input, prompt: prompt, hint: field.hint, quick: quick)
          end
        end

        # @return [Array(Object, String|nil)]
        def accept_field(field, value)
          return [nil, "Поле «#{field.label}» обязательное — очистить нельзя."] if value == CLEAR && field.required
          return [CLEAR, nil] if value == CLEAR

          ::CrmCards::FieldValue.normalize(field, value)
        end

        def result_view(result)
          return ::CrmCards::CardView.render(result.card, viewer: tg_user) if result.ok?

          { text: "⚠️ #{escape_html(result.error)}" }
        end

        def moderator_gate
          return '⚠️ Карточка не найдена.' unless card
          return "🚫 #{escape_html(permissions.denial)}" if permissions.denial
          return '🚫 Решение по карточке принимает модератор.' unless permissions.can?(:moderate)
          unless card.status_pending_review?
            return "ℹ️ Карточка ##{card.id} не на модерации — #{::CrmCard::STATUS_LABELS[card.status]}."
          end

          nil
        end
      end
    end
  end
end
