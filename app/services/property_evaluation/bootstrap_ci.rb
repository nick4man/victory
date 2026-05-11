# frozen_string_literal: true

module PropertyEvaluation
  # Resamples the comparables set N times with replacement, refits the
  # hedonic regression on each resample, and returns the empirical p5/p95
  # of predicted ₽/м². Yields a confidence band that captures sample-induced
  # variance better than the z-score CI built into Hedonic.
  #
  # Returns nil if the comparables pool is too thin (< MIN_SAMPLE) or if
  # too many resamples fail (degenerate matrices on land/garage edge cases).
  class BootstrapCi
    N_RESAMPLES = 500
    MIN_SAMPLE  = 8
    MIN_VALID_PREDICTIONS = 100

    def self.call(comparables:, target:)
      return nil if comparables.size < MIN_SAMPLE
      new(comparables, target).call
    end

    def initialize(comparables, target)
      @comparables = comparables
      @target = target
      @rng = Random.new
    end

    def call
      predictions = N_RESAMPLES.times.map do
        # Resample with replacement, same size as original — standard
        # bootstrap mechanic.
        sample = Array.new(@comparables.size) { @comparables[@rng.rand(@comparables.size)] }
        result = PropertyEvaluation::Hedonic.call(comparables: sample, target: @target)
        result&.predicted_price_per_sqm
      end.compact
      return nil if predictions.size < MIN_VALID_PREDICTIONS

      sorted = predictions.sort
      {
        p5:  percentile(sorted, 0.05).round(2),
        p25: percentile(sorted, 0.25).round(2),
        p50: percentile(sorted, 0.50).round(2),
        p75: percentile(sorted, 0.75).round(2),
        p95: percentile(sorted, 0.95).round(2),
        n_resamples: predictions.size,
        n_failed:    N_RESAMPLES - predictions.size
      }
    end

    private

    def percentile(sorted, p)
      return 0.0 if sorted.empty?
      rank = ((sorted.size - 1) * p).round
      sorted[rank].to_f
    end
  end
end
