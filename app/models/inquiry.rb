# frozen_string_literal: true

# == Schema Information
#
# Table name: inquiries
#
#  id                     :bigint           not null, primary key
#  user_id                :bigint
#  property_id            :bigint
#  agent_id               :bigint
#  inquiry_type           :integer          default("viewing"), not null
#  status                 :integer          default("new"), not null
#  name                   :string           not null
#  phone                  :string           not null
#  email                  :string
#  message                :text
#  comment                :text
#  preferred_date         :datetime
#  preferred_time         :string
#  scheduled_at           :datetime
#  completed_at           :datetime
#  metadata               :jsonb
#  source                 :string
#  utm_source             :string
#  utm_medium             :string
#  utm_campaign           :string
#  referrer_url           :string
#  ip_address             :string
#  user_agent             :string
#  processed_at           :datetime
#  cancelled_at           :datetime
#  cancellation_reason    :string
#  crm_id                 :string
#  synced_to_crm_at       :datetime
#  priority               :integer          default(0)
#  notifications_sent     :boolean          default(false)
#  last_notification_at   :datetime
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#

class Inquiry < ApplicationRecord
  include AASM

  # ============================================
  # ASSOCIATIONS
  # ============================================
  belongs_to :user, optional: true, counter_cache: true
  belongs_to :property, optional: true, counter_cache: true
  belongs_to :agent, class_name: 'User', optional: true

  has_many :messages, dependent: :nullify
  has_many :activities, as: :trackable, dependent: :destroy

  # ============================================
  # ENUMS
  # ============================================
  enum inquiry_type: {
    viewing: 0,           # Запрос на просмотр
    consultation: 1,      # Консультация
    mortgage: 2,          # Ипотека
    evaluation: 3,        # Оценка недвижимости
    callback: 4,          # Обратный звонок
    quick_inquiry: 5,     # Быстрая заявка
    contact_agent: 6      # Связаться с агентом
  }, _prefix: true

  enum status: {
    new: 0,              # Новая
    contacted: 1,        # Связались
    in_progress: 2,      # В работе
    scheduled: 3,        # Запланирована
    completed: 4,        # Завершена
    cancelled: 5,        # Отменена
    spam: 6              # Спам
  }, _prefix: true

  enum priority: {
    normal: 0,
    high: 1,
    urgent: 2
  }, _prefix: true

  # ============================================
  # VALIDATIONS
  # ============================================
  validates :name, presence: true, length: { minimum: 2, maximum: 100 }
  validates :phone, presence: true
  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
  validates :inquiry_type, presence: true
  validates :status, presence: true
  validates :message, length: { maximum: 2000 }, allow_blank: true

  validate :phone_format
  validate :preferred_date_in_future, if: :preferred_date?
  validate :property_or_message_required

  # ============================================
  # CALLBACKS
  # ============================================
  before_validation :normalize_phone
  before_validation :set_default_source, on: :create
  after_create :assign_to_agent
  after_create :send_notifications
  after_create :sync_to_crm
  after_update :notify_status_change, if: :saved_change_to_status?

  # ============================================
  # SCOPES
  # ============================================
  scope :recent, -> { order(created_at: :desc) }
  scope :active, -> { where(status: [:new, :contacted, :in_progress, :scheduled]) }
  scope :pending, -> { where(status: :new) }
  scope :archived, -> { where(status: [:completed, :cancelled]) }
  scope :by_type, ->(type) { where(inquiry_type: type) if type.present? }
  scope :by_status, ->(status) { where(status: status) if status.present? }
  scope :for_property, ->(property_id) { where(property_id: property_id) if property_id.present? }
  scope :for_user, ->(user_id) { where(user_id: user_id) if user_id.present? }
  scope :unassigned, -> { where(agent_id: nil) }
  scope :today, -> { where('created_at >= ?', Time.current.beginning_of_day) }
  scope :this_week, -> { where('created_at >= ?', Time.current.beginning_of_week) }
  scope :this_month, -> { where('created_at >= ?', Time.current.beginning_of_month) }
  scope :high_priority, -> { where(priority: [:high, :urgent]) }
  scope :needs_sync, -> { where(crm_id: nil).where.not(status: :spam) }

  # ============================================
  # STATE MACHINE (AASM)
  # ============================================
  aasm column: :status, enum: true do
    state :new, initial: true
    state :contacted
    state :in_progress
    state :scheduled
    state :completed
    state :cancelled
    state :spam

    event :contact do
      transitions from: :new, to: :contacted
      after do
        update(processed_at: Time.current)
      end
    end

    event :start_processing do
      transitions from: [:new, :contacted], to: :in_progress
      after do
        update(processed_at: Time.current)
      end
    end

    event :schedule do
      transitions from: [:new, :contacted, :in_progress], to: :scheduled
      after do
        update(processed_at: Time.current)
      end
    end

    event :complete do
      transitions from: [:contacted, :in_progress, :scheduled], to: :completed
      after do
        update(completed_at: Time.current)
      end
    end

    event :cancel do
      transitions from: [:new, :contacted, :in_progress, :scheduled], to: :cancelled
      after do
        update(cancelled_at: Time.current)
      end
    end

    event :mark_as_spam do
      transitions from: :new, to: :spam
    end
  end

  # ============================================
  # CLASS METHODS
  # ============================================
  def self.ransackable_attributes(auth_object = nil)
    %w[name email phone status inquiry_type created_at property_id user_id agent_id]
  end

  def self.ransackable_associations(auth_object = nil)
    %w[user property agent]
  end

  def self.statistics(period = :all)
    scope = period == :all ? all : send(period)
    
    {
      total: scope.count,
      by_type: scope.group(:inquiry_type).count,
      by_status: scope.group(:status).count,
      conversion_rate: calculate_conversion_rate(scope),
      avg_response_time: calculate_avg_response_time(scope)
    }
  end

  def self.calculate_conversion_rate(scope = all)
    total = scope.count
    return 0 if total.zero?
    
    completed = scope.completed.count
    (completed.to_f / total * 100).round(2)
  end

  def self.calculate_avg_response_time(scope = all)
    times = scope.where.not(processed_at: nil)
                 .pluck(:created_at, :processed_at)
                 .map { |created, processed| (processed - created).to_i }
    
    return 0 if times.empty?
    (times.sum / times.size / 60.0).round(2) # в минутах
  end

  # ============================================
  # INSTANCE METHODS
  # ============================================

  # Display helpers
  def full_contact_info
    parts = [name]
    parts << email if email.present?
    parts << formatted_phone
    parts.join(' | ')
  end

  def formatted_phone
    return phone unless phone.present?
    # Format: +7 (XXX) XXX-XX-XX
    phone.gsub(/(\d{1})(\d{3})(\d{3})(\d{2})(\d{2})/, '+\1 (\2) \3-\4-\5')
  end

  def type_label
    I18n.t("activerecord.attributes.inquiry.inquiry_types.#{inquiry_type}")
  end

  def status_label
    I18n.t("activerecord.attributes.inquiry.statuses.#{status}")
  end

  def status_badge_class
    {
      'new' => 'badge-primary',
      'contacted' => 'badge-info',
      'in_progress' => 'badge-warning',
      'scheduled' => 'badge-success',
      'completed' => 'badge-success',
      'cancelled' => 'badge-secondary',
      'spam' => 'badge-danger'
    }[status] || 'badge-secondary'
  end

  def priority_badge_class
    {
      'normal' => 'badge-secondary',
      'high' => 'badge-warning',
      'urgent' => 'badge-danger'
    }[priority] || 'badge-secondary'
  end

  # Timing
  def response_time_minutes
    return nil unless processed_at
    ((processed_at - created_at) / 60).round(2)
  end

  def overdue?
    return false if status_completed? || status_cancelled?
    created_at < 24.hours.ago && status_new?
  end

  def scheduled_soon?
    return false unless scheduled_at
    scheduled_at.between?(Time.current, 24.hours.from_now)
  end

  # Agent assignment
  def assign_to!(agent_user)
    return false unless agent_user.agent? || agent_user.admin?
    update(agent: agent_user)
  end

  def unassign!
    update(agent: nil)
  end

  # Processing
  def mark_processed!
    update(processed_at: Time.current) unless processed_at
  end

  def cancel_with_reason!(reason)
    update(cancellation_reason: reason)
    cancel!
  end

  # CRM sync
  def sync_to_crm!
    return if crm_id.present?
    
    # AmoCrmSyncJob.perform_later(id)
    # Placeholder for CRM sync logic
  end

  def synced_to_crm?
    crm_id.present? && synced_to_crm_at.present?
  end

  # Metadata helpers
  def set_metadata(key, value)
    self.metadata ||= {}
    self.metadata[key.to_s] = value
    save
  end

  def get_metadata(key)
    metadata&.dig(key.to_s)
  end

  # Source tracking
  def from_mobile?
    source == 'mobile' || user_agent&.match?(/Mobile|Android|iPhone/i)
  end

  def has_utm_params?
    utm_source.present? || utm_medium.present? || utm_campaign.present?
  end

  def utm_string
    return unless has_utm_params?
    
    params = []
    params << "utm_source=#{utm_source}" if utm_source.present?
    params << "utm_medium=#{utm_medium}" if utm_medium.present?
    params << "utm_campaign=#{utm_campaign}" if utm_campaign.present?
    params.join('&')
  end

  # Notifications
  def notify_admins!
    return if notifications_sent?
    
    # AdminNotificationJob.perform_later(id)
    update(notifications_sent: true, last_notification_at: Time.current)
  end

  def notify_user_of_status_change!
    return unless user
    
    # UserNotificationJob.perform_later(id, 'status_changed')
  end

  # Property related
  def property_title
    property&.title || 'Общая заявка'
  end

  def property_url
    return unless property
    Rails.application.routes.url_helpers.property_url(property)
  end

  # Agent related
  def agent_name
    agent&.full_name || 'Не назначен'
  end

  # Timeline
  def timeline_events
    events = []
    
    events << { 
      time: created_at, 
      event: 'created', 
      description: 'Заявка создана' 
    }
    
    if processed_at
      events << { 
        time: processed_at, 
        event: 'processed', 
        description: 'Заявка обработана' 
      }
    end
    
    if scheduled_at
      events << { 
        time: scheduled_at, 
        event: 'scheduled', 
        description: 'Назначена встреча' 
      }
    end
    
    if completed_at
      events << { 
        time: completed_at, 
        event: 'completed', 
        description: 'Заявка завершена' 
      }
    end
    
    if cancelled_at
      events << { 
        time: cancelled_at, 
        event: 'cancelled', 
        description: "Заявка отменена#{cancellation_reason.present? ? ": #{cancellation_reason}" : ''}" 
      }
    end
    
    events.sort_by { |e| e[:time] }
  end

  private

  # Callbacks
  def normalize_phone
    return unless phone.present?
    self.phone = phone.gsub(/\D/, '')
  end

  def set_default_source
    self.source ||= 'web'
  end

  def assign_to_agent
    return if agent.present?
    
    # Simple round-robin assignment to available agents
    available_agents = User.agents.active.order('RANDOM()').limit(1)
    self.agent = available_agents.first if available_agents.any?
  end

  def send_notifications
    notify_admins!
    InquiryNotificationJob.perform_later(id) if defined?(InquiryNotificationJob)
  end

  def sync_to_crm
    sync_to_crm! if ENV['AMOCRM_ENABLED'] == 'true'
  end

  def notify_status_change
    notify_user_of_status_change! if user.present?
  end

  # Validations
  def phone_format
    return unless phone.present?
    
    cleaned = phone.gsub(/\D/, '')
    unless cleaned.match?(/\A\d{10,11}\z/)
      errors.add(:phone, 'должен содержать 10-11 цифр')
    end
  end

  def preferred_date_in_future
    if preferred_date < Time.current
      errors.add(:preferred_date, 'должна быть в будущем')
    end
  end

  def property_or_message_required
    if property_id.blank? && message.blank?
      errors.add(:base, 'Необходимо указать объект недвижимости или сообщение')
    end
  end
end