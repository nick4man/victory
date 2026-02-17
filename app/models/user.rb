# frozen_string_literal: true

# == Schema Information
#
# Table name: users
#
#  id                     :bigint           not null, primary key
#  email                  :string           default(""), not null
#  encrypted_password     :string           default(""), not null
#  reset_password_token   :string
#  reset_password_sent_at :datetime
#  remember_created_at    :datetime
#  sign_in_count          :integer          default(0), not null
#  current_sign_in_at     :datetime
#  last_sign_in_at        :datetime
#  current_sign_in_ip     :string
#  last_sign_in_ip        :string
#  confirmation_token     :string
#  confirmed_at           :datetime
#  confirmation_sent_at   :datetime
#  unconfirmed_email      :string
#  failed_attempts        :integer          default(0), not null
#  unlock_token           :string
#  locked_at              :datetime
#  first_name             :string
#  last_name              :string
#  phone                  :string
#  avatar_url             :string
#  role                   :integer          default("client"), not null
#  provider               :string
#  uid                    :string
#  bio                    :text
#  company                :string
#  position               :string
#  notification_settings  :jsonb
#  preferences            :jsonb
#  properties_count       :integer          default(0), not null
#  inquiries_count        :integer          default(0), not null
#  favorites_count        :integer          default(0), not null
#  active                 :boolean          default(true), not null
#  last_activity_at       :datetime
#  deleted_at             :datetime
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#

class User < ApplicationRecord
  # ============================================
  # DEVISE
  # ============================================
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable,
         :trackable, :confirmable, :lockable,
         :omniauthable, omniauth_providers: %i[google_oauth2 yandex]

  # ============================================
  # ASSOCIATIONS
  # ============================================
  
  # Properties
  has_many :properties, dependent: :destroy
  has_many :published_properties, -> { published }, class_name: 'Property'
  has_many :moderated_properties, class_name: 'Property', foreign_key: 'moderated_by_id'
  
  # Favorites
  has_many :favorites, dependent: :destroy
  has_many :favorite_properties, through: :favorites, source: :property
  
  # Inquiries
  has_many :inquiries, dependent: :destroy
  
  # Saved Searches
  has_many :saved_searches, dependent: :destroy
  has_many :active_saved_searches, -> { active }, class_name: 'SavedSearch'
  
  # Notifications
  has_many :notifications, dependent: :destroy
  has_many :unread_notifications, -> { unread }, class_name: 'Notification'
  
  # Messages
  has_many :sent_messages, class_name: 'Message', foreign_key: 'sender_id', dependent: :destroy
  has_many :received_messages, class_name: 'Message', foreign_key: 'recipient_id', dependent: :destroy
  
  # Viewing History
  has_many :property_views, dependent: :destroy
  has_many :viewed_properties, through: :property_views, source: :property
  
  # Reviews
  has_many :reviews, dependent: :destroy
  
  # Viewing Schedules
  has_many :viewing_schedules, dependent: :destroy
  
  # Avatar
  has_one_attached :avatar

  # ============================================
  # ENUMS
  # ============================================
  enum role: {
    client: 0,    # Обычный клиент
    agent: 1,     # Агент по недвижимости
    admin: 2      # Администратор
  }, _prefix: true

  # ============================================
  # VALIDATIONS
  # ============================================
  validates :email, presence: true, uniqueness: { case_sensitive: false }
  validates :phone, uniqueness: { allow_blank: true }
  validates :first_name, presence: true, length: { maximum: 50 }
  validates :last_name, presence: true, length: { maximum: 50 }
  validates :bio, length: { maximum: 500 }, allow_blank: true
  
  validate :phone_format, if: :phone?

  # ============================================
  # CALLBACKS
  # ============================================
  before_validation :normalize_phone
  before_save :set_default_preferences, if: :new_record?
  after_create :send_welcome_notification

  # ============================================
  # SCOPES
  # ============================================
  scope :active, -> { where(active: true, deleted_at: nil) }
  scope :inactive, -> { where(active: false) }
  scope :clients, -> { where(role: :client) }
  scope :agents, -> { where(role: :agent) }
  scope :admins, -> { where(role: :admin) }
  scope :confirmed, -> { where.not(confirmed_at: nil) }
  scope :unconfirmed, -> { where(confirmed_at: nil) }
  scope :recently_active, -> { where('last_activity_at > ?', 1.week.ago) }
  scope :not_deleted, -> { where(deleted_at: nil) }

  # Default scope
  default_scope { not_deleted }

  # ============================================
  # CLASS METHODS
  # ============================================
  
  # OAuth authentication
  def self.from_omniauth(auth)
    where(provider: auth.provider, uid: auth.uid).first_or_create do |user|
      user.email = auth.info.email
      user.password = Devise.friendly_token[0, 20]
      user.first_name = auth.info.first_name || auth.info.name.to_s.split.first
      user.last_name = auth.info.last_name || auth.info.name.to_s.split.last
      user.avatar_url = auth.info.image
      user.confirmed_at = Time.current # Auto-confirm OAuth users
    end
  end

  # Search users
  def self.search(query)
    return none if query.blank?
    
    where('first_name ILIKE ? OR last_name ILIKE ? OR email ILIKE ?',
          "%#{query}%", "%#{query}%", "%#{query}%")
  end

  # ============================================
  # INSTANCE METHODS
  # ============================================
  
  # Display name
  def full_name
    "#{first_name} #{last_name}".strip
  end

  def display_name
    full_name.presence || email
  end

  def initials
    "#{first_name&.first}#{last_name&.first}".upcase
  end

  # Avatar
  def avatar_path
    return avatar_url if avatar_url.present?
    return Rails.application.routes.url_helpers.rails_blob_url(avatar, only_path: true) if avatar.attached?
    nil
  end

  # Role checks
  def admin?
    role_admin?
  end

  def agent?
    role_agent?
  end

  def client?
    role_client?
  end

  def can_moderate?
    admin? || agent?
  end

  # Activity
  def touch_activity!
    update_column(:last_activity_at, Time.current)
  end

  def active?
    active && !deleted?
  end

  def deleted?
    deleted_at.present?
  end

  # Soft delete
  def soft_delete!
    update(deleted_at: Time.current, active: false)
  end

  def restore!
    update(deleted_at: nil, active: true)
  end

  # Favorites
  def favorite(property)
    favorites.find_or_create_by(property: property)
  end

  def unfavorite(property)
    favorites.where(property: property).destroy_all
  end

  def favorited?(property)
    favorite_properties.exists?(property.id)
  end

  def toggle_favorite(property)
    favorited?(property) ? unfavorite(property) : favorite(property)
  end

  # Properties
  def active_properties
    properties.active.published
  end

  def pending_properties
    properties.pending_moderation
  end

  # Inquiries
  def active_inquiries
    inquiries.active
  end

  def pending_inquiries
    inquiries.pending
  end

  # Notifications
  def unread_notifications_count
    unread_notifications.count
  end

  def mark_all_notifications_as_read!
    unread_notifications.update_all(read_at: Time.current)
  end

  # Messages
  def unread_messages_count
    received_messages.unread.count
  end

  def conversations
    Message.where('sender_id = ? OR recipient_id = ?', id, id)
           .select('DISTINCT conversation_id')
  end

  # Preferences
  def preference(key)
    preferences&.dig(key.to_s)
  end

  def set_preference(key, value)
    self.preferences ||= {}
    self.preferences[key.to_s] = value
    save
  end

  # Notification settings
  def notification_enabled?(type)
    notification_settings&.dig(type.to_s) != false
  end

  def enable_notification(type)
    self.notification_settings ||= {}
    self.notification_settings[type.to_s] = true
    save
  end

  def disable_notification(type)
    self.notification_settings ||= {}
    self.notification_settings[type.to_s] = false
    save
  end

  # Stats
  def total_views
    properties.sum(:views_count)
  end

  def total_favorites
    properties.sum(:favorites_count)
  end

  def total_inquiries
    properties.sum(:inquiries_count)
  end

  # Viewing history
  def recently_viewed_properties(limit = 10)
    viewed_properties
      .published
      .order('property_views.created_at DESC')
      .limit(limit)
  end

  def view_property(property)
    property_views.find_or_create_by(property: property) do |view|
      view.viewed_at = Time.current
    end
    property.increment_views!
  end

  # Agent specific
  def agent_properties_stats
    return {} unless agent? || admin?
    
    {
      total: properties.count,
      active: properties.active.count,
      sold: properties.sold.count,
      pending: properties.pending_moderation.count,
      total_views: total_views,
      total_inquiries: total_inquiries
    }
  end

  # Recommendations
  def recommended_properties(limit = 6)
    Property.recommended_for_user(self, limit)
  end

  # Contact information
  def formatted_phone
    return unless phone
    # Format: +7 (XXX) XXX-XX-XX
    phone.gsub(/(\d{1})(\d{3})(\d{3})(\d{2})(\d{2})/, '+\1 (\2) \3-\4-\5')
  end

  # Verification
  def verified?
    confirmed? && phone.present?
  end

  # Status
  def status_badge
    return 'deleted' if deleted?
    return 'inactive' unless active
    return 'unconfirmed' unless confirmed?
    'active'
  end

  private

  # Callbacks
  def normalize_phone
    return unless phone.present?
    # Remove all non-digit characters
    self.phone = phone.gsub(/\D/, '')
  end

  def set_default_preferences
    self.preferences ||= {
      'email_notifications' => true,
      'sms_notifications' => true,
      'push_notifications' => true,
      'newsletter' => true
    }
    
    self.notification_settings ||= {
      'new_properties' => true,
      'price_changes' => true,
      'new_messages' => true,
      'inquiry_updates' => true,
      'saved_search_results' => true
    }
  end

  def send_welcome_notification
    UserMailer.welcome_email(self).deliver_later
  end

  # Validations
  def phone_format
    return unless phone.present?
    
    unless phone.match?(/\A\d{10,11}\z/)
      errors.add(:phone, 'должен содержать 10-11 цифр')
    end
  end

  # Override Devise methods
  def active_for_authentication?
    super && active? && !deleted?
  end

  def inactive_message
    deleted? ? :deleted_account : super
  end
end