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
  
  # ViewingSchedule schema больше не tracks per-type email_sent flags
  # (confirmation/confirmed/cancellation/reminder_email_sent columns
  # удалены). State transitions (confirmed_at, cancelled_at) пишутся
  # при actual state change в ViewingsController, не в notification job.
  # Reminder остался — schema имеет reminder_sent + reminder_sent_at.

  def send_viewing_requested(viewing)
    ViewingMailer.viewing_requested(viewing).deliver_now
    ViewingMailer.viewing_confirmation(viewing).deliver_now
  end

  def send_viewing_confirmed(viewing)
    ViewingMailer.viewing_confirmed(viewing).deliver_now
  end

  def send_viewing_cancelled(viewing)
    ViewingMailer.viewing_cancelled(viewing).deliver_now
  end

  def send_viewing_reminder(viewing)
    ViewingMailer.viewing_reminder(viewing).deliver_now
    viewing.update(reminder_sent: true, reminder_sent_at: Time.current)
  end
  
  def send_viewing_completed(viewing)
    ViewingMailer.viewing_completed(viewing).deliver_now
  end
end

