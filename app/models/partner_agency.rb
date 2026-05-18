# frozen_string_literal: true

# Phase 3 MLS/YRL — partner agency entity для commission tracking.
# Связана с ExternalListing через `feed_source_key` (matches source / source_id
# prefix). Используется в Referrals::AutoCreator для matching при Inquiry create.
#
# Status enum:
#   active   — нормальная работа, лиды передаём
#   inactive — temporarily not accepting (отпуск менеджера, etc.)
#   blocked  — disputed commissions / bad faith, leads НЕ передаём
class PartnerAgency < ApplicationRecord
  default_scope { where(deleted_at: nil) }

  has_many :referrals, dependent: :nullify

  STATUSES = %w[active inactive blocked].freeze

  validates :name, presence: true, length: { maximum: 200 }
  validates :slug, presence: true, uniqueness: true,
                   format: { with: /\A[a-z0-9_-]+\z/, message: 'lowercase + digits + - / _ only' }
  validates :status, inclusion: { in: STATUSES }
  validates :default_commission_rate,
            numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 },
            allow_nil: true
  validates :contact_email, format: { with: URI::MailTo::EMAIL_REGEXP, allow_blank: true }

  scope :active,        -> { where(status: 'active') }
  scope :with_feed_key, ->(key) { where(feed_source_key: key) }

  # Soft-delete consistent with project convention.
  def destroy
    update!(deleted_at: Time.current)
  end

  # Display label including commission rate (для admin UI).
  def display_label
    rate = default_commission_rate.present? ? " · #{(default_commission_rate * 100).to_i}%" : ''
    "#{name}#{rate}"
  end

  # Active+claimable: лиды можно передавать сейчас.
  def claimable?
    status == 'active' && deleted_at.nil?
  end
end
