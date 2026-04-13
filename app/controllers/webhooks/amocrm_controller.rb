# frozen_string_literal: true

class Webhooks::AmocrmController < ApplicationController
  skip_before_action :verify_authenticity_token
  before_action :verify_amocrm_token

  def create
    # TODO: реализовать обработку событий amoCRM
    render plain: 'OK'
  end

  private

  # amoCRM поддерживает настройку секретного токена в параметрах интеграции.
  # Установите AMOCRM_WEBHOOK_SECRET в .env.
  def verify_amocrm_token
    expected = ENV['AMOCRM_WEBHOOK_SECRET']
    return if expected.blank? # без секрета — пропускаем проверку (только для dev)

    provided = request.headers['X-Amocrm-Signature'] ||
               params[:token].presence
    unless provided && ActiveSupport::SecurityUtils.secure_compare(expected.to_s, provided.to_s)
      Rails.logger.warn "[amoCRM webhook] Unauthorized request from IP: #{request.remote_ip}"
      render plain: 'Unauthorized', status: :unauthorized
    end
  end
end
