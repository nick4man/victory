# frozen_string_literal: true

# User Mailer
# Sends transactional emails related to user accounts
class UserMailer < ApplicationMailer
  # Send welcome email after registration
  # @param user [User]
  def welcome_email(user)
    @user = user
    @dashboard_url = "#{ENV.fetch('APP_URL', 'http://localhost:5000')}/dashboard"
    @properties_url = "#{ENV.fetch('APP_URL', 'http://localhost:5000')}/properties"
    # Contacts из AgencyInfo (canonical, как на сайте). До 22.05.26 здесь
    # были ENV-fallback'и с моками `+7 (999) 123-45-67` / `info@viktory-realty.ru`
    # которые утекали в production-emails если ENV не set.
    @contact_phone = AgencyInfo::PHONE_PRIMARY
    @contact_email = AgencyInfo::EMAIL

    attach_logo
    track_email("welcome_#{user.id}")

    mail(
      to: user.email,
      subject: 'Добро пожаловать в АН "Виктори"!'
    )
  end
end
