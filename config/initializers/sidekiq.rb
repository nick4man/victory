# frozen_string_literal: true

# Phase 9 Iter 11 — Critical-job alert handler для plain Sidekiq::Job classes.
#
# ApplicationJob (ActiveJob) имеет rescue_from + DM-alert helper (Phase 9 Iter 10).
# Но 4 из 5 наших CRITICAL_JOB_CLASSES — plain Sidekiq::Job (Kpi::StaffSnapshotJob,
# Kpi::AgencyDigestJob, TaskBatchExpiryJob, DispatcherDigestRefreshJob).
# Для них rescue_from не fires → DM alerts silent.
#
# Fix: Sidekiq.configure_server { config.error_handlers << ... } ловит ВСЕ
# unhandled exceptions из Sidekiq workers (включая plain Sidekiq::Job).
# Filter по job class name (только critical → DM, остальное → log only).

# Список critical classes (mirror ApplicationJob::CRITICAL_JOB_CLASSES, плюс
# Sidekiq-only jobs которые тоже считаем critical).
CRITICAL_SIDEKIQ_JOBS = %w[
  Kpi::StaffSnapshotJob
  Kpi::AgencyDigestJob
  TaskBatchExpiryJob
  DispatcherDigestRefreshJob
  DigestCleanupJob
].freeze

Sidekiq.configure_server do |config|
  config.error_handlers << lambda { |exception, context, _config_or_nil|
    begin
      job_class_full = context[:job]&.dig('class').to_s
      Rails.logger.error("[Sidekiq] error_handler caught #{job_class_full}: #{exception.class}: #{exception.message}")

      if CRITICAL_SIDEKIQ_JOBS.include?(job_class_full)
        notify_directors_about_sidekiq_failure(job_class_full, exception, context)
      end
    rescue StandardError => e
      Rails.logger.warn("[Sidekiq error_handler] alert dispatch failed: #{e.class}: #{e.message}")
    end
  }
end

def notify_directors_about_sidekiq_failure(job_class, exception, context)
  return unless defined?(TelegramUser) && defined?(Telegram::Client)

  args = context[:job]&.dig('args').inspect.to_s.truncate(200)
  text = "⚠️ <b>Sidekiq job failed</b>\n" \
         "Class: <code>#{job_class}</code>\n" \
         "Args: <code>#{args}</code>\n" \
         "Error: <code>#{exception.class}: #{exception.message.to_s.truncate(160)}</code>\n\n" \
         '<i>Phase 9 Iter 11 — Sidekiq error_handler alert.</i>'

  client = Telegram::Client.new
  TelegramUser.directors.active.find_each do |director|
    chat_id = director.dm_chat_id || director.tg_user_id
    next if chat_id.blank?

    client.send_message(text, chat_id: chat_id, parse_mode: 'HTML')
  rescue StandardError => e
    Rails.logger.warn("[Sidekiq alert] DM to #{director.mention} failed: #{e.message}")
  end
end
