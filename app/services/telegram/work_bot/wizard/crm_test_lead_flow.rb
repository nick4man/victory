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
      # staff_test: true исключает лид из метрик (LeadEvent.real) и
      # не даёт ему попасть в CRM из рабочего бота (CrmCards::Checker).
      class CrmTestLeadFlow < Flow
        include CrmCardSupport

        flow 'crm_test_lead', 'Тестовый лид'

        def steps
          [
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

        def accept(step, value, manual: false)
          field = ::CrmCards::Schema.field('lead', step.id)
          field ? accept_field(field, value) : [value, nil]
        end

        def finish
          lead = ::LeadEvent.create!(
            lead_ref: tg_user, source: 'manual', current_stage: 'first_contact', first_contact_at: Time.current,
            anchor_topic_key: 'dispatcher', tg_chat_id: tg_user.dm_chat_id || tg_user.tg_user_id,
            assigned_to: tg_user, assigned_at: Time.current, staff_test: true,
            metadata: { 'name' => ctx['name'], 'phone' => ctx['phone'], 'sandbox' => true }
          )
          { text: "🧪 Тестовый лид ##{lead.id} создан и назначен на тебя.",
            keyboard: [[{ text: '📋 Карточка заявки', callback_data: "wiz:s:crm_lead:#{lead.id}" }]] }
        end
      end
    end
  end
end
