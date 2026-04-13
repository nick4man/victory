# frozen_string_literal: true

# == Schema Information
#
# Table name: notifications
#
#  id                :bigint           not null, primary key
#  user_id           :bigint           not null
#  notifiable_type   :string
#  notifiable_id     :bigint
#  notification_type :string           not null
#  title             :string           not null
#  body              :text
#  link              :string
#  read_at           :datetime
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#

class Notification < ApplicationRecord
  # ============================================
  # ASSOCIATIONS
  # ============================================
  belongs_to :user
  belongs_to :notifiable, polymorphic: true, optional: true

  # ============================================
  # VALIDATIONS
  # ============================================
  validates :notification_type, :title, presence: true

  # ============================================
  # SCOPES
  # ============================================
  scope :unread,  -> { where(read_at: nil) }
  scope :read,    -> { where.not(read_at: nil) }
  scope :recent,  -> { order(created_at: :desc) }
  scope :by_type, ->(type) { where(notification_type: type) }

  # ============================================
  # NOTIFICATION TYPES
  # ============================================
  TYPES = %w[
    new_inquiry
    inquiry_status_change
    new_message
    viewing_confirmed
    viewing_reminder
    valuation_completed
    property_published
    property_sold
    system
  ].freeze

  # ============================================
  # INSTANCE METHODS
  # ============================================
  def read?
    read_at.present?
  end

  def unread?
    read_at.nil?
  end

  def mark_as_read!
    update(read_at: Time.current) if unread?
  end

  # ============================================
  # CLASS METHODS
  # ============================================
  def self.ransackable_attributes(_auth_object = nil)
    %w[notification_type title read_at created_at user_id]
  end

  def self.create_for(user:, type:, title:, body: nil, link: nil, notifiable: nil)
    create!(
      user:              user,
      notification_type: type,
      title:             title,
      body:              body,
      link:              link,
      notifiable:        notifiable
    )
  rescue ActiveRecord::RecordInvalid => e
    Rails.logger.error "Failed to create notification: #{e.message}"
    nil
  end
end
