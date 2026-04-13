# frozen_string_literal: true

# Application Mailer
# Base mailer for all email notifications
class ApplicationMailer < ActionMailer::Base
  default from: ENV.fetch('DEFAULT_FROM_EMAIL', 'noreply@viktory-realty.ru')
  layout 'mailer'

  after_action :log_email_sent

  private

  # Attach company logo as inline image
  def attach_logo
    attachments.inline['logo.png'] = File.read(
      Rails.root.join('app', 'assets', 'images', 'logo.png')
    )
  rescue StandardError => e
    Rails.logger.warn "Failed to attach logo: #{e.message}"
  end

  # Normalize phone to digits-only
  def format_phone(phone)
    return '' unless phone.present?

    phone.gsub(/[^\d+]/, '')
  end

  # Store tracking ID for email open pixel
  def track_email(tracking_id)
    @tracking_id  = tracking_id
    @tracking_url = "#{ENV.fetch('APP_URL', 'http://localhost:5000')}/email/track/#{tracking_id}"
  end

  # Log all sent emails
  def log_email_sent
    Rails.logger.info "Email sent: #{message.subject} to #{message.to}"
  end
end
