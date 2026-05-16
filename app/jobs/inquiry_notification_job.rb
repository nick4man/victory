# frozen_string_literal: true

# Inquiry Notification Job
# Sends email notifications for new inquiries
class InquiryNotificationJob < ApplicationJob
  queue_as :mailers
  
  def perform(inquiry_id)
    inquiry = Inquiry.find(inquiry_id)
    
    # Send confirmation to client
    InquiryMailer.inquiry_confirmation(inquiry).deliver_now
    
    # Send notification to managers
    InquiryMailer.new_inquiry_notification(inquiry).deliver_now
    
    # For callback requests, send urgent notification
    if inquiry.inquiry_type == 'callback'
      InquiryMailer.callback_requested(inquiry).deliver_now
    end
    
    # Update inquiry — mark notifications as sent + timestamp.
    # Reason: previous schema had confirmation_email_sent boolean +
    # confirmation_email_sent_at datetime, обе columns удалены при
    # consolidation; current schema использует notifications_sent (boolean,
    # «было ли отправлено») + last_notification_at для observability.
    # Retries безопасны — boolean set'ится idempotently.
    inquiry.update(notifications_sent: true, last_notification_at: Time.current)
    
    Rails.logger.info "Inquiry notifications sent for inquiry ##{inquiry_id}"
  rescue ActiveRecord::RecordNotFound => e
    Rails.logger.warn "Inquiry ##{inquiry_id} not found: #{e.message}"
  end
end

