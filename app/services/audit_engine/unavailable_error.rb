# frozen_string_literal: true

module AuditEngine
  # Circuit breaker is open OR network is unreachable OR engine returned 5xx.
  # Transient — Sidekiq's `retry_on` handles this. Distinct from ResponseError
  # so we don't retry on 422 validation errors.
  class UnavailableError < Error; end
end
