# frozen_string_literal: true

module Webhooks
  # Receives Avito Messenger webhook V3 callbacks.
  #
  # Avito sends a JSON payload with shape:
  #   { "payload": { "type": "message", "value": { ...WebhookMessage... } } }
  #
  # Auth: the webhook URL registered in Avito can carry a token query param
  # (ENV['AVITO_WEBHOOK_SECRET']). If the secret is not configured we refuse
  # with 501 Not Implemented (same as the other webhook controllers); if it is
  # configured, requests without a matching token are rejected with 401.
  # Successful requests return 200 quickly and do the actual work in Sidekiq so
  # that Avito does not retry on our processing delays.
  class AvitoController < ApplicationController
    skip_before_action :verify_authenticity_token, raise: false

    def create
      secret = ENV['AVITO_WEBHOOK_SECRET'].to_s
      return head :not_implemented if secret.blank?

      return unauthorized unless valid_signature?(secret)

      payload = parse_payload
      Avito::InboundProcessorJob.perform_async(payload) if payload.present?

      head :ok
    rescue StandardError => e
      Rails.logger.error("[Avito webhook] #{e.class} #{e.message}")
      head :ok
    end

    private

    def valid_signature?(secret)
      provided = request.params['token'].to_s
      return true if ActiveSupport::SecurityUtils.secure_compare(provided, secret)

      Rails.logger.warn("[Avito webhook] token mismatch from ip=#{request.remote_ip}")
      false
    end

    def unauthorized
      head :unauthorized
    end

    def parse_payload
      raw = request.body.read
      return {} if raw.blank?

      JSON.parse(raw)
    rescue JSON::ParserError
      params.to_unsafe_h.except(:controller, :action).stringify_keys
    end
  end
end
