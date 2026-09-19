# frozen_string_literal: true

module Telegram
  module WorkBot
    module Commands
      # `/starttest` — разбудить песочницу карточек CRM и напомнить, что в ней
      # сейчас проверяем. Песочница живёт в GitHub Codespace и засыпает от
      # простоя; без этой команды её будит разработчик руками.
      class StartTest < Base
        director_only

        SUMMARY_PATH = Rails.root.join('docs/sandbox/current-test.md')
        TEST_BOT = ENV.fetch('SANDBOX_TEST_BOT_USERNAME', '@anvictory_testsbot')

        def handle
          status = ::Sandbox::Codespace.start!
          ::Sandbox::CodespaceReadyJob.perform_async(chat_id) unless status.awake?
          reply([headline(status), '', summary].compact_blank.join("\n"))
        rescue ::Sandbox::Codespace::Error => e
          reply("⚠️ Песочницу разбудить не вышло: #{escape_html(e.message)}")
          :error
        end

        private

        def chat_id = message.dig('chat', 'id')

        def headline(status)
          if status.awake?
            "🧪 <b>Песочница уже на ходу</b> — пиши #{escape_html(TEST_BOT)} в личку."
          else
            "🧪 <b>Бужу песочницу</b> (#{escape_html(status.state)}) — минута-полторы, напишу сюда, когда встанет.\n" \
              "Бот песочницы: #{escape_html(TEST_BOT)}."
          end
        end

        # Что именно проверяем — в файле рядом с кодом: правит тот же, кто
        # выкатывает, и текст едет в прод вместе с изменениями.
        def summary
          return nil unless SUMMARY_PATH.exist?

          text = SUMMARY_PATH.read.to_s.gsub(/<!--.*?-->/m, '')
          # Из markdown Telegram понимает мало: заголовок и **жирный** в <b>,
          # остальное отдаём как есть, заэкранировав.
          escape_html(text).gsub(/^#+\s*(.+)$/) { "<b>#{Regexp.last_match(1)}</b>" }
                           .gsub(/\*\*(.+?)\*\*/) { "<b>#{Regexp.last_match(1)}</b>" }
                           .gsub(/`([^`]+)`/) { "<code>#{Regexp.last_match(1)}</code>" }
                           .squeeze("\n").strip
        end
      end
    end
  end
end
