# frozen_string_literal: true

module Telegram
  module WorkBot
    module Commands
      # `/menu` — меню «Что сделать?»: вход в пошаговые мастера кнопками.
      # Меню всегда уходит в личку — мастера идут там же; в группе вызвавшему
      # отвечаем, куда смотреть.
      class Menu < Base
        def handle
          engine = Wizard::Engine.new(tg_user: tg_user, client: client)
          sent = begin
            engine.menu
          rescue Telegram::Client::Error => e
            Rails.logger.warn("[Commands::Menu] DM to #{tg_user.mention} failed: #{e.message}")
            nil
          end

          unless sent
            reply('⚠️ Не могу написать тебе в личку. Открой чат с ботом, нажми «Start» и повтори /menu.')
            return :dm_unavailable
          end

          reply('↘︎ Меню отправлено в личку с ботом.') unless message.dig('chat', 'type') == 'private'
          :menu_shown
        end
      end
    end
  end
end
