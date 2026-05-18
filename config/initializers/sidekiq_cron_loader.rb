# frozen_string_literal: true

# Load periodic schedule defined in config/sidekiq_cron.yml into Sidekiq::Cron
# only when the process is the Sidekiq server (avoid registering jobs from web).
Rails.application.config.after_initialize do
  next unless defined?(Sidekiq) && Sidekiq.server?
  next unless defined?(Sidekiq::Cron::Job)

  schedule_path = Rails.root.join('config/sidekiq_cron.yml')
  next unless File.exist?(schedule_path)

  schedule = YAML.safe_load(ERB.new(File.read(schedule_path)).result, aliases: true) || {}

  # Все наши cron-jobs наследуют от ApplicationJob (ActiveJob). sidekiq-cron 1.12+
  # по умолчанию вызывает `klass.perform_async`, который доступен только на
  # Sidekiq::Worker, а не на ActiveJob → NoMethodError. Force `active_job: true`
  # на каждом entry чтобы sidekiq-cron делал `klass.set(queue:).perform_later`.
  # См. https://github.com/sidekiq-cron/sidekiq-cron#activejob
  schedule.each_value do |entry|
    entry['active_job'] = true if entry.is_a?(Hash) && !entry.key?('active_job')
  end

  Sidekiq::Cron::Job.load_from_hash(schedule) if schedule.any?
  Rails.logger.info("Sidekiq::Cron loaded jobs: #{Sidekiq::Cron::Job.all.map(&:name).inspect}")
end
