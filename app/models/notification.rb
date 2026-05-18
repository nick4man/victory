# frozen_string_literal: true

# In-app notification shown on /dashboard/notifications. See
# `db/migrate/20260514100000_create_notifications.rb` for column docs.
#
# Common kinds:
#   inquiry        — submitted, contacted, answered, status changed
#   valuation      — express / investment audit ready
#   property_match — saved-search hit
#   message        — staff replied via chat
#   lead_stage     — D4: stage transition в LeadEvent pipeline
#                    (new → first_contact → show → contract → deal → closed_*)
#   system         — generic
class Notification < ApplicationRecord
  belongs_to :user
  belongs_to :notifiable, polymorphic: true, optional: true

  KINDS = %w[inquiry valuation property_match message lead_stage system].freeze

  validates :kind,  presence: true, inclusion: { in: KINDS }
  validates :title, presence: true, length: { maximum: 200 }

  scope :unread,        -> { where(read_at: nil) }
  scope :read,          -> { where.not(read_at: nil) }
  scope :not_archived,  -> { where(archived_at: nil) }
  scope :recent,        -> { order(created_at: :desc) }

  def read?
    read_at.present?
  end

  def archived?
    archived_at.present?
  end

  def mark_read!
    update_column(:read_at, Time.current) unless read?
  end

  def archive!
    update_column(:archived_at, Time.current)
  end

  # One-call constructor used by mailers/jobs/services to push a new entry
  # without each caller knowing the schema. Returns the created Notification
  # or nil if `user` is blank (e.g. anonymous submitter).
  def self.notify!(user, kind:, title:, body: nil, url: nil, notifiable: nil)
    return nil if user.blank?

    create!(
      user:       user,
      kind:       kind,
      title:      title,
      body:       body,
      url:        url,
      notifiable: notifiable
    )
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.warn("[Notification.notify!] #{e.message}")
    nil
  end
end
