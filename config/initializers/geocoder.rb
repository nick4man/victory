# frozen_string_literal: true

# Geocoder Configuration

Geocoder.configure(
  # Geocoding service
  lookup: :yandex,
  
  # API key (if required)
  api_key: ENV['YANDEX_MAPS_API_KEY'],
  
  # Geocoding service timeout (in seconds)
  timeout: 5,
  
  # Language for results
  language: :ru,
  
  # Use HTTPS
  use_https: true,
  
  # Units for distance calculations
  units: :km,
  
  # Distance calculation method
  distances: :linear,
  
  # Caching (use Redis in production)
  cache: Redis.new(url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/0')),
  cache_prefix: 'geocoder:',
  
  # Always append country code to search queries
  # always_raise: [
  #   Geocoder::OverQueryLimitError,
  #   Geocoder::RequestDenied,
  #   Geocoder::InvalidRequest,
  #   Geocoder::InvalidApiKey
  # ],
  
  # Yandex-specific options
  yandex: {
    api_key: ENV['YANDEX_MAPS_API_KEY'],
    lang: :ru_RU
  }
)

# Log geocoding queries in development
if Rails.env.development?
  Geocoder.configure(logger: Rails.logger)
end

