# frozen_string_literal: true

class Review < ApplicationRecord
  # ============================================
  # ASSOCIATIONS
  # ============================================
  
  belongs_to :user
  belongs_to :property, optional: true
  belongs_to :agent, class_name: 'User', optional: true
  
  # ============================================
  # ENUMS
  # ============================================
  
  enum status: {
    pending: 'pending',
    approved: 'approved',
    rejected: 'rejected'
  }, _prefix: true
  
  # ============================================
  # VALIDATIONS
  # ============================================
  
  validates :rating, presence: true, numericality: { in: 1..5 }
  validates :content, presence: true, length: { minimum: 10, maximum: 1000 }
  validates :title, length: { maximum: 255 }, allow_blank: true
  
  # ============================================
  # SCOPES
  # ============================================
  
  scope :recent, -> { order(created_at: :desc) }
  scope :approved, -> { where(status: 'approved') }
  scope :pending, -> { where(status: 'pending') }
  scope :rejected, -> { where(status: 'rejected') }
  scope :by_rating, ->(rating) { where(rating: rating) }
  scope :high_rated, -> { where('rating >= ?', 4) }
  scope :low_rated, -> { where('rating <= ?', 2) }
  scope :for_property, ->(property_id) { where(property_id: property_id) }
  scope :for_agent, ->(agent_id) { where(agent_id: agent_id) }
  
  # ============================================
  # CALLBACKS
  # ============================================
  
  after_create :notify_moderators
  after_update :notify_author, if: :saved_change_to_status?
  
  # ============================================
  # INSTANCE METHODS
  # ============================================
  
  # Approve review
  def approve!
    update(status: 'approved', moderated_at: Time.current)
  end
  
  # Reject review
  def reject!(reason = nil)
    update(status: 'rejected', moderated_at: Time.current, moderation_notes: reason)
  end
  
  # Check if moderated
  def moderated?
    moderated_at.present?
  end
  
  # Stars representation
  def stars
    '★' * rating + '☆' * (5 - rating)
  end
  
  # Rating percentage
  def rating_percentage
    (rating.to_f / 5.0 * 100).round
  end
  
  # Status humanized
  def status_humanized
    I18n.t("activerecord.attributes.review.statuses.#{status}", default: status.humanize)
  end
  
  # Check if verified review
  def verified?
    verified_at.present?
  end
  
  # Mark as verified
  def verify!
    update(verified_at: Time.current)
  end
  
  private
  
  def notify_moderators
    # ReviewModerationJob.perform_later(self.id)
  end
  
  def notify_author
    # ReviewStatusNotificationJob.perform_later(self.id)
  end
end

