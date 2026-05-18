# frozen_string_literal: true

# Application Job
# Base class for all background jobs
class ApplicationJob < ActiveJob::Base
  # Automatically retry jobs that encountered a deadlock
  retry_on ActiveRecord::Deadlocked

  # Most jobs are safe to ignore if the underlying records are no longer
  # available — но логируем чтобы понять статистику discards (типичный
  # симптом — job создан до cleanup-задачи которая удалила запись).
  discard_on ActiveJob::DeserializationError do |job, error|
    Rails.logger.warn(
      "[ApplicationJob discard] #{job.class.name} jid=#{job.job_id} " \
      "args=#{job.arguments.inspect.to_s.truncate(200)} " \
      "reason=#{error.class}: #{error.message.to_s.truncate(120)}"
    )
  end
  
  # Retry on common errors
  retry_on StandardError, wait: :exponentially_longer, attempts: 3
  
  # Log job execution
  before_perform do |job|
    Rails.logger.info "Starting job: #{job.class.name} with arguments: #{job.arguments.inspect}"
  end
  
  after_perform do |job|
    Rails.logger.info "Completed job: #{job.class.name}"
  end
  
  # Phase 9 Iter 10 — Critical job classes which warrant DM Оксане on failure.
  # Не для всех jobs (например cleanup tasks — noise) — только для тех что
  # затрагивают live customer/staff flow.
  CRITICAL_JOB_CLASSES = %w[
    DocumentIntake::ParserJob
    Kpi::StaffSnapshotJob
    Kpi::AgencyDigestJob
    DispatcherDigestRefreshJob
    TaskBatchExpiryJob
  ].freeze

  rescue_from(StandardError) do |exception|
    Rails.logger.error "Job failed: #{self.class.name}"
    Rails.logger.error "Error: #{exception.message}"
    Rails.logger.error exception.backtrace.join("\n")

    notify_directors_on_critical_failure(exception) if CRITICAL_JOB_CLASSES.include?(self.class.name)

    raise exception
  end

  private

  def notify_directors_on_critical_failure(exception)
    text = "⚠️ <b>Background job failed</b>\n" \
           "Class: <code>#{self.class.name}</code>\n" \
           "Args: <code>#{arguments.inspect.to_s.truncate(200)}</code>\n" \
           "Error: <code>#{exception.class}: #{exception.message.to_s.truncate(180)}</code>\n\n" \
           '<i>Phase 9 Iter 10 — automatic alert.</i>'

    client = Telegram::Client.new
    # Phase 11 Iter 25 — cascade fallback: directors → admins → managers.
    # Если все directors неактивны, alert не теряется.
    Telegram::CriticalRecipients.resolve.each do |recipient|
      chat_id = recipient.dm_chat_id || recipient.tg_user_id
      next if chat_id.blank?

      client.send_message(text, chat_id: chat_id, parse_mode: 'HTML')
    rescue StandardError => e
      Rails.logger.warn("[ApplicationJob#notify_critical_failure] DM to #{recipient.mention}: #{e.message}")
    end
  end
end

