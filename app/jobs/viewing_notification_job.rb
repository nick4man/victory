# frozen_string_literal: true

# Viewing Notification Job
# Sends email notifications for viewing schedules
class ViewingNotificationJob < ApplicationJob
  queue_as :mailers
  
  def perform(viewing_id, notification_type)
    viewing = ViewingSchedule.find(viewing_id)
    
    case notification_type.to_s
    when 'requested'
      send_viewing_requested(viewing)
    when 'confirmed'
      send_viewing_confirmed(viewing)
    when 'cancelled'
      send_viewing_cancelled(viewing)
    when 'reminder'
      send_viewing_reminder(viewing)
    when 'completed'
      send_viewing_completed(viewing)
    else
      Rails.logger.warn "Unknown notification type: #{notification_type}"
    end
    
    Rails.logger.info "Viewing #{notification_type} notification sent for viewing ##{viewing_id}"
  rescue ActiveRecord::RecordNotFound => e
    Rails.logger.warn "Viewing ##{viewing_id} not found: #{e.message}"
  end
  
  private
  
  def send_viewing_requested(viewing)
    ViewingMailer.viewing_requested(viewing).deliver_now
    ViewingMailer.viewing_confirmation(viewing).deliver_now
    viewing.update(confirmation_email_sent: true, confirmation_email_sent_at: Time.current)
  end
  
  def send_viewing_confirmed(viewing)
    ViewingMailer.viewing_confirmed(viewing).deliver_now
    viewing.update(confirmed_email_sent: true, confirmed_email_sent_at: Time.current)
  end
  
  def send_viewing_cancelled(viewing)
    ViewingMailer.viewing_cancelled(viewing).deliver_now
    viewing.update(cancellation_email_sent: true, cancellation_email_sent_at: Time.current)
  end
  
  def send_viewing_reminder(viewing)
    ViewingMailer.viewing_reminder(viewing).deliver_now
    viewing.update(reminder_email_sent: true, reminder_email_sent_at: Time.current)
  end
  
  def send_viewing_completed(viewing)
    ViewingMailer.viewing_completed(viewing).deliver_now
  end
end

