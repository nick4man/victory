# frozen_string_literal: true

module Telegram
  module WorkBot
    module Wizard
      # «Тестовый лид» — только в тестовом боте. Лид сразу назначен на
      # проверяющего и стоит на «первом контакте», чтобы весь путь карточки
      # проходился за минуту.
      #
      # lead_ref — сам проверяющий (TelegramUser), а не Inquiry: создание
      # Inquiry рассылает письма админам и публикует лид в рабочую группу.
      #
      # staff_test: true исключает лид из персистентного KPI-снапшота
      # (Kpi::StaffSnapshot#leads_stats фильтрует через LeadEvent.real), а
      # metadata['sandbox'] => true — из выбора лида в рабочем боте
      # (CrmCards::Checker.sandbox_lead?, LeadPicking#recent_leads) и из CRM
      # (Checker). Другие дайджесты/выборки, не прогнанные через .real или
      # sandbox-фильтр явно, могут по-прежнему считать тестовые лиды — это не
      # гарантия для всех метрик агентства, только для перечисленных мест.
      class CrmTestLeadFlow < Flow
        include CrmCardSupport

        flow 'crm_test_lead', 'Тестовый лид'

        def steps
          [
            paste_step('lead'),
            field_step(::CrmCards::Schema.field('lead', 'name'), prompt: 'Имя тестового клиента?'),
            field_step(::CrmCards::Schema.field('lead', 'phone'), prompt: 'Телефон тестового клиента?'),
            Flow::Step.new(id: 'confirm', kind: :confirm, prompt: 'Создать тестовый лид и назначить на себя?',
                           confirm_label: '🧪 Создать')
          ]
        end

        def gate
          return '🚫 Тестовые лиды заводятся только в тестовом боте.' unless ::Telegram::BotContext.test?
          return "🚫 #{escape_html(permissions.denial)}" if permissions.denial
          return '🚫 Твоей должности не выдано право заводить заявки.' unless permissions.can?(:create_lead)

          nil
        end

        # Вставленный текст закрывает имя и телефон — спрашивать их заново
        # незачем, а остальное пригодится в карточке (см. #finish).
        def skip?(step)
          %w[name phone].include?(step.id) && pasted_values[step.id].present?
        end

        def accept(step, value, manual: false)
          return accept_paste('lead', value) if step.id == 'paste'

          field = ::CrmCards::Schema.field('lead', step.id)
          field ? accept_field(field, value) : [value, nil]
        end

        def finish
          now = Time.current
          values = pasted_values.merge({ 'name' => ctx['name'], 'phone' => ctx['phone'] }.compact_blank)
          lead = ::LeadEvent.create!(
            lead_ref: tg_user, source: 'manual', current_stage: 'first_contact', first_contact_at: now,
            anchor_topic_key: 'dispatcher', tg_chat_id: tg_user.dm_chat_id || tg_user.tg_user_id,
            assigned_to: tg_user, assigned_at: now, staff_test: true,
            metadata: { 'name' => values['name'], 'phone' => values['phone'], 'sandbox' => true,
                        # Что клиент хотел — из вставленного текста; карточка
                        # подставит это в «Итог разговора», чтобы не набирать снова.
                        'summary' => values['comment'] }.compact
          )
          { text: "🧪 Тестовый лид ##{lead.id} создан и назначен на тебя.",
            keyboard: [[{ text: '📋 Карточка заявки', callback_data: "wiz:s:crm_lead:#{lead.id}" }]] }
        end
      end
    end
  end
end
