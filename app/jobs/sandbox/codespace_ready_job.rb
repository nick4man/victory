# frozen_string_literal: true

module Sandbox
  # Ждёт, пока разбуженный codespace поднимется, и пишет об этом тому, кто
  # звал /starttest: старт занимает минуту-полторы, держать на это веб-запрос
  # незачем, а проверяющий не должен гадать, можно ли уже писать боту.
  class CodespaceReadyJob
    include Sidekiq::Job
    sidekiq_options queue: :low_priority, retry: false

    ATTEMPTS = 12
    DELAY = 15

    def perform(chat_id)
      ATTEMPTS.times do
        sleep(DELAY)
        next unless ::Sandbox::Codespace.status.awake?

        bot = ::Telegram::WorkBot::Commands::StartTest::TEST_BOT
        return notify(chat_id, "✅ Песочница поднялась — можно тестировать в #{bot}.")
      end
      notify(chat_id, '⚠️ Песочница не поднялась за три минуты — посмотри codespace на GitHub.')
    rescue ::Sandbox::Codespace::Error => e
      notify(chat_id, "⚠️ Не смог дождаться песочницы: #{e.message}")
    end

    private

    def notify(chat_id, text)
      ::Telegram::Client.new.send_message(text, chat_id: chat_id)
    rescue ::Telegram::Client::Error => e
      Rails.logger.warn("[Sandbox::CodespaceReadyJob] #{e.class}: #{e.message}")
    end
  end
end
