# frozen_string_literal: true

# Send Viewing Reminders Job
# Scheduled job to send reminders for upcoming viewings
class SendViewingRemindersJob < ApplicationJob
  queue_as :scheduled
  
  # 🚨 NOT SCHEDULED: was declared only in the deleted config/schedule.rb,
  # which never executed (no `whenever` gem). Do NOT just add it to
  # config/sidekiq_cron.yml: the query below uses preferred_date and
  # reminder_email_sent, but viewing_schedules has scheduled_at and
  # reminder_sent, so it fails on the first run. Fix the query first.
  # Example: 0 * * * * SendViewingRemindersJob.perform_later
  
  def perform
    tomorrow = Date.tomorrow
    
    # Find confirmed viewings scheduled for tomorrow that haven't received reminder
    viewings = ViewingSchedule.where(
      status: 'confirmed',
      preferred_date: tomorrow,
      reminder_email_sent: false
    )
    
    Rails.logger.info "Found #{viewings.count} viewings to send reminders for"
    
    viewings.find_each do |viewing|
      ViewingNotificationJob.perform_later(viewing.id, 'reminder')
    end
    
    Rails.logger.info "Scheduled #{viewings.count} viewing reminder jobs"
  end
end

