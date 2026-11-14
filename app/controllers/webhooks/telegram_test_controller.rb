# frozen_string_literal: true

module Webhooks
  # Вебхук тестового бота (TELEGRAM_TEST_BOT_TOKEN) — песочница карточек CRM.
  #
  # В отличие от основного вебхука, секрет обязателен без «переходного»
  # пропуска: вход новый, совместимость сохранять не с чем. Пустой ENV —
  # вход закрыт (CLAUDE.md: вебхук при пустом секрете отказывает).
  #
  # ActionController::API, а не ApplicationController: браузерного стека
  # (сессия, куки, CSRF) здесь нет, запрос подлинен только по секрету в
  # заголовке — отключать нечего.
  class TelegramTestController < ActionController::API

    def create
      return head(:forbidden) unless authorized?

      Telegram::InboundProcessorJob.perform_async(JSON.parse(request.raw_post), 'test')
      head :ok
    rescue JSON::ParserError
      head :ok # Telegram повторяет не-2xx; битое тело повторять незачем
    end

    private

    def authorized?
      expected = ENV['TELEGRAM_TEST_WEBHOOK_SECRET'].to_s
      return false if expected.blank? || ENV['TELEGRAM_TEST_BOT_TOKEN'].blank?

      ActiveSupport::SecurityUtils.secure_compare(expected, request.headers['X-Telegram-Bot-Api-Secret-Token'].to_s)
    end
  end
end
