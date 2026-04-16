# frozen_string_literal: true

# Rack::Attack — rate limiting and request throttling
# Requires Redis (via REDIS_URL env var) for distributed counter storage.
# Enable middleware in config/application.rb: config.middleware.use Rack::Attack

Rack::Attack.cache.store = ActiveSupport::Cache::RedisCacheStore.new(
  url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/1'),
  namespace: 'rack_attack'
)

# ============================================
# GLOBAL THROTTLE: 300 requests per 5 minutes per IP
# ============================================
Rack::Attack.throttle('req/ip', limit: 300, period: 5.minutes) do |req|
  req.ip unless req.path.start_with?('/health', '/assets')
end

# ============================================
# AUTH ENDPOINTS: max 5 login attempts per 20 minutes per IP
# ============================================
Rack::Attack.throttle('login/ip', limit: 5, period: 20.minutes) do |req|
  req.ip if req.path == '/users/sign_in' && req.post?
end

# Throttle by email to prevent targeted brute-force
Rack::Attack.throttle('login/email', limit: 5, period: 20.minutes) do |req|
  if req.path == '/users/sign_in' && req.post?
    req.params.dig('user', 'email')&.to_s&.downcase&.strip
  end
end

# Registration: 3 per IP per hour
Rack::Attack.throttle('signup/ip', limit: 3, period: 1.hour) do |req|
  req.ip if req.path == '/users' && req.post?
end

# ============================================
# API ENDPOINTS: 100 requests per hour per IP
# ============================================
Rack::Attack.throttle('api/ip', limit: 100, period: 1.hour) do |req|
  req.ip if req.path.start_with?('/api/')
end

# ============================================
# CONTACT FORM: 5 submissions per IP per hour
# ============================================
Rack::Attack.throttle('contact_form/ip', limit: 5, period: 1.hour) do |req|
  req.ip if req.path == '/contacts' && req.post?
end

# ============================================
# VALUATION FORM: 10 per IP per hour
# ============================================
Rack::Attack.throttle('valuation/ip', limit: 10, period: 1.hour) do |req|
  req.ip if req.path.start_with?('/valuations') && req.post?
end

# ============================================
# RESPONSE FOR THROTTLED REQUESTS
# ============================================
Rack::Attack.throttled_responder = lambda do |req|
  match_data = req.env['rack.attack.match_data']
  now = match_data[:epoch_time]

  headers = {
    'Content-Type'          => 'application/json',
    'X-RateLimit-Limit'     => match_data[:limit].to_s,
    'X-RateLimit-Remaining' => '0',
    'X-RateLimit-Reset'     => (now + (match_data[:period] - now % match_data[:period])).to_s,
    'Retry-After'           => (match_data[:period] - now % match_data[:period]).to_s
  }

  [429, headers, [{ error: 'Too Many Requests' }.to_json]]
end

# ============================================
# LOGGING
# ============================================
ActiveSupport::Notifications.subscribe('throttle.rack_attack') do |_name, _start, _finish, _id, payload|
  req = payload[:request]
  Rails.logger.warn "[Rack::Attack] Throttled #{req.ip} — #{req.path} (#{req.env['rack.attack.matched']})"
end
