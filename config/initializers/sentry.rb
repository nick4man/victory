# frozen_string_literal: true

# Sentry Configuration
# Error tracking and monitoring

if ENV['SENTRY_DSN'].present?
  Sentry.init do |config|
    config.dsn = ENV['SENTRY_DSN']
    
    # Set environment
    config.environment = Rails.env
    
    # Set release version
    config.release = ENV.fetch('APP_VERSION', 'unknown')
    
    # Breadcrumbs
    config.breadcrumbs_logger = [:active_support_logger, :http_logger]
    
    # Sampling
    config.traces_sample_rate = ENV.fetch('SENTRY_TRACES_SAMPLE_RATE', 0.1).to_f
    
    # Ignore certain errors
    config.excluded_exceptions += [
      'ActionController::RoutingError',
      'ActiveRecord::RecordNotFound',
      'ActionController::InvalidAuthenticityToken',
      'ActionController::UnknownFormat',
      'Rack::QueryParser::InvalidParameterError'
    ]
    
    # Filter sensitive data
    config.send_default_pii = false
    config.sanitize_fields = Rails.application.config.filter_parameters.map(&:to_s)
    
    # Before send hook
    config.before_send = lambda do |event, hint|
      # Don't send events in development/test
      return nil if Rails.env.development? || Rails.env.test?
      
      # Filter out certain requests
      if event.request&.url&.include?('/health')
        return nil
      end
      
      event
    end
    
    # Performance monitoring
    config.traces_sampler = lambda do |sampling_context|
      # High priority transactions
      if sampling_context[:parent_sampled] == true
        1.0
      # Background jobs
      elsif sampling_context[:env] && sampling_context[:env]['action_dispatch.request_id']
        0.1
      # Default
      else
        0.01
      end
    end
    
    # Async reporting
    config.background_worker_threads = 5
    
    # Timeout
    config.timeout = 2
    config.open_timeout = 1
  end
end

