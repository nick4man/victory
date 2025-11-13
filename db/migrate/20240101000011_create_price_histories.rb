# frozen_string_literal: true

class CreatePriceHistories < ActiveRecord::Migration[7.0]
  def change
    create_table :price_histories do |t|
      # Associations
      t.references :property, null: false, foreign_key: true, index: true
      t.references :changed_by, foreign_key: { to_table: :users }, index: true

      # Price data
      t.decimal :old_price, precision: 15, scale: 2
      t.decimal :new_price, precision: 15, scale: 2, null: false
      t.decimal :price_change, precision: 15, scale: 2 # difference
      t.decimal :price_change_percent, precision: 5, scale: 2 # percentage
      
      # Change details
      t.string :change_type, null: false # increase, decrease
      t.text :reason
      t.text :notes
      
      # Metadata
      t.datetime :effective_date, null: false # when the price change is effective
      t.boolean :auto_generated, default: false, null: false
      
      t.timestamps
    end

    # Indexes
    add_index :price_histories, :change_type
    add_index :price_histories, :effective_date
    add_index :price_histories, [:property_id, :effective_date]
    add_index :price_histories, [:property_id, :created_at]
    add_index :price_histories, :created_at
  end
end

