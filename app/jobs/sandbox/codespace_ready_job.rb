# frozen_string_literal: true

module Sandbox
  # Ждёт, пока разбуженный codespace поднимется, и пишет об этом тому, кто
  # звал /starttest: старт занимает минуту-полторы, держать на это веб-запрос
  # незачем, а проверяющий не должен гадать, можно ли уже писать боту.
  #
  # Каждая проверка — отдельный запуск через perform_in, а не sleep в цикле:
  # спящий джоб занимал бы воркер на три минуты и не пережил бы перезапуск
  # sidekiq (retry: false), молча проглотив обещанное сообщение.
  class CodespaceReadyJob
    include Sidekiq::Job
    sidekiq_options queue: :low_priority, retry: false

    ATTEMPTS = 12
    DELAY = 15

    def perform(chat_id, attempt = 1, thread_id = nil)
      return notify(chat_id, thread_id, '⚠️ Песочница не поднялась за три минуты — посмотри codespace на GitHub.') if
        attempt > ATTEMPTS

      if awake?
        bot = ::Telegram::WorkBot::Commands::StartTest::TEST_BOT
        return notify(chat_id, thread_id, "✅ Песочница поднялась — можно тестировать в #{bot}.")
      end

      self.class.perform_in(DELAY, chat_id, attempt + 1, thread_id)
    end

    private

    # Сбой GitHub на одной проверке — не повод бросать ожидание: codespace в
    # это время может спокойно подниматься.
    def awake?
      ::Sandbox::Codespace.status.awake?
    rescue ::Sandbox::Codespace::Error => e
      Rails.logger.warn("[Sandbox::CodespaceReadyJob] #{e.class}: #{e.message}")
      false
    end

    def notify(chat_id, thread_id, text)
      ::Telegram::Client.new.send_message(text, chat_id: chat_id, message_thread_id: thread_id)
    rescue ::Telegram::Client::Error => e
      Rails.logger.warn("[Sandbox::CodespaceReadyJob] #{e.class}: #{e.message}")
    end
  end
end
