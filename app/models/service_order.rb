# frozen_string_literal: true

class ServiceOrder < ApplicationRecord
  belongs_to :service_type
  belongs_to :user, optional: true
  has_many :notes, as: :notable, dependent: :destroy

  ACTIVE_STATES = %w[lead active ad prepayment deferred].freeze
  scope :active, -> { where(deal_state: ACTIVE_STATES) }
  scope :recent, -> { order(synced_at: :desc) }
end
