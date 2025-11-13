# frozen_string_literal: true

# CarrierWave Configuration
require 'carrierwave/storage/abstract'
require 'carrierwave/storage/file'
require 'carrierwave/storage/fog'

CarrierWave.configure do |config|
  # Choose storage based on environment
  if Rails.env.production? && ENV['AWS_ACCESS_KEY_ID'].present?
    # Production with S3/Yandex Object Storage
    config.storage = :fog
    config.fog_provider = 'fog/aws'
    config.fog_credentials = {
      provider:              'AWS',
      aws_access_key_id:     ENV['AWS_ACCESS_KEY_ID'],
      aws_secret_access_key: ENV['AWS_SECRET_ACCESS_KEY'],
      region:                ENV.fetch('AWS_REGION', 'us-east-1'),
      # For Yandex Object Storage
      # endpoint:              'https://storage.yandexcloud.net',
      # path_style:            true
    }
    config.fog_directory  = ENV.fetch('AWS_BUCKET', 'viktory-realty')
    config.fog_public     = true
    config.fog_authenticated_url_expiration = 600
    config.fog_attributes = {
      'Cache-Control' => "public, max-age=#{365.days.to_i}",
      'X-Content-Type-Options' => 'nosniff'
    }
  else
    # Development, test, or production without S3
    config.storage = :file
    config.enable_processing = Rails.env.development? || Rails.env.production?
  end

  # Directory configuration
  config.root = Rails.root

  # Cache settings
  config.cache_dir = Rails.root.join('tmp', 'uploads')

  # Permissions
  config.permissions = 0o644
  config.directory_permissions = 0o755

  # Remove uploaded files on record destroy
  config.remove_previously_stored_files_after_update = true

  # Ignore processing errors
  config.ignore_processing_errors = false

  # Integrity check
  config.ignore_integrity_errors = false

  # Whitelist validation (removed - not supported in CarrierWave 3.0)
  # config.ignore_whitelist_integrity_errors = false

  # Download validation
  config.ignore_download_errors = false

  # Processing validation
  config.validate_integrity = true
  config.validate_processing = true
  config.validate_download = true
end

