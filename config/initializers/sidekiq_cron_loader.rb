# frozen_string_literal: true

# Load periodic schedule defined in config/sidekiq_cron.yml into Sidekiq::Cron
# only when the process is the Sidekiq server (avoid registering jobs from web).
Rails.application.config.after_initialize do
  next unless defined?(Sidekiq) && Sidekiq.server?
  next unless defined?(Sidekiq::Cron::Job)

  schedule_path = Rails.root.join('config/sidekiq_cron.yml')
  next unless File.exist?(schedule_path)

  schedule = YAML.safe_load(ERB.new(File.read(schedule_path)).result, aliases: true) || {}

  # sidekiq-cron 1.12+ по умолчанию вызывает `klass.perform_async`. Это
  # работает для plain Sidekiq::Worker, но НЕ для ActiveJob (где метод —
  # `perform_later`). Большинство наших cron-jobs наследуют ApplicationJob,
  # но есть исключения (Telegram::WorkBot::PollingJob — include Sidekiq::Job).
  # Per-entry detect: загружаем класс и смотрим, потомок ли он ActiveJob::Base.
  # Default — false (Sidekiq worker), чтобы не сломать existing direct-workers.
  schedule.each_value do |entry|
    next unless entry.is_a?(Hash)
    next if entry.key?('active_job')  # honor explicit override в YAML

    klass_name = entry['class'].to_s
    next if klass_name.blank?

    begin
      klass = klass_name.constantize
      entry['active_job'] = true if klass < ActiveJob::Base
    rescue NameError => e
      Rails.logger.warn("[sidekiq_cron_loader] cannot resolve #{klass_name}: #{e.message}")
      next
    end
  end

  Sidekiq::Cron::Job.load_from_hash(schedule) if schedule.any?
  Rails.logger.info("Sidekiq::Cron loaded jobs: #{Sidekiq::Cron::Job.all.map(&:name).inspect}")
end
