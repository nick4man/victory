# frozen_string_literal: true

# Service offered by the agency (mortgage, legal advice, valuation, ...).
# Maps to Topnlab service_type_id once admin links them via /dashboard/admin/reports
# or db/seeds.rb. Records with crm_type_id=nil still work for public submissions —
# user inquiries land in local Inquiry model and agent transfers them to CRM manually.
class ServiceType < ApplicationRecord
  has_many :service_orders, dependent: :destroy

  scope :public_visible, -> { where(public_visible: true) }
  scope :active,         -> { where(active: true) }
  scope :ordered,        -> { order(:order_position, :title) }

  CATEGORIES = %w[finance legal technical marketing search].freeze
  validates :slug, presence: true, uniqueness: true, format: { with: /\A[a-z0-9_-]+\z/ }
  validates :title, presence: true
  validates :category, inclusion: { in: CATEGORIES }, allow_blank: true
end
