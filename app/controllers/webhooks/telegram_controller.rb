# frozen_string_literal: true

class Webhooks::TelegramController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :verify_telegram_secret

  def create
    # TODO: реализовать обработку Telegram-событий
    render plain: 'OK'
  end

  private

  # Telegram передаёт секрет через заголовок X-Telegram-Bot-Api-Secret-Token.
  # Установите TELEGRAM_WEBHOOK_SECRET в .env.
  def verify_telegram_secret
    expected = ENV['TELEGRAM_WEBHOOK_SECRET']
    if expected.blank?
      Rails.logger.error '[Telegram webhook] TELEGRAM_WEBHOOK_SECRET is not configured'
      render plain: 'Unauthorized', status: :unauthorized and return
    end

    provided = request.headers['X-Telegram-Bot-Api-Secret-Token']
    unless provided && ActiveSupport::SecurityUtils.secure_compare(expected.to_s, provided.to_s)
      Rails.logger.warn "[Telegram webhook] Invalid secret from IP: #{request.remote_ip}"
      render plain: 'Unauthorized', status: :unauthorized
    end
  end
end
