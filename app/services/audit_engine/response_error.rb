# frozen_string_literal: true

module AuditEngine
  # Engine returned a non-2xx, non-retryable response (4xx auth/validation).
  # Body is preserved for Sidekiq job logging. Sidekiq must NOT retry.
  class ResponseError < Error
    attr_reader :status, :body

    def initialize(status, body)
      @status = status
      @body = body
      preview = body.is_a?(Hash) ? body.to_json : body.to_s
      super("audit-engine #{status}: #{preview[0, 500]}")
    end
  end
end
