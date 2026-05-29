# frozen_string_literal: true

# Landing controller for /valuations — presents two distinct modes:
#
#   1. Express ("сколько стоит мой объект?") → PropertyValuationsController
#   2. Investment Audit ("стоит ли покупать?") → Valuations::InvestmentController
#
# Both modes share the same PropertyValuation model (discriminated by
# `audit_mode`). Index also surfaces lightweight stats + a featured BUY
# audit so the picker has tangible social proof, not just abstract text.
class ValuationsController < ApplicationController
  def index
    @stats          = stats
    @featured_audit = featured_audit
  end

  private

  def stats
    Rails.cache.fetch('valuations_index:stats:v1', expires_in: 1.hour) do
      completed = PropertyValuation.where(audit_mode: 'investment', status: 'completed')
      {
        audit_count:   completed.count,
        avg_seconds:   median_seconds(completed),
        catalog_count: Property.on_site.count
      }
    end
  end

  # Median (not mean) — protects against runaway jobs that took 8 minutes
  # due to LLM upstream latency from skewing the headline.
  def median_seconds(scope)
    seconds = scope.where('updated_at > created_at')
                   .pluck(Arel.sql('EXTRACT(EPOCH FROM (updated_at - created_at))'))
                   .compact
    return 30 if seconds.empty?
    seconds.sort[seconds.size / 2].to_f.round
  end

  # Most recent completed audit of any verdict. BUY would be ideal social
  # proof but in a fresh agency catalog NEUTRAL is by far the most common
  # outcome — showing the latest verdict (whatever it is) at least proves
  # that audits run end-to-end and produce real numbers.
  def featured_audit
    PropertyValuation
      .where(audit_mode: 'investment', status: 'completed')
      .where.not(address: [nil, ''])
      .order(created_at: :desc)
      .first
  end
end
