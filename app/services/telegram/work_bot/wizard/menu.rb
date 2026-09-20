# frozen_string_literal: true

module Telegram
  module WorkBot
    module Wizard
      # Меню «Что сделать?» — вход во все мастера из лички. Собрано под роль:
      # недоступного действия в нём нет, поэтому отказ по правам из меню
      # получить нельзя (с карточки в группе — можно: кнопки там видят все).
      module Menu
        module_function

        def text(_tg_user)
          "<b>Что сделать?</b>\n<i>Здесь только то, что доступно твоей должности.</i>"
        end

        def keyboard(tg_user)
          rows = [[
            { text: '📅 Поставить задачу', callback_data: 'wiz:s:task' },
            { text: '♻️ Переоткрыть задачу', callback_data: 'wiz:s:reopen' }
          ]]
          rows << [{ text: '❌ Закрыть лид', callback_data: 'wiz:s:close' }] if tg_user&.manager_or_director?
          # Песочница обслуживает только карточки CRM: задачи и закрытие лидов
          # работают на боевых данных и в тестовом боте не предлагаются.
          rows = [] if ::Telegram::BotContext.test?
          # Права на карточки — из должности в CRM, а не из роли в боте.
          perms = tg_user && ::CrmCards::Permissions.for(tg_user)
          if perms&.can?(:create_lead)
            rows << [{ text: '📋 Карточка заявки', callback_data: 'wiz:s:crm_lead' }]
            rows << [{ text: '🧪 Тестовый лид', callback_data: 'wiz:s:crm_test_lead' }] if ::Telegram::BotContext.test?
          end
          rows << [{ text: '🏠 Новый объект в CRM', callback_data: 'wiz:s:crm_object' }] if perms&.can?(:create_object)
          rows
        end
      end
    end
  end
end
