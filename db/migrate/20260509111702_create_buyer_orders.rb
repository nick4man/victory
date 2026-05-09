# frozen_string_literal: true

class CreateBuyerOrders < ActiveRecord::Migration[7.1]
  def change
    create_table :buyer_orders do |t|
      t.bigint  :crm_id, null: false
      t.string  :deal_type, null: false        # 'sale' | 'rent'
      t.string  :realty_type
      t.bigint  :price_min
      t.bigint  :price_max
      t.decimal :area_min, precision: 10, scale: 2
      t.decimal :area_max, precision: 10, scale: 2
      t.integer :rooms_min
      t.integer :rooms_max
      t.string  :preferred_districts, array: true, default: []
      t.string  :preferred_cities,    array: true, default: []
      t.string  :metro_stations,      array: true, default: []
      t.text    :description
      t.bigint  :user_id              # local agent (resolved via email)
      t.string  :stage_name
      t.bigint  :stage_id
      t.string  :deal_state           # lead | active | ad | prepayment | denied | deal | deferred | archive
      t.string  :client_name
      t.string  :client_phone_masked
      t.jsonb   :fc_data, default: {}, null: false
      t.datetime :synced_at, null: false
      t.timestamps
    end

    add_index :buyer_orders, :crm_id, unique: true
    add_index :buyer_orders, [:deal_type, :realty_type]
    add_index :buyer_orders, :user_id
    add_index :buyer_orders, :deal_state
    add_index :buyer_orders, :preferred_districts, using: :gin
    add_index :buyer_orders, :preferred_cities,    using: :gin
  end
end
