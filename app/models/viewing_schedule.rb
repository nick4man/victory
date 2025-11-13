# frozen_string_literal: true

# Viewing Schedule Model
# Manages property viewing appointments
class ViewingSchedule < ApplicationRecord
  # Associations
  belongs_to :property
  belongs_to :user, optional: true
  belongs_to :agent, class_name: 'User', optional: true
  
  # Enums
  enum status: {
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
  
  # Scopes
  scope :recent, -> { order(created_at: :desc) }
  scope :upcoming, -> { where('preferred_date >= ?', Date.current).where(status: [:pending, :confirmed]) }
  scope :past, -> { where('preferred_date < ?', Date.current) }
  scope :today, -> { where(preferred_date: Date.current) }
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
  
  def datetime
    return nil unless preferred_date && preferred_time
    
    time_parts = preferred_time.split(':')
    preferred_date.to_time + time_parts[0].to_i.hours + time_parts[1].to_i.minutes
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
    return unless preferred_date.present? && preferred_time.present? && property_id.present?
    
    # Check if time slot is available (not booked by another viewing)
    conflicting = ViewingSchedule.where(
      property_id: property_id,
      preferred_date: preferred_date,
      preferred_time: preferred_time,
      status: [:pending, :confirmed]
    ).where.not(id: id)
    
    if conflicting.exists?
      errors.add(:preferred_time, 'уже занято. Пожалуйста, выберите другое время')
    end
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
