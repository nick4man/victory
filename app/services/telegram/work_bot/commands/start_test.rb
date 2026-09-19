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
        # sendMessage не принимает больше 4096 символов, а файл правят руками
        # перед каждым прогоном — обрезаем, чтобы он не вырос до отказа.
        SUMMARY_LIMIT = 3500

        def handle
          unless message.dig('chat', 'type') == 'private'
            return reply('🧪 Песочницу бужу только в личке: в сводке — что именно сейчас тестируем.')
          end

          status = ::Sandbox::Codespace.start!
          ::Sandbox::CodespaceReadyJob.perform_async(chat_id) unless status.awake?
          reply([headline(status), summary].compact.join("\n\n"))
        rescue ::Sandbox::Codespace::Error => e
          reply("⚠️ Песочницу разбудить не вышло: #{escape_html(e.message)}")
          :error
        end

        # В Router и в меню команда записана слитно, а имя класса даёт
        # «/start_test» — из-за расхождения в BotCommandLog копились бы два
        # ключа на одну команду (см. комментарий к Base#command_key).
        def command_key = '/starttest'

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

          # Из markdown Telegram понимает мало: заголовок и **жирный** в <b>,
          # остальное отдаём как есть, заэкранировав.
          escape_html(without_comments(SUMMARY_PATH.read.to_s))
            .gsub(/^#+\s*(.+)$/) { "<b>#{Regexp.last_match(1)}</b>" }
            .gsub(/\*\*(.+?)\*\*/) { "<b>#{Regexp.last_match(1)}</b>" }
            .gsub(/`([^`]+)`/) { "<code>#{Regexp.last_match(1)}</code>" }
            .squeeze("\n").strip.truncate(SUMMARY_LIMIT)
        end

        # Комментарии-подсказки редактору выбрасываем построчно, а не
        # регуляркой по тексту: вырезание разметки regexp'ом — приглашение к
        # инъекции (CodeQL). Незакрытый комментарий не съедает остаток файла:
        # лучше показать лишнюю строку, чем пустой список проверок.
        def without_comments(text)
          inside = false
          kept = text.lines.reject do |line|
            open_here = line.include?('<!--')
            skip = inside || open_here
            inside = true if open_here && !line.include?('-->')
            inside = false if inside && !open_here && line.include?('-->')
            skip
          end
          inside ? text : kept.join
        end
      end
    end
  end
end
