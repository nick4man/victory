# frozen_string_literal: true

# Market Analytics Update Job
# Calculates and caches market price statistics for the main property categories
class MarketAnalyticsUpdateJob < ApplicationJob
  queue_as :low_priority

  DEAL_TYPES = %w[sale rent].freeze

  def perform
    Rails.logger.info 'Starting market analytics update'

    DEAL_TYPES.each do |deal_type|
      update_price_stats(deal_type)
    end

    Rails.logger.info 'Market analytics update completed'
  end

  private

  def update_price_stats(deal_type)
    properties = Property.published.where(deal_type: deal_type).where.not(price: nil)
    return if properties.empty?

    stats = {
      count:   properties.count,
      avg:     properties.average(:price)&.round,
      median:  median_price(properties),
      min:     properties.minimum(:price),
      max:     properties.maximum(:price),
      updated_at: Time.current.iso8601
    }

    Rails.cache.write(
      "market_stats/#{deal_type}",
      stats,
      expires_in: 25.hours
    )

    Rails.logger.info "Updated market stats for #{deal_type}: #{stats[:count]} properties, avg #{stats[:avg]} ₽"
  end

  def median_price(properties)
    prices = properties.order(:price).pluck(:price).map(&:to_f)
    return nil if prices.empty?

    mid = prices.size / 2
    prices.size.odd? ? prices[mid].round : ((prices[mid - 1] + prices[mid]) / 2).round
  end
end
