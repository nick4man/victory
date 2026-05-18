# frozen_string_literal: true

module Webhooks
  # YooKassa payment webhook — пока не используется (placeholder для будущей
  # payments integration). Без auth любой может POST'ить и засорять логи /
  # триггерить downstream side-effects если будет добавлена бизнес-логика.
  #
  # Auth strategy:
  #   - YOOKASSA_WEBHOOK_SECRET не настроен → 501 Not Implemented
  #     (signals что endpoint неактивен)
  #   - настроен → требуем HMAC-SHA256 заголовок Yookassa («Signature»
  #     по docs https://yookassa.ru/developers/using-api/webhooks).
  class YookassaController < ApplicationController
    skip_before_action :verify_authenticity_token, raise: false

    def create
      secret = ENV['YOOKASSA_WEBHOOK_SECRET'].to_s
      return head :not_implemented if secret.blank?

      return head :unauthorized unless valid_signature?(secret)

      Rails.logger.info("Webhook YooKassa: #{request.raw_post.truncate(2000)}")
      head :ok
    end

    private

    def valid_signature?(secret)
      provided = request.headers['HTTP_X_YOOKASSA_SIGNATURE'].to_s
      return false if provided.blank?

      raw = request.raw_post.to_s
      expected = OpenSSL::HMAC.hexdigest('SHA256', secret, raw)
      ActiveSupport::SecurityUtils.secure_compare(provided, expected)
    end
  end
end
