# frozen_string_literal: true

module Telegram
  # Какой бот обрабатывает текущий апдейт: основной (@anvictorybot) или
  # тестовый (TELEGRAM_TEST_BOT_TOKEN — песочница карточек CRM, только личка).
  #
  # Контекст выставляет вход (Telegram::InboundProcessorJob) на время
  # обработки апдейта, поэтому ~70 мест `Telegram::Client.new` не трогаются:
  # токен выбирается здесь, и ответ уходит от того бота, которому писали.
  #
  # В Sidekiq-джобы контекст сам не переносится — намеренно: побочный джоб
  # песочницы с bot=test молча не обновил бы рабочую группу. Джоб, которому
  # нужен тестовый бот, выставляет контекст по данным (CrmCards::ExportJob).
  class BotContext < ActiveSupport::CurrentAttributes
    BOTS = %w[main test].freeze

    attribute :bot

    def self.test?
      bot.to_s == 'test'
    end

    def self.token
      test? ? ENV.fetch('TELEGRAM_TEST_BOT_TOKEN', nil) : ENV.fetch('TELEGRAM_BOT_TOKEN', nil)
    end

    # Неизвестное имя — ошибка, а не откат на основной бот: песочница,
    # говорящая голосом рабочего бота, хуже падения.
    def self.within(name, &)
      raise ArgumentError, "Неизвестный Telegram-бот: #{name.inspect}" unless BOTS.include?(name.to_s)

      set(bot: name.to_s, &)
    end
  end
end
