# frozen_string_literal: true

# Phase 4 — Property Valuation 2.0. Adds two new dimensions to PropertyValuation:
#
# 1. `audit_mode` — which estimator produced the result. 'express' is the
#    legacy + improved (hedonic + bootstrap) market-comparable path; 'investment'
#    is the audit-engine-v2 EI/Monte Carlo path that calls the sidecar.
#
# 2. `audit_engine_id` — UUID returned by the engine's POST /audit/. Lets us
#    refetch monte-carlo results, compare-offers, PDF without re-creating the
#    audit. Nullable + unique-where-not-null because express valuations have none.
#
# 3. `hedonic_data` — jsonb for the Ruby-side hedonic regression artifacts
#    (coefficients, r_squared, predicted_price_per_sqm, ci_lo/hi). Kept
#    separately from `evaluation_data` so it stays trivially queryable.
class AddAuditModeToPropertyValuations < ActiveRecord::Migration[7.1]
  def change
    add_column :property_valuations, :audit_mode, :string, default: 'express', null: false
    add_column :property_valuations, :audit_engine_id, :uuid
    add_column :property_valuations, :hedonic_data, :jsonb, default: {}, null: false

    add_index :property_valuations, :audit_mode
    add_index :property_valuations, :audit_engine_id,
              unique: true, where: 'audit_engine_id IS NOT NULL',
              name: 'idx_property_valuations_audit_engine_id_unique'
  end
end
