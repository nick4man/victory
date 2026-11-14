# frozen_string_literal: true

# Idempotency record per Avito Messenger message id.
# Created before processing; duplicates raise RecordNotUnique and are skipped.
class AvitoWebhookAck < ApplicationRecord
  validates :message_id,    presence: true, uniqueness: true
  validates :processed_at,  presence: true

  scope :not_deleted, -> { where(deleted_at: nil) }
  scope :stale, ->(older_than: 7.days.ago) { where(processed_at: ...older_than) }

  default_scope { not_deleted }
end
