# frozen_string_literal: true

class Message < ApplicationRecord
  # ============================================
  # ASSOCIATIONS
  # ============================================
  
  belongs_to :sender, class_name: 'User'
  belongs_to :recipient, class_name: 'User'
  belongs_to :property, optional: true
  belongs_to :parent, class_name: 'Message', optional: true
  has_many :replies, class_name: 'Message', foreign_key: :parent_id, dependent: :destroy
  
  # ============================================
  # VALIDATIONS
  # ============================================
  
  validates :body, presence: true
  validates :sender_id, :recipient_id, presence: true
  
  # ============================================
  # SCOPES
  # ============================================
  
  scope :recent, -> { order(created_at: :desc) }
  scope :unread, -> { where(read: false) }
  scope :read, -> { where(read: true) }
  scope :between_users, ->(user1_id, user2_id) {
    where('(sender_id = ? AND recipient_id = ?) OR (sender_id = ? AND recipient_id = ?)',
          user1_id, user2_id, user2_id, user1_id)
  }
  scope :for_user, ->(user_id) {
    where('sender_id = ? OR recipient_id = ?', user_id, user_id)
  }
  scope :sent_by, ->(user_id) { where(sender_id: user_id) }
  scope :received_by, ->(user_id) { where(recipient_id: user_id) }
  scope :about_property, ->(property_id) { where(property_id: property_id) }
  scope :root_messages, -> { where(parent_id: nil) }
  
  # ============================================
  # CALLBACKS
  # ============================================
  
  after_create :send_notification
  
  # ============================================
  # INSTANCE METHODS
  # ============================================
  
  # Mark as read
  def mark_as_read!
    update(read: true, read_at: Time.current) unless read?
  end
  
  # Mark as unread
  def mark_as_unread!
    update(read: false, read_at: nil)
  end
  
  # Check if conversation thread
  def conversation?
    replies.any?
  end
  
  # Get conversation thread
  def conversation_thread
    return [] unless parent.present?
    parent.conversation_thread + [self]
  end
  
  # Reply to message
  def reply(sender:, body:)
    Message.create(
      sender: sender,
      recipient: self.sender,
      body: body,
      property: property,
      parent: self
    )
  end
  
  # Shortened body for preview
  def body_preview(length = 100)
    body.truncate(length)
  end
  
  private
  
  def send_notification
    # MessageNotificationJob.perform_later(self.id)
  end
end

