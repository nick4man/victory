# frozen_string_literal: true

module Telegram
  module WorkBot
    module Wizard
      # Мастер «Карточка заявки для CRM»: ответственный после разговора с
      # клиентом дозаполняет то, чего нет в лиде, и получает карточку с итогом
      # машинной проверки и кнопкой «На модерацию».
      #
      # Спрашивает только незаполненное обязательное: имя и телефон приходят
      # из лида, заполненное в черновике не повторяется. Необязательные поля —
      # через «Изменить поле». Последний шаг — подтверждение: мастер без
      # вопросов Engine не завершает, а для полного черновика так и было бы.
      class CrmLeadCardFlow < Flow
        include CrmCardSupport

        flow 'crm_lead', 'Карточка заявки для CRM'

        CANDIDATES_LIMIT = 8

        def steps
          [lead_step, paste_step('lead')] + ::CrmCards::Schema.for('lead').map { |field| field_step(field) } +
            [Flow::Step.new(id: 'confirm', kind: :confirm,
                            prompt: 'Сохранить карточку заявки? Дальше — машинная проверка.',
                            confirm_label: '💾 Сохранить и проверить')]
        end

        def skip?(step)
          field = ::CrmCards::Schema.field('lead', step.id)
          return false unless field
          return true unless field.required

          _, error = ::CrmCards::FieldValue.normalize(field, known_values[field.key])
          error.nil?
        end

        def gate
          return "🚫 #{escape_html(permissions.denial)}" if permissions.denial
          return '🚫 Твоей должности в CRM не выдано право заводить заявки.' unless permissions.can?(:create_lead)
          return nil if ctx['lead'].blank? # лид выберут первым шагом
          return "⚠️ Лид ##{escape_html(ctx['lead'])} не найден." unless lead

          lead_refusal(lead)
        end

        def accept(step, value, manual: false)
          return accept_lead(value) if step.id == 'lead'
          return accept_paste('lead', value) if step.id == 'paste'

          field = ::CrmCards::Schema.field('lead', step.id)
          field ? accept_field(field, value) : [value, nil]
        end

        def finish
          return { text: '⚠️ Лид не найден — карточка не сохранена.' } unless lead

          answers = ::CrmCards::Schema.for('lead').to_h { |f| [f.key, ctx[f.key]] }.compact
          result_view(workflow.upsert_lead_card!(lead: lead, actor: tg_user, values: known_values.merge(answers)))
        end

        private

        # Из лички лида выбирают списком: свои открытые (модератору — все),
        # в тестовом боте — только тестовые, без уже отправленной карточки.
        def lead_step
          Flow::Step.new(id: 'lead', kind: :choice, per_row: 1,
                         prompt: candidates.any? ? 'По какому лиду карточка?' : 'По какому лиду карточка? Подходящих лидов нет.',
                         hint: 'В списке — открытые лиды без отправленной карточки.',
                         options: candidates.map { |l| [lead_label(l), l.id.to_s] })
        end

        # Пустой список без запроса, если лид уже выбран: steps() зовёт
        # lead_step на каждом рендере мастера (чтобы id/порядок шагов не
        # плавали), но список кандидатов после выбора уже не нужен — он не
        # рисуется повторно, а candidates раньше всё равно бил в базу.
        def candidates
          @candidates ||= ctx['lead'].present? ? [] : fetch_candidates
        end

        def fetch_candidates
          scope = ::LeadEvent.open.order(updated_at: :desc)
          scope = if ::Telegram::BotContext.test?
                    scope.where("lead_events.metadata->>'sandbox' = 'true'")
                  else
                    scope.where("COALESCE(lead_events.metadata->>'sandbox', '') <> 'true'")
                  end
          scope = scope.where(assigned_to: tg_user) unless permissions.can?(:moderate)
          scope.limit(CANDIDATES_LIMIT * 2).to_a.reject { |l| lead_refusal(l) }.first(CANDIDATES_LIMIT)
        end

        def accept_lead(value)
          found = value.to_s.match?(/\A\d+\z/) ? ::LeadEvent.find_by(id: value) : nil
          return [nil, 'Лид не найден — выбери из списка.'] unless found

          refusal = lead_refusal(found)
          refusal ? [nil, refusal] : [found.id.to_s, nil]
        end

        def lead_refusal(target)
          sandbox_lead = ::CrmCards::Checker.sandbox_lead?(target)
          if ::Telegram::BotContext.test? && !sandbox_lead
            return '🚫 В тестовом боте карточки заводятся только по тестовым лидам.'
          end
          return '🚫 Это тестовый лид — его карточку заводят в тестовом боте.' if !::Telegram::BotContext.test? && sandbox_lead
          return "ℹ️ Лид ##{target.id} уже закрыт (#{target.current_stage}) — карточку заводить нечего." if target.closed?

          unless target.assigned_to_id == tg_user.id || permissions.can?(:moderate)
            responsible = target.assigned_to&.mention || 'пока никто не назначен'
            return "🚫 Карточку заполняет ответственный по лиду: #{escape_html(responsible)}."
          end

          card = ::CrmCard.kind_lead.find_by(lead_event_id: target.id)
          return nil if card.nil? || ::CrmCard::AUTHOR_EDITABLE.include?(card.status)

          "ℹ️ Карточка ##{card.id} по этому лиду — #{::CrmCard::STATUS_LABELS[card.status]}. Открой её через /cards."
        end

        def lead_label(target)
          name = target.metadata.to_h['name'].to_s.split.first
          ["##{target.id}", name, target.lead_ref.try(:title).to_s.truncate(30)].compact_blank.join(' · ')
        end

        def lead
          return @lead if defined?(@lead)

          @lead = ctx['lead'].to_s.match?(/\A\d+\z/) ? ::LeadEvent.find_by(id: ctx['lead']) : nil
        end

        def existing
          return @existing if defined?(@existing)

          @existing = lead && ::CrmCard.kind_lead.find_by(lead_event_id: lead.id)
        end

        # Известное заранее: черновик поверх данных, пришедших с лидом.
        # Вставленный текст свежее данных лида (сотрудник только что говорил с
        # клиентом), но черновик, который он уже правил руками, не перебивает.
        def known_values
          @known_values ||= prefill.merge(pasted_values).merge(existing&.payload.to_h)
        end

        def prefill
          meta = lead&.metadata.to_h
          values = {}
          name = meta['name'].to_s.strip
          values['name'] = name if name.present? && name != 'Без имени'
          phone, error = ::CrmCards::FieldValue.phone(meta['phone'].to_s)
          values['phone'] = phone unless error
          # Текст, вставленный при заведении лида, — готовый итог разговора.
          summary, summary_error = ::CrmCards::FieldValue.normalize(::CrmCards::Schema.field('lead', 'comment'),
                                                                   meta['summary'])
          values['comment'] = summary if meta['summary'].present? && summary_error.nil?
          external_id = lead&.property&.external_id.to_s
          values['realty_id'] = external_id.to_i if external_id.match?(/\A\d+\z/)
          values
        end
      end
    end
  end
end
