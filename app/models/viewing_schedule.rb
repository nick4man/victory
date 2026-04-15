# frozen_string_literal: true

# Viewing Schedule Model
# Manages property viewing appointments
class ViewingSchedule < ApplicationRecord
  # Associations
  belongs_to :property
  belongs_to :user, optional: true
  belongs_to :agent, class_name: 'User', optional: true
  
  # Enums
  # NOTE: 'scheduled' is the DB default but treated as 'pending' semantically
  enum status: {
    scheduled: 'scheduled',
    pending: 'pending',
    confirmed: 'confirmed',
    completed: 'completed',
    cancelled: 'cancelled',
    no_show: 'no_show'
  }
  
  # Validations
  validates :name, presence: true
  validates :phone, presence: true, format: { with: /\A\+?[0-9\s\-\(\)]+\z/ }
  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP }, allow_blank: true
  validates :preferred_date, presence: true
  validates :preferred_time, presence: true
  validates :status, presence: true
  
  validate :date_not_in_past
  validate :time_slot_available
  
  # Callbacks
  before_validation :normalize_phone
  after_create :send_notifications
  after_update :handle_status_change, if: :saved_change_to_status?
  
  # Scopes — use the actual DB column scheduled_at (not virtual preferred_date)
  scope :recent, -> { order(created_at: :desc) }
  scope :upcoming, -> { where('scheduled_at >= ?', Date.current).where(status: [:pending, :confirmed, :scheduled]) }
  scope :past, -> { where('scheduled_at < ?', Date.current) }
  scope :today, -> { where(scheduled_at: Date.current.all_day) }
  scope :for_property, ->(property_id) { where(property_id: property_id) }
  scope :for_user, ->(user_id) { where(user_id: user_id) }
  
  # Instance Methods
  
  def confirm!
    update(status: 'confirmed', confirmed_at: Time.current)
  end
  
  def cancel!(reason = nil)
    update(
      status: 'cancelled',
      cancelled_at: Time.current,
      cancellation_reason: reason
    )
  end
  
  def complete!
    update(status: 'completed', completed_at: Time.current)
  end
  
  def mark_no_show!
    update(status: 'no_show')
  end
  
  # Virtual accessors: the DB stores a single scheduled_at datetime,
  # but the model exposes preferred_date (Date) and preferred_time (HH:MM string)
  # for the booking form and mailer templates.
  def preferred_date
    scheduled_at&.to_date
  end

  def preferred_date=(value)
    return if value.blank?

    time_part = preferred_time || '10:00'
    self.scheduled_at = Time.zone.parse("#{value} #{time_part}")
  end

  def preferred_time
    scheduled_at&.strftime('%H:%M')
  end

  def preferred_time=(value)
    return if value.blank?

    date_part = preferred_date || Date.tomorrow
    self.scheduled_at = Time.zone.parse("#{date_part} #{value}")
  end

  def duration_minutes
    duration
  end

  def datetime
    scheduled_at
  end
  
  def datetime_formatted
    return '' unless datetime
    
    I18n.l(datetime, format: :long)
  end
  
  def upcoming?
    preferred_date >= Date.current && %w[pending confirmed].include?(status)
  end
  
  def can_cancel?
    %w[pending confirmed].include?(status) && preferred_date >= Date.current
  end
  
  def can_confirm?
    status == 'pending' && preferred_date >= Date.current
  end
  
  private
  
  def normalize_phone
    return unless phone.present?
    
    self.phone = phone.gsub(/[^\d+]/, '')
  end
  
  def date_not_in_past
    return unless preferred_date.present?
    
    if preferred_date < Date.current
      errors.add(:preferred_date, 'не может быть в прошлом')
    end
  end
  
  def time_slot_available
    return unless scheduled_at.present? && property_id.present?

    # Check if a viewing is already booked within ±30 minutes of the same slot
    window = 30.minutes
    conflicting = ViewingSchedule
                  .where(property_id: property_id, status: [:scheduled, :pending, :confirmed])
                  .where(scheduled_at: (scheduled_at - window)..(scheduled_at + window))
                  .where.not(id: id)

    errors.add(:preferred_time, 'уже занято. Пожалуйста, выберите другое время') if conflicting.exists?
  end
  
  def send_notifications
    ViewingMailer.viewing_requested(self).deliver_later
    ViewingMailer.viewing_confirmation(self).deliver_later if email.present?
  end
  
  def handle_status_change
    case status
    when 'confirmed'
      ViewingMailer.viewing_confirmed(self).deliver_later if email.present?
    when 'cancelled'
      ViewingMailer.viewing_cancelled(self).deliver_later if email.present?
    when 'completed'
      ViewingMailer.viewing_completed(self).deliver_later if email.present?
    end
  end
end
