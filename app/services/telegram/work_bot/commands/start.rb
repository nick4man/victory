# frozen_string_literal: true

module Telegram
  module WorkBot
    module Commands
      # `/start` — первое, что видит новый сотрудник. Раньше здесь открывался
      # полный справочник команд, включая чужие роли: человек получал простыню
      # вместо понятного «что делать». Теперь короткое приветствие и меню
      # «Что сделать?» с кнопками; полный список остался в /help.
      class Start < Menu
        public_command

        def handle
          dm('👋 Это рабочий бот АН «Виктори». Ниже — что можно сделать; ' \
             'полный список команд — /help.')
          super
        end
      end
    end
  end
end
