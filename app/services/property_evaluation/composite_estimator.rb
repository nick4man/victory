# frozen_string_literal: true

module PropertyEvaluation
  # Wraps the existing PriceEstimator (weighted median + multiplicative
  # adjustments) and augments it with a hedonic regression signal plus a
  # bootstrap confidence interval. The composite price is a weighted
  # average of the two estimates.
  #
  # Decision logic:
  #   N < MIN_HEDONIC → fall back to PriceEstimator output unchanged
  #   N ≥ MIN_HEDONIC → blend MEDIAN_WEIGHT * median + HEDONIC_WEIGHT * hedonic
  #
  # Reasoning for blending:
  #   - Median is robust to outliers but doesn't differentiate area, rooms
  #     beyond the comparable selection.
  #   - Hedonic regression captures non-linear effects (log(area), distance)
  #     but is fragile on small samples / homogeneous comparables.
  #   - Blending leverages both — neither dominates.
  class CompositeEstimator
    # Re-calibrated 15.05.26 — 8 был слишком высокий для тонкого Ryazan
    # catalog. Sample обычно 5-7 (3 semantic + 2 external + 0-2 synth),
    # с 8-threshold hedonic skip'ался и estimate = pure median (без
    # area/rooms adjustment). На 5 hedonic менее robust, но даже грубая
    # regression лучше pure median для смещения по area. Hedonic возвращает
    # nil если matrix singular — composite_estimator safely fallback.
    MIN_HEDONIC    = 5
    HEDONIC_WEIGHT = 0.4
    MEDIAN_WEIGHT  = 0.6

    def self.call(comparables:, target_area:, target_rooms:, base_estimate:)
      new(comparables, target_area, target_rooms, base_estimate).call
    end

    def initialize(comparables, target_area, target_rooms, base_estimate)
      @comparables = enrich_comparables(comparables)
      @target = { area: target_area.to_f, rooms: target_rooms.to_i, distance_km: 0.0 }
      @base = base_estimate
    end

    def call
      return base_only if @comparables.size < MIN_HEDONIC

      hedonic = PropertyEvaluation::Hedonic.call(comparables: @comparables, target: @target)
      bootstrap = PropertyEvaluation::BootstrapCi.call(comparables: @comparables, target: @target)
      return base_only if hedonic.nil?

      median_pps = @base[:base_price_per_sqm].to_f
      hedonic_pps = hedonic.predicted_price_per_sqm
      composite_pps = (MEDIAN_WEIGHT * median_pps + HEDONIC_WEIGHT * hedonic_pps).round(2)

      area = @target[:area]
      composite_price = (composite_pps * area).round(-3)

      result = @base.merge(
        estimated_price:    composite_price,
        price_per_sqm:      composite_pps,
        composite: {
          median_weight:  MEDIAN_WEIGHT,
          hedonic_weight: HEDONIC_WEIGHT,
          median_pps:     median_pps.round(2),
          hedonic_pps:    hedonic_pps.round(2),
          composite_pps:  composite_pps
        },
        hedonic: hedonic.to_h
      )

      if bootstrap
        result.merge!(
          min_price: (bootstrap[:p5]  * area).round(-3),
          max_price: (bootstrap[:p95] * area).round(-3),
          bootstrap_ci: bootstrap
        )
      end

      result
    end

    private

    # ComparableFinder hands us comparables shaped as { record:, price_per_sqm:,
    # distance_km:, weight: }. Hedonic needs flat { rooms:, area:, price_per_sqm:,
    # distance_km: } — extract.
    def enrich_comparables(comps)
      comps.map do |c|
        r = c[:record]
        {
          rooms:         r.try(:rooms),
          area:          r.try(:area).to_f,
          price_per_sqm: c[:price_per_sqm].to_f,
          distance_km:   c[:distance_km].to_f
        }
      end
    end

    def base_only
      @base
    end
  end
end
