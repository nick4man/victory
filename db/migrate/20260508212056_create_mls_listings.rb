# frozen_string_literal: true

class CreateMlsListings < ActiveRecord::Migration[7.1]
  def change
    create_table :mls_listings do |t|
      t.string  :external_source, null: false
      t.string  :external_id,     null: false
      t.string  :deal_type,       null: false
      t.string  :realty_type,     null: false
      t.bigint  :price
      t.integer :price_per_sqm
      t.decimal :area,         precision: 10, scale: 2
      t.decimal :living_area,  precision: 10, scale: 2
      t.integer :rooms
      t.integer :floor
      t.integer :total_floors
      t.integer :building_year
      t.string  :building_type
      t.string  :condition
      t.string  :address
      t.string  :city
      t.string  :district
      t.float   :latitude
      t.float   :longitude
      t.string  :metro_station
      t.integer :metro_distance
      t.boolean :has_balcony,  default: false
      t.boolean :has_loggia,   default: false
      t.boolean :has_parking,  default: false
      t.boolean :has_elevator, default: false
      t.string  :url
      t.datetime :listed_at
      t.datetime :synced_at,   null: false
      t.timestamps
    end

    add_index :mls_listings, [:external_source, :external_id], unique: true,
              name: 'index_mls_listings_on_source_and_external_id'
    add_index :mls_listings, [:deal_type, :realty_type]
    add_index :mls_listings, :price_per_sqm
    add_index :mls_listings, [:latitude, :longitude]
    add_index :mls_listings, :district
    add_index :mls_listings, :city
    add_index :mls_listings, :synced_at
  end
end
