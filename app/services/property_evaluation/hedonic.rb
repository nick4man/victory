# frozen_string_literal: true

require 'matrix'

module PropertyEvaluation
  # Ruby port of audit-engine-v2's `src/audit_engine/hedonic.py` (OLS
  # hedonic regression) — for the Express estimator. Median ₽/m² over
  # comparables ignores object characteristics; this corrects for area,
  # rooms count, and distance to the subject.
  #
  # Model:
  #   log(price_per_sqm) = β0 + β1·rooms + β2·log(area_sqm) + β3·distance_km + ε
  #
  # OLS via stdlib Matrix#solve_LR. N≤300 finishes in <50 ms with no native
  # extensions (no numo/lapack dep). Returns nil if the sample is too small
  # (<8) or the design matrix is degenerate.
  class Hedonic
    MIN_SAMPLE = 8
    CI_Z_95 = 1.96

    Result = Struct.new(
      :predicted_price_per_sqm,
      :ci_lo_95,
      :ci_hi_95,
      :n_used,
      :r_squared,
      :residual_std,
      :feature_names,
      :coefficients,
      keyword_init: true
    ) do
      def to_h
        {
          predicted_price_per_sqm: predicted_price_per_sqm.round(2),
          ci_lo_95: ci_lo_95.round(2),
          ci_hi_95: ci_hi_95.round(2),
          n_used: n_used,
          r_squared: r_squared.round(4),
          residual_std: residual_std.round(4),
          feature_names: feature_names,
          coefficients: coefficients.map { |c| c.round(6) }
        }
      end
    end

    # comparables: Array<Hash> with keys :rooms, :area, :price_per_sqm, :distance_km
    # target: Hash { rooms:, area:, distance_km: }
    def self.call(comparables:, target:)
      new(comparables, target).call
    end

    def initialize(comparables, target)
      @raw = comparables
      @target = target
    end

    def call
      rows, ys = build_design_matrix
      n = rows.length
      return nil if n < MIN_SAMPLE

      x_full = Matrix.rows(rows)
      kept_idx = drop_constant_columns(x_full)
      return nil if kept_idx.size < 2 # intercept + at least one feature

      x = Matrix.columns(kept_idx.map { |i| x_full.column(i).to_a })
      return nil unless full_rank?(x)

      # OLS: β = (X'X)⁻¹ X'y
      xt = x.transpose
      xtx = xt * x
      return nil unless xtx.regular?

      beta_reduced = xtx.inverse * xt * Matrix.column_vector(ys)
      beta_reduced = beta_reduced.column(0).to_a

      # Residuals, R², residual std
      y_pred = x * Matrix.column_vector(beta_reduced)
      y_pred = y_pred.column(0).to_a
      residuals = ys.each_with_index.map { |yi, i| yi - y_pred[i] }
      ss_res = residuals.sum { |r| r * r }
      mean_y = ys.sum.to_f / ys.length
      ss_tot = ys.sum { |yi| (yi - mean_y) * (yi - mean_y) }
      r_squared = ss_tot.positive? ? 1.0 - (ss_res / ss_tot) : 0.0
      dof = n - kept_idx.size
      residual_std = dof.positive? ? Math.sqrt(ss_res / dof) : 0.0

      # Predict for target on the reduced feature set
      x_target_full = [1.0, @target[:rooms].to_f, Math.log(@target[:area].to_f), @target[:distance_km].to_f]
      x_target = kept_idx.map { |i| x_target_full[i] }
      log_pred = beta_reduced.each_with_index.sum { |b, i| b * x_target[i] }
      pred = Math.exp(log_pred)
      half_log = CI_Z_95 * residual_std
      ci_lo = Math.exp(log_pred - half_log)
      ci_hi = Math.exp(log_pred + half_log)

      feature_names_full = %w[intercept rooms log_area distance_km]
      Result.new(
        predicted_price_per_sqm: pred,
        ci_lo_95: ci_lo,
        ci_hi_95: ci_hi,
        n_used: n,
        r_squared: r_squared,
        residual_std: residual_std,
        feature_names: kept_idx.map { |i| feature_names_full[i] },
        coefficients: beta_reduced
      )
    rescue ExceptionForMatrix::ErrNotRegular, ZeroDivisionError, Math::DomainError => e
      Rails.logger.info("[Hedonic] regression failed: #{e.class} #{e.message}")
      nil
    end

    private

    # Returns [rows, ys] where rows = [[1.0, rooms, log(area), distance_km], ...]
    # and ys = [log(price_per_sqm), ...]. Drops comps with missing/zero
    # area, rooms, or price_per_sqm.
    def build_design_matrix
      rows = []
      ys = []
      @raw.each do |c|
        area = c[:area].to_f
        ppsm = c[:price_per_sqm].to_f
        next if area <= 0 || ppsm <= 0
        next if c[:rooms].nil?

        distance_km = (c[:distance_km] || 0).to_f
        rows << [1.0, c[:rooms].to_f, Math.log(area), distance_km]
        ys << Math.log(ppsm)
      end
      [rows, ys]
    end

    # Returns indices of columns to keep. Intercept (column 0) is always
    # kept. Non-intercept columns with zero variance are dropped.
    def drop_constant_columns(matrix)
      kept = [0]
      (1...matrix.column_count).each do |j|
        col = matrix.column(j).to_a
        mean = col.sum.to_f / col.length
        variance = col.sum { |v| (v - mean) * (v - mean) } / col.length
        kept << j if variance > 1e-9
      end
      kept
    end

    def full_rank?(matrix)
      matrix.rank == matrix.column_count
    rescue StandardError
      false
    end
  end
end
