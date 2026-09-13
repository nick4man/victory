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
          "<b>Что сделать?</b>\n<i>Меню собрано под твою роль — недоступных действий здесь нет.</i>"
        end

        def keyboard(_tg_user)
          [[{ text: '📅 Поставить задачу', callback_data: 'wiz:s:task' }]]
        end
      end
    end
  end
end
