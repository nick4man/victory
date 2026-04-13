# frozen_string_literal: true

# Property Valuation Follow Up Job
# Sends follow-up emails to users whose valuations were completed 3+ days ago.
# When called by the cron schedule (no args), iterates all eligible valuations.
# Can also be called with a specific valuation_id for manual/one-off sends.
class PropertyValuationFollowUpJob < ApplicationJob
  queue_as :low_priority

  FOLLOW_UP_AFTER_DAYS = 3

  def perform(valuation_id = nil)
    if valuation_id.present?
      follow_up_single(valuation_id)
    else
      follow_up_all
    end
  end

  private

  def follow_up_all
    cutoff = FOLLOW_UP_AFTER_DAYS.days.ago

    PropertyValuation.where(status: 'completed')
                     .where('created_at <= ?', cutoff)
                     .where.not(email: [nil, ''])
                     .find_each do |valuation|
      PropertyValuationMailer.follow_up(valuation).deliver_later
      Rails.logger.info "Follow-up email queued for valuation ##{valuation.id}"
    rescue StandardError => e
      Rails.logger.error "Follow-up failed for valuation ##{valuation.id}: #{e.message}"
    end
  end

  def follow_up_single(valuation_id)
    valuation = PropertyValuation.find(valuation_id)
    return unless valuation.email.present?

    PropertyValuationMailer.follow_up(valuation).deliver_now
    Rails.logger.info "Follow-up email sent for valuation ##{valuation_id}"
  rescue ActiveRecord::RecordNotFound => e
    Rails.logger.warn "Valuation ##{valuation_id} not found: #{e.message}"
  end
end
