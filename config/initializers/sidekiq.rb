# frozen_string_literal: true

# Sidekiq configuration

REDIS_CONFIG = {
  url: ENV.fetch('REDIS_URL', 'redis://localhost:6379/0')
}.freeze

Sidekiq.configure_server do |config|
  config.redis = REDIS_CONFIG

  # Load recurring jobs schedule
  schedule_file = Rails.root.join('config', 'sidekiq_schedule.yml')
  if File.exist?(schedule_file) && Sidekiq::Cron::Job.respond_to?(:load_from_hash)
    schedule = YAML.safe_load(ERB.new(File.read(schedule_file)).result, permitted_classes: [Symbol])
    Sidekiq::Cron::Job.load_from_hash(schedule) if schedule
  end
end

Sidekiq.configure_client do |config|
  config.redis = REDIS_CONFIG
end
