# frozen_string_literal: true

module Webhooks
  # AmoCRM webhook — placeholder (текущий CRM это Topnlab, не AmoCRM).
  # Без auth любой может POST'ить и забивать логи. Token-based gate:
  #
  #   - AMOCRM_WEBHOOK_SECRET не настроен → 501 Not Implemented
  #   - настроен → ?secret=… в query OR Authorization: Bearer
  class AmocrmController < ApplicationController
    skip_before_action :verify_authenticity_token, raise: false

    def create
      secret = ENV['AMOCRM_WEBHOOK_SECRET'].to_s
      return head :not_implemented if secret.blank?

      return head :unauthorized unless valid_credential?(secret)

      Rails.logger.info("Webhook AmoCRM: #{request.raw_post.truncate(2000)}")
      head :ok
    end

    private

    def valid_credential?(secret)
      provided = params[:secret].to_s.presence ||
                 bearer_token.to_s
      return false if provided.blank?

      ActiveSupport::SecurityUtils.secure_compare(provided, secret)
    end

    def bearer_token
      header = request.headers['Authorization'].to_s
      header.start_with?('Bearer ') ? header.sub(/\ABearer /, '') : nil
    end
  end
end
