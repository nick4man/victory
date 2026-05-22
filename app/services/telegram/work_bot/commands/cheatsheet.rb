# frozen_string_literal: true

module Telegram
  module WorkBot
    module Commands
      # Phase 15 — /cheatsheet команда для director DM control panel.
      # Возвращает структурированный markdown с ВСЕМИ возможностями бота
      # для текущего role (director получает максимум, manager слегка
      # урезанный, agent — минимальный).
      #
      # UX hint: первая строка ответа предлагает закрепить сообщение
      # (long-press → Pin) — Оксана получит постоянную reference card
      # вверху своего чата с ботом.
      class Cheatsheet < Base
        def handle
          # Public — agent тоже может посмотреть свой набор; renderer сам
          # отфильтрует секции по role/can_voice_distribute?.
          markdown = Telegram::WorkBot::CheatsheetRenderer.call(tg_user: tg_user)
          reply(markdown)
        end
      end
    end
  end
end
