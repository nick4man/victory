# frozen_string_literal: true

# User Mailer
# Sends transactional emails related to user accounts
class UserMailer < ApplicationMailer
  # Send weekly digest of new properties to subscribed users
  # @param user [User]
  def weekly_digest(user)
    @user = user
    @new_properties = Property.published.order(created_at: :desc).limit(6)
    @properties_url = "#{ENV.fetch('APP_URL', 'http://localhost:5000')}/properties"
    @dashboard_url  = "#{ENV.fetch('APP_URL', 'http://localhost:5000')}/dashboard"

    attach_logo
    track_email("digest_#{user.id}_#{Date.current.cweek}")

    mail(
      to:      user.email,
      subject: 'АН "Виктори" — еженедельный дайджест недвижимости'
    )
  end

  # Send welcome email after registration
  # @param user [User]
  def welcome_email(user)
    @user = user
    @dashboard_url = "#{ENV.fetch('APP_URL', 'http://localhost:5000')}/dashboard"
    @properties_url = "#{ENV.fetch('APP_URL', 'http://localhost:5000')}/properties"
    @contact_phone = ENV.fetch('CONTACT_PHONE', '+7 (999) 123-45-67')
    @contact_email = ENV.fetch('CONTACT_EMAIL', 'info@viktory-realty.ru')

    attach_logo
    track_email("welcome_#{user.id}")

    mail(
      to: user.email,
      subject: 'Добро пожаловать в АН "Виктори"!'
    )
  end
end
