# frozen_string_literal: true

# Computes weighted-median price/m² across the comparable pool, then applies
# deterministic hedonic adjustments for floor / building year / condition / amenities.
module PropertyEvaluation
  class PriceEstimator
    CONDITION_FACTOR = {
      'needs_repair' => 0.88,
      'average'      => 0.96,
      'good'         => 1.03,
      'excellent'    => 1.10,
      'designer'     => 1.18
    }.freeze

    def initialize(valuation, comparables)
      @v = valuation
      @comps = comparables
    end

    def call
      base_pps = weighted_median(@comps.map { |c| [c[:price_per_sqm], c[:weight]] })
      factors = {
        floor:     floor_factor,
        year:      year_factor,
        condition: condition_factor,
        amenities: amenities_factor
      }
      adjusted = factors.values.reduce(base_pps.to_f) { |acc, f| acc * f }
      estimated = (adjusted * subject_area).round(-3)

      {
        base_price_per_sqm: base_pps.round,
        price_per_sqm:      adjusted.round,
        estimated_price:    estimated,
        min_price:          (estimated * 0.92).round(-3),
        max_price:          (estimated * 1.08).round(-3),
        adjustments:        factors
      }
    end

    private

    def subject_area
      if @v.property_type.to_s == 'land'
        @v.respond_to?(:land_area_in_sqm) ? @v.land_area_in_sqm.to_f : @v.land_area.to_f * 100
      else
        @v.total_area.to_f
      end
    end

    def weighted_median(pairs)
      return 0 if pairs.empty?

      sorted = pairs.sort_by(&:first)
      total  = sorted.sum { |_, w| w }
      half = total / 2.0
      cum = 0.0
      sorted.each do |value, weight|
        cum += weight
        return value if cum >= half
      end
      sorted.last.first
    end

    def floor_factor
      return 1.0 unless @v.floor.present? && @v.total_floors.present?

      f = @v.floor.to_i
      t = @v.total_floors.to_i
      return 0.94 if f == 1 && t > 1
      return 1.06 if f == t && t.between?(2, 5)
      return 0.96 if f == t && t > 16
      1.0
    end

    def year_factor
      y = @v.building_year.to_i
      return 1.0 if y <= 0
      return 0.92 if y < 1970
      return 1.04 if y.between?(2000, 2014)
      return 1.07 if y >= 2015
      1.0
    end

    def condition_factor
      CONDITION_FACTOR[@v.property_condition.to_s] || 1.0
    end

    def amenities_factor
      bonus = 0.0
      bonus += 0.02 if @v.has_garage
      bonus += 0.01 if @v.has_balcony
      bonus += 0.01 if @v.has_loggia
      1.0 + bonus
    end
  end
end
