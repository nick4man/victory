# frozen_string_literal: true

# Application Mailer
# Base mailer for all email notifications
class ApplicationMailer < ActionMailer::Base
  # MAIL_FROM accepts "Name <addr@example.com>" формат; DEFAULT_FROM_EMAIL
  # — legacy var, fallback. Mail.ru SMTP требует, чтобы From-адрес совпадал
  # с SMTP_USERNAME (или входил в alias-список).
  #
  # 22.05.26 — fallback теперь включает читабельное имя
  # `АН «Виктори» <noreply@victory62.org>` (раньше был голый адрес,
  # выглядел технически в inbox получателя). reply_to → AgencyInfo::EMAIL
  # (oks07@yandex.ru) чтобы клиент при ответе писал в реальную почту.
  default from: ENV.fetch('MAIL_FROM',
                          ENV.fetch('DEFAULT_FROM_EMAIL',
                                    "#{AgencyInfo::NAME} <noreply@victory62.org>"))
  default reply_to: AgencyInfo::EMAIL
  layout 'mailer'
  
  # #435/#436 — gate delivery по user notification preferences.
  # Вызывается ПОСЛЕ `mail(...)` в client-facing mailer methods. Если user
  # opted-out (или не can'нет получать в этом channel) — sets
  # `mail_obj.perform_deliveries = false`, что отменяет SMTP send и в
  # deliver_now, и в deliver_later.
  #
  # Pattern в mailer:
  #   def some_email(user, ...)
  #     msg = mail(to: user.email, subject: '...')
  #     gate_notify!(msg, user, category: 'inquiry_status')
  #     msg
  #   end
  #
  # Auth-mailers (magic_link, password_reset, email_change_confirmation,
  # phone_change) НЕ должны вызывать этот helper — они critical security,
  # не подлежат opt-out.
  def gate_notify!(mail_obj, user, category:, channel: 'email')
    return if user&.notify?(category: category, channel: channel)
    mail_obj.perform_deliveries = false
    Rails.logger.info(
      "[#{self.class.name}##{action_name}] skipped: " \
      "user=#{user&.id} prefs off для #{category}:#{channel}"
    )
  end

  # Legacy alias — keep until all mailers migrated. Now redirects to
  # gate_notify! если message доступен через self.message.
  def skip_unless_notify!(user, category:, channel: 'email')
    gate_notify!(message, user, category: category, channel: channel)
  end

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

