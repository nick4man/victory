# frozen_string_literal: true

module Webhooks
  # Telegram bot webhook: dispatched to InboundProcessor which matches
  # reply-to messages back to a Conversation and posts agent reply into
  # the chat widget via ActionCable.
  class TelegramController < ApplicationController
    skip_before_action :verify_authenticity_token, raise: false

    def create
      payload = parse_payload
      Telegram::InboundProcessor.new(payload).call if payload.present?

      head :ok
    rescue StandardError => e
      Rails.logger.error("[Telegram webhook] #{e.class} #{e.message}")
      head :ok # always 200 — Telegram retries non-2xx aggressively
    end

    private

    def parse_payload
      raw = request.body.read
      return {} if raw.blank?
      JSON.parse(raw)
    rescue JSON::ParserError
      params.to_unsafe_h.except(:controller, :action).stringify_keys
    end
  end
end
