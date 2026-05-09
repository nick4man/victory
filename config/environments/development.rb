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

  # Show full error reports.
  config.consider_all_requests_local = true

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
  
  # No SMTP / letter_opener in this dev setup — use :test sink (does not raise).
  config.action_mailer.delivery_method = :test
  config.action_mailer.perform_deliveries = false
  
  # Set default URL options
  config.action_mailer.default_url_options = {
    host: ENV.fetch('APP_HOST', 'localhost'),
    port: ENV.fetch('PORT', 5000)
  }
  
  # Asset host for email images
  config.action_mailer.asset_host = "http://#{ENV.fetch('APP_HOST', 'localhost')}:#{ENV.fetch('PORT', 5000)}"

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

