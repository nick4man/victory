# frozen_string_literal: true

# Median ₽/м² per (city, property_type). Used by PropertyEvaluationService
# as the fallback estimator when the comparable pool is empty — replacing
# the old single hardcoded ABSOLUTE_FALLBACK_PRICE_PER_SQM which was
# calibrated to Ryazan and over-estimated 2-3× for Moscow / under-estimated
# for small cities.
#
# Source data: open analytics (cian.ru/analytics, domclick.ru/research) —
# the seed file documents the snapshot date so dated rows can be refreshed
# manually as the market drifts.
class CreateCityMedianPrices < ActiveRecord::Migration[7.1]
  def change
    create_table :city_median_prices do |t|
      t.string  :city,                 null: false
      t.string  :region                                  # optional disambiguation
      t.string  :property_type,        null: false       # apartment | house | land | commercial | garage | room
      t.integer :median_price_per_sqm, null: false
      t.string  :source                                  # 'cian.ru/analytics 2025-Q1'
      t.date    :as_of                                   # snapshot date for the median

      t.timestamps
    end

    add_index :city_median_prices, %i[city property_type], unique: true
    add_index :city_median_prices, :city
  end
end
