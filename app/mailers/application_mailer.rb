# frozen_string_literal: true

# Application Mailer
# Base mailer for all email notifications
class ApplicationMailer < ActionMailer::Base
  default from: ENV.fetch('DEFAULT_FROM_EMAIL', 'noreply@viktory-realty.ru')
  layout 'mailer'
  
  # Helper method to attach company logo
  def attach_logo
    attachments.inline['logo.png'] = File.read(
      Rails.root.join('app', 'assets', 'images', 'logo.png')
    )
  rescue StandardError => e
    Rails.logger.warn "Failed to attach logo: #{e.message}"
  end
  
  # Helper method to format phone numbers
  def format_phone(phone)
    return '' unless phone.present?
    
    phone.gsub(/[^\d+]/, '')
  end
  
  # Helper method to track email opens
  def track_email(tracking_id)
    @tracking_id = tracking_id
    @tracking_url = "#{ENV.fetch('APP_URL', 'http://localhost:3000')}/email/track/#{tracking_id}"
  end
  
  private
  
  # Log all sent emails
  def log_email_sent
    Rails.logger.info "Email sent: #{message.subject} to #{message.to}"
  end
  
  after_action :log_email_sent
end

