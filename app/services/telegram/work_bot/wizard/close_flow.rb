# frozen_string_literal: true

module Telegram
  module WorkBot
    module Wizard
      # Мастер «Закрытие лида»: лид → исход → причина отказа → подтверждение.
      #
      # Исход — две кнопки вместо слов «выиграно / проиграно»: опечатка в
      # исходе невозможна. Причина — фиксированный список, чтобы аналитика
      # отказов была сравнимой; «Другое» открывает свободный ввод.
      class CloseFlow < Flow
        include LeadPicking

        flow 'close', 'Закрытие лида'
        manager_only

        OUTCOMES = [['✅ Выиграно', 'closed_won'], ['❌ Проиграно', 'closed_lost']].freeze
        OUTCOME_WORDS = { 'closed_won' => 'выиграно', 'closed_lost' => 'проиграно' }.freeze
        REASONS = [
          ['Цена', 'цена'], ['Ушёл к конкуренту', 'конкурент'], ['Передумал', 'передумал'],
          ['Не дозвонились', 'нет связи'], ['Не наш профиль', 'не профиль']
        ].freeze
        REASON_MAX = 255

        def steps
          [
            lead_step,
            Step.new(id: 'outcome', kind: :choice, per_row: 2,
                     prompt: "Чем закончился лид ##{ctx['lead']}?", options: OUTCOMES),
            Step.new(id: 'reason', kind: :choice, per_row: 2,
                     prompt: 'Причина отказа?',
                     hint: 'Фиксированный список даёт сравнимую аналитику отказов.',
                     options: REASONS,
                     manual: '✍️ Другое', manual_prompt: 'Опиши причину одной фразой.'),
            Step.new(id: 'confirm', kind: :confirm,
                     prompt: confirm_prompt,
                     confirm_label: ctx['outcome'] == 'closed_won' ? '✅ Закрыть лид' : '❌ Закрыть лид')
          ]
        end

        def skip?(step)
          step.id == 'reason' && ctx['outcome'] == 'closed_won'
        end

        def gate
          lead_gate
        end

        def accept(step, value, manual: false)
          case step.id
          when 'lead' then accept_lead(value)
          when 'outcome' then OUTCOME_WORDS.key?(value) ? [value, nil] : [nil, 'Неизвестный исход — выбери кнопкой.']
          when 'reason' then accept_reason(value, manual)
          else [value, nil]
          end
        end

        def finish
          # Между выбором лида и подтверждением до 30 минут: другой руководитель
          # мог закрыть лид. LeadStageTransition пропускает closed_won → closed_lost,
          # поэтому проверяем здесь, до записи причины.
          current_lead = ::LeadEvent.find_by(id: ctx['lead'])
          return { text: '⚠️ Лид не найден — ничего не закрыто.' } unless current_lead
          unless current_lead.open?
            return { text: "ℹ️ Лид ##{current_lead.id} уже закрыт (#{current_lead.current_stage}) — " \
                           'пока шёл мастер, его закрыл кто-то другой. Ничего не изменено.' }
          end

          stage = ctx['outcome']
          reason = stage == 'closed_lost' ? ctx['reason'] : nil

          result = LeadClosure.new(current_lead, stage, actor: tg_user, reason: reason, client: client).call
          unless result.success?
            return { text: "⚠️ Лид ##{current_lead.id} не закрыт: #{escape_html(result.message)}" }
          end

          icon = stage == 'closed_won' ? '✅' : '❌'
          text = "#{icon} <b>Лид ##{current_lead.id} закрыт:</b> #{OUTCOME_WORDS[stage]}"
          text += " · причина: #{escape_html(reason)}" if reason
          text += "\nКарточка в топике перерисована, заметка ушла в Topnlab."
          { text: text }
        end

        private

        def confirm_prompt
          return '' if ctx['outcome'].blank?

          text = "Закрыть лид ##{ctx['lead']} как «#{OUTCOME_WORDS[ctx['outcome']]}»"
          text += " · причина: #{escape_html(ctx['reason'])}" if ctx['outcome'] == 'closed_lost' && ctx['reason'].present?
          "#{text}?"
        end

        def accept_reason(value, manual)
          text = value.to_s.squish
          if manual
            return [nil, 'Пустой ответ. Опиши причину хотя бы одним словом.'] if text.empty?
            return [nil, "Слишком длинно: #{text.length} символов, влезает #{REASON_MAX}."] if text.length > REASON_MAX
          elsif REASONS.none? { |_, v| v == text }
            return [nil, 'Неизвестная причина — выбери кнопкой.']
          end

          [text, nil]
        end
      end
    end
  end
end
