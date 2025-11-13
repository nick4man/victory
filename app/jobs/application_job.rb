# frozen_string_literal: true

# Application Job
# Base class for all background jobs
class ApplicationJob < ActiveJob::Base
  # Automatically retry jobs that encountered a deadlock
  retry_on ActiveRecord::Deadlocked

  # Most jobs are safe to ignore if the underlying records are no longer available
  discard_on ActiveJob::DeserializationError
  
  # Retry on common errors
  retry_on StandardError, wait: :exponentially_longer, attempts: 3
  
  # Log job execution
  before_perform do |job|
    Rails.logger.info "Starting job: #{job.class.name} with arguments: #{job.arguments.inspect}"
  end
  
  after_perform do |job|
    Rails.logger.info "Completed job: #{job.class.name}"
  end
  
  rescue_from(StandardError) do |exception|
    Rails.logger.error "Job failed: #{self.class.name}"
    Rails.logger.error "Error: #{exception.message}"
    Rails.logger.error exception.backtrace.join("\n")
    
    # Send error notification if needed
    # ErrorNotificationService.new(exception, job: self).notify
    
    raise exception
  end
end

