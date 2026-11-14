# frozen_string_literal: true

# Incoming/outgoing message from Avito Messenger.
# Linked to a Property when the Avito item_id matches Property.external_id
# for source 'avito'.
class AvitoMessage < ApplicationRecord
  belongs_to :property, optional: true

  enum :direction, { incoming: 'incoming', outgoing: 'outgoing' }, prefix: :direction

  validates :message_id,   presence: true, uniqueness: true
  validates :chat_id,      presence: true
  validates :author_id,    presence: true
  validates :user_id,      presence: true
  validates :content_type, presence: true
  validates :payload,      presence: true
  validates :direction,    presence: true, inclusion: { in: %w[incoming outgoing] }

  scope :not_deleted, -> { where(deleted_at: nil) }
  scope :recent, -> { order(created_at: :desc) }

  default_scope { not_deleted }
end
