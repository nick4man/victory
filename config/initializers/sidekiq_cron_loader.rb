# frozen_string_literal: true

# Load periodic schedule defined in config/sidekiq_cron.yml into Sidekiq::Cron
# only when the process is the Sidekiq server (avoid registering jobs from web).
Rails.application.config.after_initialize do
  next unless defined?(Sidekiq) && Sidekiq.server?
  next unless defined?(Sidekiq::Cron::Job)

  schedule_path = Rails.root.join('config/sidekiq_cron.yml')
  next unless File.exist?(schedule_path)

  schedule = YAML.safe_load(ERB.new(File.read(schedule_path)).result, aliases: true) || {}
  Sidekiq::Cron::Job.load_from_hash(schedule) if schedule.any?
  Rails.logger.info("Sidekiq::Cron loaded jobs: #{Sidekiq::Cron::Job.all.map(&:name).inspect}")
end
