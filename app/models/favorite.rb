# frozen_string_literal: true

class Favorite < ApplicationRecord
  # ============================================
  # ASSOCIATIONS
  # ============================================
  
  belongs_to :user, counter_cache: true
  belongs_to :property
  
  # ============================================
  # VALIDATIONS
  # ============================================
  
  validates :user_id, uniqueness: { scope: :property_id, message: 'уже добавлено в избранное' }
  
  # ============================================
  # SCOPES
  # ============================================
  
  scope :recent, -> { order(created_at: :desc) }
  scope :by_user, ->(user_id) { where(user_id: user_id) }
  scope :by_property, ->(property_id) { where(property_id: property_id) }
  
  # ============================================
  # CALLBACKS
  # ============================================
  
  after_create :notify_property_owner
  
  # ============================================
  # INSTANCE METHODS
  # ============================================
  
  # Formatted created date
  def created_at_formatted
    I18n.l(created_at, format: :long)
  end
  
  private
  
  def notify_property_owner
    # Send notification to property owner
    # FavoriteNotificationJob.perform_later(self.id)
  end
end

