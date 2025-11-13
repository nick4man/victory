# frozen_string_literal: true

# Sidekiq configuration

Sidekiq.configure_server do |config|
  config.redis = {
    url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/0'),
    namespace: 'viktory_realty_sidekiq',
    pool_timeout: 5
  }
  
  # Enable periodic jobs
  # config.periodic do |mgr|
  #   mgr.register('0 * * * *', SendViewingRemindersJob)
  #   mgr.register('0 3 * * *', UpdatePropertyStatisticsJob)
  # end
end

Sidekiq.configure_client do |config|
  config.redis = {
    url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/0'),
    namespace: 'viktory_realty_sidekiq',
    pool_timeout: 5
  }
end

# Sidekiq Web UI authentication
require 'sidekiq/web'

Sidekiq::Web.use(Rack::Auth::Basic) do |user, password|
  # Constant time comparison to prevent timing attacks
  ActiveSupport::SecurityUtils.secure_compare(
    ::Digest::SHA256.hexdigest(user),
    ::Digest::SHA256.hexdigest(ENV.fetch('SIDEKIQ_USERNAME', 'admin'))
  ) & ActiveSupport::SecurityUtils.secure_compare(
    ::Digest::SHA256.hexdigest(password),
    ::Digest::SHA256.hexdigest(ENV.fetch('SIDEKIQ_PASSWORD', 'change_me_in_production'))
  )
end

# Set session options
# Sidekiq::Web.set :session_secret, Rails.application.secrets.secret_key_base  # Removed - not supported in Sidekiq 7.2
# Sidekiq::Web.set :sessions, domain: ENV.fetch('APP_DOMAIN', 'localhost')    # Removed - not supported in Sidekiq 7.2

