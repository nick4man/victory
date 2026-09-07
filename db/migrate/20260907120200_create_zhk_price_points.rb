# frozen_string_literal: true

# Append-only ряд цены за м². Никаких пересчётов при записи: тренды считает
# отдельная спека, когда наберётся хотя бы пара месяцев замеров.
class CreateZhkPricePoints < ActiveRecord::Migration[8.1]
  def change
    create_table :zhk_price_points do |t|
      t.references :residential_complex, null: false, foreign_key: true
      t.string     :source,        null: false
      t.datetime   :observed_at,   null: false
      t.integer    :price_per_sqm, null: false
      t.integer    :kind,          null: false, default: 0
      t.integer    :rooms
      t.string     :url
      t.timestamps
    end

    add_index :zhk_price_points, %i[residential_complex_id observed_at]
  end
end
