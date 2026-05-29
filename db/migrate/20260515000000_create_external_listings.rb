# frozen_string_literal: true

# External listings ingested from public real-estate feeds (Yandex YRL feeds
# of other Ryazan agencies, future Avito API, Cian, etc). Used as comparable
# data for property valuation when local Property + MlsListing tables are
# too thin to form a reliable hedonic sample.
#
# Each (source, source_id) is unique — re-ingesting the same feed updates
# in place rather than inserting duplicates. We never delete; setting
# `closed_at` lets the AI filter exclude stale listings without losing the
# historical sample.
class CreateExternalListings < ActiveRecord::Migration[7.1]
  def change
    create_table :external_listings do |t|
      t.string  :source,        null: false # 'yandex_yrl' / 'avito' / 'cian' / 'topnlab_mls'
      t.string  :source_id,     null: false # listing UID inside that source
      t.string  :url
      t.string  :title
      t.text    :description
      t.integer :price
      t.float   :area
      t.float   :land_area
      t.integer :rooms
      t.integer :floor
      t.integer :total_floors
      t.integer :building_year
      t.string  :condition
      t.string  :district
      t.string  :address
      t.float   :latitude
      t.float   :longitude
      t.string  :property_type     # 'flat' | 'house' | 'land' | 'room' | 'commerce' | 'garage'
      t.string  :deal_type         # 'sale' | 'rent'
      t.string  :seller_kind       # 'agency' | 'developer' | 'owner'
      t.string  :seller_name
      t.string  :seller_phone
      t.datetime :fetched_at,     null: false
      t.datetime :closed_at                # set when listing disappears from source
      t.jsonb   :raw_payload, default: {}

      t.timestamps
    end

    add_index :external_listings, %i[source source_id], unique: true
    add_index :external_listings, %i[district property_type deal_type]
    add_index :external_listings, %i[price area]
    add_index :external_listings, :fetched_at
    add_index :external_listings, :closed_at
  end
end
