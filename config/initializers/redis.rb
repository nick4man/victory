# frozen_string_literal: true

# Redis Configuration for АН "Виктори"

# Redis connection
REDIS = Redis.new(
  url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/0'),
  timeout: 5
  # driver: :hiredis,  # Removed - not supported in Redis 5.0
  # reconnect_attempts: 3,  # Removed - not supported in Redis 5.0
  # reconnect_delay: 0.5,    # Removed - not supported in Redis 5.0
  # reconnect_delay_max: 5.0 # Removed - not supported in Redis 5.0
)

# Redis namespace for different environments
REDIS_NAMESPACE = "viktory_realty_#{Rails.env}"

# Test connection
begin
  REDIS.ping
  Rails.logger.info "✅ Redis connected successfully: #{ENV.fetch('REDIS_URL', 'redis://localhost:6379/0')}"
rescue Redis::CannotConnectError => e
  Rails.logger.error "❌ Redis connection failed: #{e.message}"
  Rails.logger.warn "⚠️  Application will continue without Redis. Some features may be limited."
end

# Redis for Sidekiq (if using background jobs)
if defined?(Sidekiq)
  Sidekiq.configure_server do |config|
    config.redis = {
      url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/0'),
      namespace: "#{REDIS_NAMESPACE}:sidekiq",
      # driver: :hiredis  # Removed - not supported in Redis 5.0
    }
  end

  Sidekiq.configure_client do |config|
    config.redis = {
      url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/0'),
      namespace: "#{REDIS_NAMESPACE}:sidekiq",
      # driver: :hiredis  # Removed - not supported in Redis 5.0
    }
  end
end

# Redis for ActionCable (if using websockets)
if defined?(ActionCable)
  ActionCable.server.config.cable = {
    adapter: 'redis',
    url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/0'),
    channel_prefix: "#{REDIS_NAMESPACE}:cable"
  }
end

# Helper methods for Redis operations
module RedisHelper
  # Cache helper with expiration
  def self.cache_set(key, value, expires_in: 1.hour)
    full_key = "#{REDIS_NAMESPACE}:cache:#{key}"
    REDIS.setex(full_key, expires_in.to_i, value.to_json)
  rescue Redis::BaseError => e
    Rails.logger.error "Redis cache_set failed: #{e.message}"
    nil
  end

  def self.cache_get(key)
    full_key = "#{REDIS_NAMESPACE}:cache:#{key}"
    value = REDIS.get(full_key)
    return nil unless value
    
    JSON.parse(value)
  rescue Redis::BaseError, JSON::ParserError => e
    Rails.logger.error "Redis cache_get failed: #{e.message}"
    nil
  end

  def self.cache_delete(key)
    full_key = "#{REDIS_NAMESPACE}:cache:#{key}"
    REDIS.del(full_key)
  rescue Redis::BaseError => e
    Rails.logger.error "Redis cache_delete failed: #{e.message}"
    nil
  end

  # Counter helper
  def self.increment(key, by: 1)
    full_key = "#{REDIS_NAMESPACE}:counter:#{key}"
    REDIS.incrby(full_key, by)
  rescue Redis::BaseError => e
    Rails.logger.error "Redis increment failed: #{e.message}"
    nil
  end

  def self.decrement(key, by: 1)
    full_key = "#{REDIS_NAMESPACE}:counter:#{key}"
    REDIS.decrby(full_key, by)
  rescue Redis::BaseError => e
    Rails.logger.error "Redis decrement failed: #{e.message}"
    nil
  end

  def self.get_counter(key)
    full_key = "#{REDIS_NAMESPACE}:counter:#{key}"
    REDIS.get(full_key).to_i
  rescue Redis::BaseError => e
    Rails.logger.error "Redis get_counter failed: #{e.message}"
    0
  end
end

