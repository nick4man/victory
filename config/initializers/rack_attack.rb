# frozen_string_literal: true

# Rack::Attack Configuration
# Throttling and blocking for security

class Rack::Attack
  ### Configure Cache ###
  
  # Use Redis for Rack::Attack cache
  Rack::Attack.cache.store = ActiveSupport::Cache::RedisCacheStore.new(
    url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/0'),
    namespace: 'viktory_realty_rack_attack'
  )

  ### Throttle Configuration ###
  
  # Throttle all requests by IP (60 requests per minute)
  throttle('req/ip', limit: ENV.fetch('RACK_ATTACK_LIMIT', 300).to_i, period: ENV.fetch('RACK_ATTACK_PERIOD', 5.minutes).to_i) do |req|
    req.ip unless req.path.start_with?('/assets')
  end

  # Throttle POST requests to /login by IP address
  throttle('logins/ip', limit: 5, period: 20.seconds) do |req|
    if req.path == '/users/sign_in' && req.post?
      req.ip
    end
  end

  # Throttle POST requests to /login by email param
  throttle('logins/email', limit: 5, period: 20.seconds) do |req|
    if req.path == '/users/sign_in' && req.post?
      # Normalize email
      req.params['user']['email'].to_s.downcase.gsub(/\s+/, '') if req.params.dig('user', 'email').present?
    end
  end

  # Throttle password reset requests
  throttle('password_reset/ip', limit: 3, period: 5.minutes) do |req|
    if req.path == '/users/password' && req.post?
      req.ip
    end
  end

  # Throttle registration
  throttle('registrations/ip', limit: 5, period: 1.hour) do |req|
    if req.path == '/users' && req.post?
      req.ip
    end
  end

  # Throttle API requests
  throttle('api/ip', limit: 300, period: 5.minutes) do |req|
    if req.path.start_with?('/api')
      req.ip
    end
  end

  # Throttle form submissions
  throttle('inquiries/ip', limit: 10, period: 1.hour) do |req|
    if req.path.match?(%r{/(inquiries|contact_forms|property_valuations)}) && req.post?
      req.ip
    end
  end

  ### Custom Throttles for Authenticated Users ###
  
  # Throttle by user ID for authenticated requests
  throttle('authenticated/user', limit: 1000, period: 1.hour) do |req|
    req.env['warden']&.user&.id if req.env['warden']&.user
  end

  ### Allow2ban: Block IPs making too many bad requests ###
  
  # Block IPs making too many 404 requests
  Rack::Attack.blocklist('fail2ban/404') do |req|
    # Count 404s by IP
    key = "fail2ban:#{req.ip}"
    
    # Mark it as a failed request
    Rack::Attack::Allow2Ban.filter(key, maxretry: 20, findtime: 10.minutes, bantime: 1.hour) do
      req.env['PATH_INFO'] =~ /\.(php|asp|aspx|exe|dll)$/i ||
      req.env['HTTP_USER_AGENT'] =~ /(bot|spider|crawler)/i
    end
  end

  ### Always Allow Safelist ###
  
  # Allow requests from localhost
  safelist('allow-localhost') do |req|
    req.ip == '127.0.0.1' || req.ip == '::1'
  end

  # Allow health checks
  safelist('allow-health-checks') do |req|
    req.path == '/health' || req.path == '/up'
  end

  ### Custom Blocklist ###
  
  # Block specific IPs
  blocklist('block-bad-ips') do |req|
    # You can add bad IPs to Redis with key 'blocked_ips'
    # Redis.current.sismember('blocked_ips', req.ip)
    false
  end

  ### Response Customization ###
  
  # Custom response for throttled requests
  self.throttled_responder = lambda do |env|
    retry_after = env['rack.attack.match_data'][:period]
    
    [
      429,
      {
        'Content-Type' => 'application/json',
        'Retry-After' => retry_after.to_s
      },
      [{
        error: 'Слишком много запросов. Попробуйте позже.',
        retry_after: retry_after
      }.to_json]
    ]
  end

  # Custom response for blocked requests
  self.blocklisted_responder = lambda do |_env|
    [
      403,
      { 'Content-Type' => 'application/json' },
      [{ error: 'Доступ запрещен' }.to_json]
    ]
  end

  ### Logging ###
  
  # Log throttled requests
  ActiveSupport::Notifications.subscribe('throttle.rack_attack') do |_name, _start, _finish, _request_id, payload|
    req = payload[:request]
    Rails.logger.warn "[Rack::Attack][Throttled] #{req.ip} #{req.request_method} #{req.fullpath}"
  end

  # Log blocked requests
  ActiveSupport::Notifications.subscribe('blocklist.rack_attack') do |_name, _start, _finish, _request_id, payload|
    req = payload[:request]
    Rails.logger.warn "[Rack::Attack][Blocked] #{req.ip} #{req.request_method} #{req.fullpath}"
  end
end

