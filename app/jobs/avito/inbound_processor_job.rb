# frozen_string_literal: true

module Avito
  # Async worker for Avito Messenger webhook payloads.
  #
  # Sidekiq retry policy gives us the required transient-error handling; the
  # processor itself re-raises non-idempotent failures so they can be retried.
  class InboundProcessorJob
    include Sidekiq::Job
    sidekiq_options queue: :default, retry: 3

    def perform(payload_json)
      payload = payload_json.is_a?(Hash) ? payload_json : JSON.parse(payload_json.to_s)
      Avito::InboundProcessor.new(payload).call
    rescue StandardError => e
      Rails.logger.error("[Avito::InboundProcessorJob] #{e.class}: #{e.message}")
      raise
    end
  end
end
