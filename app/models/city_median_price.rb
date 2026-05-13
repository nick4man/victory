# frozen_string_literal: true

# Median ₽/м² per (city, property_type) — fallback estimator when the
# comparable-finder pool is empty. Replaces the old single Ryazan-calibrated
# constant ABSOLUTE_FALLBACK_PRICE_PER_SQM.
#
# Data source: curated snapshots from cian.ru/analytics and
# domclick.ru/research. Seed is in db/seeds/city_median_prices.rb; rake
# task `city_prices:reseed` refreshes from the same source.
class CityMedianPrice < ApplicationRecord
  PROPERTY_TYPES = %w[apartment house land commercial garage room].freeze

  validates :city, :property_type, :median_price_per_sqm, presence: true
  validates :property_type, inclusion: { in: PROPERTY_TYPES }
  validates :city, uniqueness: { scope: :property_type }

  # Resolve a median for a given city name. Accepts CRM-style strings like
  # 'г. Москва' or 'г Москва' — strips the prefix and ILIKE-matches.
  # Returns nil if no row found (caller falls back to a federal default).
  #
  # @param city [String, nil]
  # @param property_type [String]  one of PROPERTY_TYPES
  # @return [Integer, nil]
  def self.lookup(city, property_type)
    return nil if city.blank? || property_type.blank?

    normalized = city.to_s.sub(/^\s*г\.?\s*/i, '').strip
    return nil if normalized.blank?

    where('city ILIKE ?', normalized).find_by(property_type: property_type.to_s)&.median_price_per_sqm
  end
end
