# frozen_string_literal: true

module AuditEngine
  # Base error for audit-engine integration. Callers (controllers, jobs)
  # rescue this to render fallback UI / decide on retry.
  class Error < StandardError; end
end
