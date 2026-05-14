# frozen_string_literal: true

# Adds explicit premium override flag to Property.
# Premium-сегмент = (price >= Property::PREMIUM_THRESHOLD) OR is_premium = true.
# Threshold-based heuristic covers the bulk of cases; the flag is a marketing
# override for objects that price below threshold but belong to a premium ЖК
# (or, rarely, the opposite — overpriced regular property).
class AddIsPremiumToProperties < ActiveRecord::Migration[7.1]
  def change
    add_column :properties, :is_premium, :boolean, default: false, null: false
    # Partial index — only «true» rows matter for the premium scope query.
    # Smaller index, faster scope, no penalty on the 99% non-premium rows.
    add_index :properties, :is_premium, where: 'is_premium = true', name: 'index_properties_on_is_premium_true'
  end
end
