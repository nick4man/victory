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
    if expected.blank?
      Rails.logger.error '[amoCRM webhook] AMOCRM_WEBHOOK_SECRET is not configured'
      render plain: 'Unauthorized', status: :unauthorized and return
    end

    provided = request.headers['X-Amocrm-Signature'] ||
               params[:token].presence
    unless provided && ActiveSupport::SecurityUtils.secure_compare(expected.to_s, provided.to_s)
      Rails.logger.warn "[amoCRM webhook] Unauthorized request from IP: #{request.remote_ip}"
      render plain: 'Unauthorized', status: :unauthorized
    end
  end
end
