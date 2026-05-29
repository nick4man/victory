# frozen_string_literal: true

# Use this hook to configure devise mailer, warden hooks and so forth.
# Many of these configuration options can be set straight in your model.
Devise.setup do |config|
  # ==> Mailer Configuration
  config.mailer_sender = ENV.fetch('DEFAULT_FROM_EMAIL', 'noreply@viktory-realty.ru')

  # ==> ORM configuration
  require 'devise/orm/active_record'

  # ==> Configuration for any authentication mechanism
  config.case_insensitive_keys = [:email]
  config.strip_whitespace_keys = [:email]
  config.skip_session_storage  = [:http_auth]

  # ==> Configuration for :database_authenticatable
  config.stretches = Rails.env.test? ? 1 : 12
  config.pepper = ENV.fetch('DEVISE_PEPPER', SecureRandom.hex(64))

  # ==> Configuration for :validatable
  config.password_length = 6..128
  config.email_regexp    = /\A[^@\s]+@[^@\s]+\z/

  # ==> Configuration for :timeoutable
  # config.timeout_in = 30.minutes

  # ==> Configuration for :lockable
  config.lock_strategy     = :failed_attempts
  config.unlock_keys       = [:email]
  config.unlock_strategy   = :both
  config.maximum_attempts  = 10
  config.unlock_in         = 1.hour
  config.last_attempt_warning = true

  # ==> Configuration for :recoverable
  config.reset_password_keys   = [:email]
  config.reset_password_within = 6.hours

  # ==> Configuration for :rememberable
  config.remember_for = 2.weeks
  config.expire_all_remember_me_on_sign_out = true

  # ==> Configuration for :confirmable
  # Auto-confirm users in development; in production they must confirm via email.
  config.allow_unconfirmed_access_for = 14.days
  config.reconfirmable                = true
  config.confirmation_keys            = [:email]

  # ==> Scopes configuration
  config.scoped_views = false

  # ==> Navigation configuration
  config.sign_out_via = :delete

  # ==> OmniAuth — disabled (Google/Yandex OAuth UI was removed)
  # config.omniauth :google_oauth2, ENV['GOOGLE_CLIENT_ID'], ENV['GOOGLE_CLIENT_SECRET']
end
