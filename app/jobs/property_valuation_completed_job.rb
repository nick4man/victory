# frozen_string_literal: true

# Property Valuation Completed Job
# Sends email notification when property valuation is completed
class PropertyValuationCompletedJob < ApplicationJob
  queue_as :mailers
  
  def perform(valuation_id)
    valuation = PropertyValuation.find(valuation_id)
    
    # Send email to client
    PropertyValuationMailer.valuation_completed(valuation).deliver_now
    
    # Send notification to managers
    PropertyValuationMailer.new_valuation_notification(valuation).deliver_now
    
    # Update valuation status
    valuation.update(email_sent: true, email_sent_at: Time.current)
    
    Rails.logger.info "Valuation completion emails sent for valuation ##{valuation_id}"
  rescue ActiveRecord::RecordNotFound => e
    Rails.logger.warn "Valuation ##{valuation_id} not found: #{e.message}"
  end
end

