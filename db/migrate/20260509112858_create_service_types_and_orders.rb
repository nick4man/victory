# frozen_string_literal: true

class CreateServiceTypesAndOrders < ActiveRecord::Migration[7.1]
  def change
    create_table :service_types do |t|
      t.bigint  :crm_type_id            # nullable until admin maps it from Topnlab
      t.string  :slug, null: false
      t.string  :title, null: false
      t.text    :description
      t.string  :category               # 'finance' | 'legal' | 'technical' | 'marketing'
      t.string  :icon                   # iconography hint for views
      t.integer :order_position, default: 0
      t.boolean :public_visible, default: true, null: false
      t.boolean :active, default: true, null: false
      t.string  :cta_label              # button label, e.g. "Получить консультацию"
      t.timestamps
    end

    add_index :service_types, :crm_type_id, unique: true, where: 'crm_type_id IS NOT NULL'
    add_index :service_types, :slug, unique: true

    create_table :service_orders do |t|
      t.bigint  :crm_id, null: false
      t.references :service_type, foreign_key: true, null: false
      t.bigint  :user_id
      t.string  :client_name
      t.string  :client_phone_masked
      t.string  :stage_name
      t.string  :deal_state
      t.jsonb   :fc_data, default: {}, null: false
      t.datetime :synced_at, null: false
      t.timestamps
    end

    add_index :service_orders, :crm_id, unique: true
    add_index :service_orders, [:service_type_id, :deal_state]
    add_index :service_orders, :user_id
  end
end
