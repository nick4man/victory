# frozen_string_literal: true

# Property Valuation Follow Up Job
# Sends follow-up emails after valuation
class PropertyValuationFollowUpJob < ApplicationJob
  queue_as :low_priority
  
  # This job should be scheduled to run after 3 days of valuation completion
  def perform(valuation_id)
    valuation = PropertyValuation.find(valuation_id)
    
    # Check if already followed up
    return if valuation.follow_up_email_sent?
    
    # Send follow-up email
    PropertyValuationMailer.follow_up(valuation).deliver_now
    
    # Update valuation
    valuation.update(follow_up_email_sent: true, follow_up_email_sent_at: Time.current)
    
    Rails.logger.info "Follow-up email sent for valuation ##{valuation_id}"
  rescue ActiveRecord::RecordNotFound => e
    Rails.logger.warn "Valuation ##{valuation_id} not found: #{e.message}"
  end
end

