# frozen_string_literal: true

require_relative 'boot'

require 'rails/all'

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module ViktoryRealty
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 7.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.

    # Set timezone
    config.time_zone = 'Moscow'
    config.active_record.default_timezone = :local

    # Localization
    config.i18n.load_path += Dir[Rails.root.join('config', 'locales', '**', '*.{rb,yml}')]
    config.i18n.default_locale = :ru
    config.i18n.available_locales = [:ru, :en]
    config.i18n.fallbacks = [:en]

    # Eager load paths
    # config.eager_load_paths << Rails.root.join("extras")

    # Custom directories with classes and modules
    config.autoload_paths << Rails.root.join('app', 'services')
    config.autoload_paths << Rails.root.join('app', 'forms')
    config.autoload_paths << Rails.root.join('app', 'presenters')
    config.autoload_paths << Rails.root.join('app', 'decorators')

    # Active Job queue adapter
    config.active_job.queue_adapter = :sidekiq

    # Active Storage
    config.active_storage.service = :local

    # Action Cable
    config.action_cable.mount_path = '/cable'
    config.action_cable.url = ENV.fetch('ACTION_CABLE_URL', 'ws://localhost:3000/cable')

    # CORS configuration (for API)
    config.middleware.insert_before 0, Rack::Cors do
      allow do
        origins ENV.fetch('CORS_ORIGINS', '*').split(',')
        resource '/api/*',
                 headers: :any,
                 methods: [:get, :post, :put, :patch, :delete, :options, :head],
                 credentials: false,
                 max_age: 600
      end
    end

    # Rate limiting
    config.middleware.use Rack::Attack

    # Session store
    config.session_store :cookie_store,
                         key: '_viktory_realty_session',
                         expire_after: ENV.fetch('SESSION_TIMEOUT', 1800).to_i,
                         secure: Rails.env.production?,
                         httponly: true,
                         same_site: :lax

    # Cookies
    config.action_dispatch.cookies_same_site_protection = :lax

    # Active Record encryption (Rails 7+)
    # Uncomment if you need encryption for sensitive data
    # config.active_record.encryption.primary_key = ENV['ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY']
    # config.active_record.encryption.deterministic_key = ENV['ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY']
    # config.active_record.encryption.key_derivation_salt = ENV['ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT']

    # Action Mailer
    config.action_mailer.default_url_options = {
      host: ENV.fetch('APP_HOST', 'localhost'),
      protocol: ENV.fetch('APP_PROTOCOL', 'http')
    }

    # Generators configuration
    config.generators do |g|
      g.orm :active_record, primary_key_type: :uuid
      g.test_framework :rspec,
                       fixtures: false,
                       view_specs: false,
                       helper_specs: false,
                       routing_specs: false
      g.fixture_replacement :factory_bot, dir: 'spec/factories'
      g.stylesheets false
      g.javascripts false
      g.helper false
    end

    # Exception handling
    # Временно отключено до создания ErrorsController
    # unless Rails.env.development? || Rails.env.test?
    #   config.exceptions_app = ->(env) { ErrorsController.action(:show).call(env) }
    # end

    # Active Record configuration
    config.active_record.schema_format = :sql
    config.active_record.dump_schema_after_migration = false if Rails.env.production?

    # Logging
    if ENV['RAILS_LOG_TO_STDOUT'].present?
      logger           = ActiveSupport::Logger.new($stdout)
      logger.formatter = config.log_formatter
      config.logger    = ActiveSupport::TaggedLogging.new(logger)
    end

    # Log level
    config.log_level = ENV.fetch('LOG_LEVEL', Rails.env.production? ? 'info' : 'debug').to_sym

    # Disable IP spoofing check if behind proxy
    config.action_dispatch.ip_spoofing_check = true

    # Content Security Policy
    config.content_security_policy do |policy|
      policy.default_src :self, :https
      policy.font_src    :self, :https, :data
      policy.img_src     :self, :https, :data, :blob
      policy.object_src  :none
      policy.script_src  :self, :https, :unsafe_inline, :unsafe_eval
      policy.style_src   :self, :https, :unsafe_inline
      policy.connect_src :self, :https, 'ws:', 'wss:'
      
      # Specify URI for violation reports
      # policy.report_uri '/csp-violation-report-endpoint'
    end

    # Feature Policy / Permissions Policy
    config.permissions_policy do |policy|
      policy.camera      :none
      policy.gyroscope   :none
      policy.microphone  :none
      policy.usb         :none
      policy.payment     :self
      policy.geolocation :self
    end

    # Asset host (CDN)
    if ENV['ASSET_HOST'].present?
      config.asset_host = ENV['ASSET_HOST']
    end

    # Precompile additional assets
    config.assets.paths << Rails.root.join('app', 'assets', 'fonts')
    config.assets.precompile += %w[*.png *.jpg *.jpeg *.gif *.svg]

    # Pagination defaults
    Kaminari.configure do |config|
      config.default_per_page = 20
      config.max_per_page = 100
    end

    # Devise configuration
    config.to_prepare do
      Devise::SessionsController.layout 'devise'
      Devise::RegistrationsController.layout proc { |controller| user_signed_in? ? 'application' : 'devise' }
      Devise::ConfirmationsController.layout 'devise'
      Devise::UnlocksController.layout 'devise'
      Devise::PasswordsController.layout 'devise'
    end
  end
end

