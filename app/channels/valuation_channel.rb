# frozen_string_literal: true

# Pushes audit status updates to the /valuations/audit/:token page so the
# loader can flip to the result view the moment InvestmentAuditJob finishes
# (~14s for 1M MC). Falls back to the 10-second polling endpoint
# (Valuations::InvestmentController#status) if the WS doesn't deliver.
#
# Subscription params: { token: <valuation.token> }
class ValuationChannel < ApplicationCable::Channel
  def subscribed
    valuation = PropertyValuation.find_by(token: params[:token])
    return reject if valuation.nil?

    stream_for valuation
  end
end
