# frozen_string_literal: true

class CreatePropertyValuations < ActiveRecord::Migration[7.1]
  def change
    create_table :property_valuations do |t|
      # Associations
      t.references :user, foreign_key: true, null: true, index: true
      
      # Property Information
      t.string :property_type, null: false, index: true
      t.string :deal_type, null: false
      t.string :address, null: false
      t.string :city
      t.string :district
      
      # Area and Rooms
      t.decimal :total_area, precision: 8, scale: 2, null: false
      t.decimal :living_area, precision: 8, scale: 2
      t.decimal :kitchen_area, precision: 8, scale: 2
      t.integer :rooms
      
      # Floor Information
      t.integer :floor
      t.integer :total_floors
      
      # Building Information
      t.string :building_type
      t.integer :building_year
      t.string :condition
      
      # Features
      t.boolean :has_balcony, default: false
      t.boolean :has_loggia, default: false
      t.boolean :has_garage, default: false
      
      # Location
      t.string :metro_station
      t.integer :metro_distance
      t.decimal :latitude, precision: 10, scale: 6
      t.decimal :longitude, precision: 10, scale: 6
      
      # Valuation Results
      t.decimal :estimated_price, precision: 12, scale: 2
      t.decimal :min_price, precision: 12, scale: 2
      t.decimal :max_price, precision: 12, scale: 2
      t.decimal :confidence_level, precision: 3, scale: 2
      t.jsonb :evaluation_data, default: {}
      
      # Contact Information
      t.string :name
      t.string :email
      t.string :phone
      
      # Additional
      t.text :description
      t.string :token, null: false, index: { unique: true }
      t.string :status, default: 'pending', null: false, index: true
      
      # Tracking
      t.string :ip_address
      t.string :user_agent
      t.boolean :call_requested, default: false
      t.datetime :call_requested_at
      t.datetime :viewed_at
      t.integer :views_count, default: 0
      
      t.timestamps
    end
    
    # Indexes for performance
    add_index :property_valuations, :created_at
    add_index :property_valuations, [:property_type, :deal_type]
    add_index :property_valuations, :email
    add_index :property_valuations, :estimated_price
    add_index :property_valuations, [:latitude, :longitude]
    add_index :property_valuations, :evaluation_data, using: :gin
  end
end

