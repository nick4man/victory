# frozen_string_literal: true

require 'active_support/core_ext/integer/time'

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # In the development environment your application's code is reloaded any time
  # it changes. This slows down response time but is perfect for development
  # since you don't have to restart the web server when you make code changes.
  config.cache_classes = false

  # Do not eager load code on boot.
  config.eager_load = false

  # Show full Rails debug page (backtrace + web-console) — обычно `true` в dev,
  # но этот контейнер обслуживает prod-трафик victory62.org с RAILS_ENV=development,
  # поэтому юзеры не должны видеть internal traces. Управляется ENV: для локальной
  # отладки выставляй SHOW_DEBUG_ERRORS=1. Иначе → branded ErrorsController.
  config.consider_all_requests_local = ENV.fetch('SHOW_DEBUG_ERRORS', '0') == '1'

  # Enable server timing
  config.server_timing = true

  # Enable/disable caching. By default caching is disabled.
  # Run rails dev:cache to toggle caching.
  if Rails.root.join('tmp/caching-dev.txt').exist?
    config.action_controller.perform_caching = true
    config.action_controller.enable_fragment_cache_logging = true

    config.cache_store = :redis_cache_store, {
      url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/0'),
      namespace: 'viktory_realty_cache',
      expires_in: 1.day
    }
    config.public_file_server.headers = {
      'Cache-Control' => "public, max-age=#{2.days.to_i}"
    }
  else
    config.action_controller.perform_caching = false
    config.cache_store = :null_store
  end

  # Store uploaded files on the local file system (see config/storage.yml for options).
  config.active_storage.service = :local

  # ActionMailer configuration
  config.action_mailer.raise_delivery_errors = true
  config.action_mailer.perform_caching = false

  # SMTP if credentials present (this deployment serves prod traffic с
  # RAILS_ENV=development — нужны real-mail capabilities). Иначе :test sink.
  if ENV['SMTP_USERNAME'].present? && ENV['SMTP_PASSWORD'].present?
    smtp_port = ENV.fetch('SMTP_PORT', 465).to_i
    ssl_mode  = ENV.fetch('SMTP_SSL', (smtp_port == 465 ? '1' : '0'))
    use_ssl   = %w[1 true yes].include?(ssl_mode.to_s.downcase)

    config.action_mailer.delivery_method = :smtp
    config.action_mailer.perform_deliveries = true
    config.action_mailer.smtp_settings = {
      address:              ENV.fetch('SMTP_ADDRESS', 'smtp.mail.ru'),
      port:                 smtp_port,
      domain:               ENV.fetch('SMTP_DOMAIN', ENV.fetch('APP_DOMAIN', 'victory62.org')),
      user_name:            ENV['SMTP_USERNAME'],
      password:             ENV['SMTP_PASSWORD'],
      authentication:       ENV.fetch('SMTP_AUTHENTICATION', 'login').to_sym,
      enable_starttls_auto: !use_ssl,
      ssl:                  use_ssl,
      tls:                  use_ssl,
      open_timeout:         10,
      read_timeout:         10
    }.compact

    # Production-style URL options (HTTPS на victory62.org).
    config.action_mailer.default_url_options = {
      host:     ENV.fetch('APP_DOMAIN', 'victory62.org'),
      protocol: 'https'
    }
    config.action_mailer.asset_host = ENV.fetch('APP_URL', "https://#{ENV.fetch('APP_DOMAIN', 'victory62.org')}")
  else
    # No SMTP credentials — fall back to test sink.
    config.action_mailer.delivery_method = :test
    config.action_mailer.perform_deliveries = false

    config.action_mailer.default_url_options = {
      host: ENV.fetch('APP_HOST', 'localhost'),
      port: ENV.fetch('PORT', 5000)
    }
    config.action_mailer.asset_host = "http://#{ENV.fetch('APP_HOST', 'localhost')}:#{ENV.fetch('PORT', 5000)}"
  end

  # Print deprecation notices to the Rails logger.
  config.active_support.deprecation = :log

  # Raise exceptions for disallowed deprecations.
  config.active_support.disallowed_deprecation = :raise

  # Tell Active Support which deprecation messages to disallow.
  config.active_support.disallowed_deprecation_warnings = []

  # Raise an error on page load if there are pending migrations.
  config.active_record.migration_error = :page_load

  # Highlight code that triggered database queries in logs.
  config.active_record.verbose_query_logs = true

  # Suppress logger output for asset requests.
  config.assets.quiet = true

  # Raises error for missing translations.
  # config.i18n.raise_on_missing_translations = true

  # Annotate rendered view with file names.
  # config.action_view.annotate_rendered_view_with_filenames = true

  # Allow all hosts for Replit proxy compatibility
  config.hosts.clear

  # Uncomment if you wish to allow Action Cable access from any origin.
  config.action_cable.disable_request_forgery_protection = true

  # ActionCable: prefer ACTION_CABLE_URL from .env (e.g. wss://victory62.org/cable
  # behind Traefik). Fallback to relative '/cable' so the JS client uses the
  # current host scheme.
  config.action_cable.url = ENV.fetch('ACTION_CABLE_URL', '/cable')
  config.action_cable.allowed_request_origins = nil

  # Trust the WireGuard subnet so request.scheme returns 'https' when Traefik
  # forwards via X-Forwarded-Proto. Affects og:image / Active Storage URLs.
  require 'ipaddr'
  config.action_dispatch.trusted_proxies = [
    IPAddr.new('10.10.0.0/24'),
    IPAddr.new('172.16.0.0/12'),  # Docker bridge
    IPAddr.new('127.0.0.1/8')
  ]
end

