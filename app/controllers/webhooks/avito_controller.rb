# frozen_string_literal: true

module Webhooks
  # Receives Avito Messenger webhook V3 callbacks.
  #
  # Avito sends a JSON payload with shape:
  #   { "payload": { "type": "message", "value": { ...WebhookMessage... } } }
  #
  # Auth: the webhook URL registered in Avito can carry a token query param
  # (ENV['AVITO_WEBHOOK_SECRET']). If the secret is configured, requests without
  # it are rejected. We always return 200 quickly and do the actual work in
  # Sidekiq so that Avito does not retry on our processing delays.
  class AvitoController < ApplicationController
    skip_before_action :verify_authenticity_token, raise: false

    def create
      return unauthorized unless valid_signature?

      payload = parse_payload
      Avito::InboundProcessorJob.perform_async(payload) if payload.present?

      head :ok
    rescue StandardError => e
      Rails.logger.error("[Avito webhook] #{e.class} #{e.message}")
      head :ok
    end

    private

    def valid_signature?
      expected = ENV['AVITO_WEBHOOK_SECRET'].to_s
      return true if expected.blank?

      provided = request.params['token'].to_s
      return true if ActiveSupport::SecurityUtils.secure_compare(provided, expected)

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
